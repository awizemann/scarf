# Hermes v0.23.0 — Phase 0 findings (P0a CLI, P0b ACP, P0c providers/config/schema)

All citations are `@ v0.23.0` unless stated otherwise. Spot-checked by the orchestrator: left_core_migration.py:790-792, browser_session_cloud.py:225-226, and gateway_session_meta.py:72 @ v0.22.6.

## Corrections to the plan
- **F3 revised.** `browser.cloud_provider: camofox` is still accepted (browser_session_cloud.py:225-226). Without the plugin there are simply no Camofox tools. The S3 fix is unchanged: gate the row on the plugin being installed.
- **F5 revised.** The ACP `config_options` mode, model and reasoning pickers ship from **v0.22.6**, not v0.23.0. v0.23.0 adds only `service_tier` and `/model reset`.
- **The real install reports** `v0.23.0+209.g90d6b98.dirty (2026.9.24)`. The date in parentheses is stale (it's the v0.21.5 date). P0a is checking how Scarf parses this.

## Plugin presence predicate (Hermes's own)
`plugin_present(plugin, home)` returns `(home/"plugins"/plugin).is_dir()` (left_core_migration.py:790-792). Scarf should mirror this through the window's transport, not by parsing `plugins list` output.

## Breaking → slices
- **S2 Copilot.** Ids: `copilot`, `github-copilot`, `github-models`, `github-model`, `github`; ACP ids: `copilot-acp`, `github-copilot-acp`, `copilot-acp-agent` (left_core_migration.py:339-340). Env vars: `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`. The plugin no longer reads `gh auth token` (:353-358). Scarf sites to change:
  - ModelCatalogService.swift:1030, 1328-1331
  - ModelPreflight.swift:208, 321
  - HermesRoutableProviders.swift:49, 53
  - HermesProviderCredentials.swift:35, 56, 67, 83-85
  - HermesCapabilities.swift:154
  - ACPClient.swift:1335
  
  Gate on ≥0.23.0 **and** `plugins/github-copilot` present. Update check-hermes-tables.py to treat these ids as plugin-gated.
- **S3 Browser.** Gate the Camofox row and `browser.camofox.managed_persistence` (SettingsViewModel.swift:867, BrowserTab.swift:50-51, HermesConfig+YAML.swift:322) on ≥0.23.0 + `plugins/camofox`. Hide `browser.record_sessions` (HermesConfig+YAML.swift:320) on ≥0.23.0, since the key was removed and the config version went 51→52. Hide any `auxiliary.skills_hub` UI on ≥0.23.0. Fix the STT help text: a blank per-provider language now means "inherit `stt.language`".
- **S4 ACP.**
  - Copy only: cancel no longer kills background subagents (server.py:656).
  - Edit-approval titles are now redacted (edit_approval.py:207). Read the path from `content[].path`, not the title.
  - `/rewind` is cli_only (commands.py:105-106); never offer it over ACP.

## Unchanged (verified)
- state.db schema. The real v0.23 db has `messages.active` and `messages.compacted`.
- Prompt and usage shapes, tool_call, permission kinds, ROUTES for `/undo`, `/retry`, `/queue`, `/steer`.
- Rewind still sets `active = 0`. All v0.22.x gates hold.
- Platform, web and browser-cloud plugin rosters, apart from Camofox. Singularity is already handled.

## S4 spec (ACP config options, gateway-backed ACP only)
- **Where they arrive.** `configOptions` arrives on the new/load/resume/fork reply (gateway_server.py:299-322), and as `session/update` with `sessionUpdate:"config_option_update"`. It always carries the full list (:1099-1122).
- **Option shape.** Each option is `{id,name,category,type:"select",currentValue,options:[{value,name}]}` (gateway_session_meta.py:83-125). The ids, in order:
  - `edit_approval_policy`, with values `ask`, `workspace_session`, `session`
  - `model`
  - `reasoning_effort`, with values `default` (only while unset), `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`
  - `service_tier` (v0.23.0, only when the model supports fast mode), with values `normal`, `fast`, `auto`, `cold`, `ultrafast`; an unavailable current value gets an extra row
- **Writes.** `session/set_config_option {sessionId, configId, value}`. The reply is the refreshed full list.
  - Reasoning and edit changes are idle-only (busy → -32603 with explanatory text).
  - Tier changes are not idle-gated.
  - On the in-process (non-gateway) server the call is a no-op; never build pickers from it.
- **`/model reset`.** Routes as the model mutation `{'model':'reset'}` (gateway_mutations.py:136-143; session_mutation_model.py:156-190). Gate it on v0.23.0: older hosts would try to switch to a model literally named "reset".
- **Scarf gap.** Scarf needs a `configOptions` decoder (ACPMessages.swift:530-547, :656), a `set_config_option` sender (ACPClient.swift beside :728 and :767), and an `ultrafast` case in HermesServiceTier.swift:31-64.

## Flags to add (S1)
- **v0.22.6:** `hasACPConfigOptions`.
- **v0.23.0:** `hasACPServiceTierOption`, `hasModelReset`, `hasCopilotLeftCore`, `hasCamofoxLeftCore`, `hasBrowserRecordSessionsRemoved`, `hasSkillsHubAuxRemoved`, `hasSTTLanguageInherit`.
- Plus the CLI-verb flags from P0a.

## New config keys (optional surfaces, not in scope unless asked)
`compression.prepare_ahead`, `agent.stream_max_lifetime`, `webapp.*`, `vault.key_storage`, `browser.{executable_path,user_data_dir,chromium_args}`. `plugins.auto_apply` and `delegation.backend` already existed at v0.22.5. Bot Mode room purpose and notes live in `shared-state.db` `hosted_room_events`; Scarf reads none of it, and that stays out of scope.

## P0a: CLI (argv and parsers)
- **Version parsing is fine.** `parseLine` (HermesCapabilities.swift:3199-3256) stops at `+`, so the installed `v0.23.0+209.g….dirty (2026.9.24)` and canary builds parse as 0.23.0. Gates compare semver only. The stale date comes from Hermes itself (`hermes_cli/__init__.py:5`).
- **Sessions.** Failures now exit 1 (sessions_cmd.py:47-75, :994). Scarf's `"not found."` marker (HermesCLIOutcome.swift:667) never matched what Hermes prints, `No session '<id>'…`, on v0.22.5 either, so it's a bug fix for all hosts. Add the `No session '` marker and treat a non-zero exit as failure on ≥0.23 (fix lands in S7).
- **Cron (S5).**
  - Duplicating a job must carry the new `timezone`, `grace_minutes` and `catch_up` fields (cron/job_definition.py:13-18 → HermesCronJob.swift:665-671).
  - Add a `cancelled` last_status icon and widget case (cron/jobs.py:2404-2406 → HermesCronJob.swift:926-936, CronStatusWidgetView.swift:134).
  - `cron cancel <id> [--reason]` (subcommands/cron.py:200-204):
    - `Failed to cancel run:` → exit 1.
    - `Nothing to cancel for` → exit 0.
    - `Cancel requested for` → exit 0.
  - `--catch-up {on,off}` and `--grace-minutes` (0-1440) on create and edit.
- **Plugins (S6).**
  - `plugins update [name] [--yes] [--force]` (subcommands/plugins.py:68-78). `--yes` is required without a TTY. `--force` overrides a caution verdict only.
  - `plugins auto-update [on|off]` (:80-88), which sets `plugins.auto_apply`.
- **S7.**
  - `sessions refresh-prompts [--session ID] [--json]` (subcommands/sessions.py:33-43).
  - `curator lock|unlock <skill>` (curator.py:682-684, :243-270). Success prints `curator: locked '<key>'.`; failures print `curator: no skill named` or `curator: could not record` and exit 1.
- **Tools.** Post-setup keys were renamed (agent_browser/camofox → chromium/lightpanda, subcommands/tools.py:42-49). Scarf passes neither, so no change is needed.
- **Unchanged.** Curator verbs, sessions delete/rename/export/optimize flags and markers, mcp add, tools enable/disable, the other cron flags, kanban, skills, gateway list, memory, update, `--version` format.
- **Printers (follow-up, done).** Every printer and marker for doctor, status, gateway, plugins list, tools, backup and pairing still matches, checked live on 90d6b98. `status.py` is unchanged between the tags. `plugins list --json` adds a `removed` key (S6: confirm the decoder ignores unknown keys). The only mismatch found is the browser keys, already in S3.

## Final S1 flag set
- **v0.22.6:** `hasACPConfigOptions`.
- **v0.23.0:** `hasACPServiceTierOption`, `hasModelReset`, `hasCopilotLeftCore`, `hasCamofoxLeftCore`, `hasBrowserRecordSessionsRemoved`, `hasSkillsHubAuxRemoved`, `hasSTTLanguageInherit`, `hasCronCancel`, `hasCronCatchUpGrace` (catch-up, grace, timezone and the cancelled status), `hasPluginsAutoUpdateVerb`, `hasSessionsRefreshPrompts`, `hasCuratorLock`, `hasSessionsNonZeroExit`.
