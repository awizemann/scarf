# Whole-surface audit after the Hermes v0.21.1 parity branch

Date: 2026-09-08. Branch `feat/hermes-v0211-parity` (27 commits, 66 production files). Scope: the ENTIRE current content of every production file the branch touched, not just the diff. Nine per-surface reviewers, all findings anchored to Scarf file:line and (for Hermes contracts) to the v2026.9.7 source. Only two findings are NEW to this branch; everything else is pre-existing and was invisible until these files were read end to end.

## Verdict

The branch itself is sound (the diff review's 23 findings were all fixed in Phase 8). The whole-surface pass found 9 HIGH, ~25 MED, ~30 LOW pre-existing defects clustered in five classes:

1. **Exit code taken as truth (charter C5).** Hermes handlers return `None` on many failure paths, which exits 0. Scarf reports success for: `skills install` (already installed / blocked scan), `sessions export` (writes "Session not found." into the user's file), `mcp login` (every OAuth failure), `cron run` (prints `Ran now: failed.`), `plugins enable` (capabilities NOT granted).
2. **YAML writers that can make Hermes drop config.yaml entirely.** GatewayConfigWriter hardcodes 2/4-space indent and does not recognise non-empty inline flow mappings; four MCP scalar writers put raw paths in unquoted; `yamlQuoteIfNeeded` misses flow indicators; CRLF files parse to nothing; block-scalar variants fold into the value.
3. **Main-actor blocking (charter C10).** Every Settings scalar write, config check/migrate, and each gateway file-watcher tick run synchronous subprocess/SSH calls (60 s timeout) on the main actor.
4. **Surfaces that can never render.** Skills Updates tab (parser hunts for version arrows Hermes never prints); Kanban hallucination gate + goal badge + diagnostics (wire fields Hermes never emits); MCP test tool chips; plugins compat banner when the roster is empty; browse installs by Name instead of the Identifier column.
5. **Config read drift.** Three wrong upstream defaults (openrouter.response_cache, display.streaming, telegram rich_messages), five raw bool compares that bypass `normalizedScalar`, ~20 true-default bools that read `yes`/`on` as off, closed-enum strings not normalised, `ignore_root_dm` lost its reader at v0.21.1 (NEW: ceiling with no gate), `meta-ai` vision alias missing (NEW), seven v0.20 flags floored one release too high (v2026.7.30 is 0.19.1).

## Findings by surface (severity · NEW/PRE · claim · Scarf file:line · Hermes ref)

### MCP (MCPLoginController, HermesMCPDevicePrompt, IncrementalUTF8Decoder, MCPServers views, HermesFileService MCP writers)
- HIGH · PRE · `mcp login` exits 0 on every failure; sheet says "Signed in." · MCPLoginController.swift:183, MCPLoginSheet.swift:84-94 · mcp_config.py:709-713, 628-705 (returns bool, discarded)
- HIGH · PRE · Chunk boundary inside `Code:` line latches a truncated user code · HermesMCPDevicePrompt.swift:47,60-63; MCPLoginController.swift:176-178 · mcp_oauth_device.py:120-121
- HIGH · PRE · Four MCP scalar writers (client_cert, client_key, ssl_verify, cwd) skip `yamlScalar`; a path with `: ` breaks config.yaml, ` #` truncates · HermesFileService.swift:605-650,735-740 · contrast :764
- MED · PRE · `stop()` on remote kills local ssh, leaves `hermes mcp login` polling on host · MCPLoginController.swift:146-159
- MED · PRE · `mcp test` tool list never parsed (rows are `    name  desc` with ANSI, not `- `) · HermesFileService.swift:817-830 · mcp_config.py:49-52
- MED · PRE · `addMCPServerSSE` discards the transport-stamp result, reports success · HermesFileService.swift:556-563
- LOW · PRE · `IncrementalUTF8Decoder.flush()` never called at EOF · MCPLoginController.swift:109-112
- LOW · PRE · SSE servers get the stdio "terminal" glyph · MCPServersView.swift:244, MCPServerDetailView.swift:56
- LOW · PRE · "Clear Token" failure swallowed · MCPServerEditorView.swift:414
- LOW · PRE · `enabled`/`tools.resources`/`tools.prompts` exact-string, Hermes is boolish · HermesFileService.swift:987-988,1161-1164 · mcp_tool_common.py:120-137
- LOW · PRE · stale citation mcp_config.py:56 → :36 · HermesFileService.swift:801

### Skills / Health / Plugins
- HIGH · PRE · `skills install` always exits 0; every refusal reported as "Installed" · SkillsViewModel.swift:826,559,595 · skills_hub.py::do_install (bare returns)
- HIGH · PRE · Updates tab can never show an update: parser wants `→` arrows, `skills check` prints Name/Source/Status · HermesSkillsHubParser.swift:162-185 · skills_hub.py::do_check
- HIGH · PRE · Browse installs by Name, ignores Identifier column (cells[6]); browse-sh slugs need the hash · HermesSkillsHubParser.swift:70-83 · skills_hub.py::_render_browse_page
- MED · PRE · `plugins enable` non-TTY "capabilities NOT granted (fail closed)" exits 0; Scarf says Enabled · PluginsViewModel.swift:320-352 · plugins_cmd.py::_run_capability_consent
- MED · PRE · Health tooltip cites `hermes audit` (not a verb) · HealthView.swift:91
- MED · PRE · `security audit` exit 1 = findings, rendered as "Audit failed" · HealthViewModel.swift:826-838 · subcommands/security.py `--fail-on critical`
- LOW · PRE · `screen_recording_capturable` parsed, never rendered · HealthViewModel.swift:296-318
- LOW · PRE · `skills install` positionals without `--` · SkillsViewModel.swift:555,582
- LOW · PRE · compat banner inside `list`, unreachable when roster empty · PluginsView.swift:33-39,229
- LOW · PRE · dead parsing stack (loadVersion, parseOutput, splitCheck, iconForSection, runHermes) · HealthViewModel.swift:528,628,691,707,903-906

### Config model / YAML / Settings
- HIGH · PRE · Every Settings scalar write + loadConfig re-read runs synchronously on the main actor (60 s timeout) · SettingsViewModel.swift:167-190,561-579,987-996; AdvancedTab.swift:161-169 (C10)
- MED · PRE · `openrouter.response_cache` default true upstream, Scarf false · HermesConfig+YAML.swift:625 · config_defaults.py:649
- MED · PRE · `display.streaming` default false upstream, Scarf true · HermesConfig+YAML.swift:540 · config_defaults.py:796, cli.py:2598
- MED · PRE · telegram `rich_messages` default false upstream, Scarf true · HermesConfig+YAML.swift:320 · config_defaults.py:1492
- MED · NEW · `platforms.telegram.extra.ignore_root_dm` has no reader at v0.21.1; Scarf reads/writes ungated (ceiling) · HermesConfig+YAML.swift:319, TelegramSetupViewModel.swift:79 · absent at v2026.9.7
- MED · PRE · five bool reads bypass `normalizedScalar` (display.streaming, voice.auto_tts, interim_assistant_messages, slack ×3) · HermesConfig+YAML.swift:540,542,566,420-424
- MED · PRE · CRLF config.yaml drops every section header · HermesYAML.swift:81,84,243-255
- MED · PRE · Approval Mode picker offers `auto` (invalid; Hermes downgrades to manual) · AgentTab.swift:41 · approval_context.py:197
- MED · PRE · Busy Input Mode picker missing `steer` · DisplayTab.swift:102 · config_defaults.py:762
- MED · PRE · WAL Autocheckpoint "Custom" toggle writes 0 (disables checkpointing) · AdvancedTab.swift:406,364 · hermes_state_wal.py:466-487
- MED · NEW · `capabilityProviderOverrides` missing `meta-ai`→`meta` (and `opencode-free`→`opencode`) · ModelCatalogService.swift:479-491 · models_dev.py:120,129
- MED · PRE · catalog lookups don't canonicalise provider aliases (`grok`, `claude`, …) · ModelCatalogService.swift:194,291,519-565,648
- LOW · PRE · block-scalar headers other than bare `|`/`>` fold into the value · HermesYAML.swift:173-183
- LOW · PRE · `str()` never normalises closed-enum keys (trailing comment breaks pickers) · HermesConfig+YAML.swift:63-66
- LOW · PRE · ~20 true-default keys use `bool(default:true)` (reads `yes`/`on`/`1` as off) · HermesConfig+YAML.swift:95…612
- LOW · PRE · `mattermost.reply_mode` read from a path Hermes never reads · HermesConfig+YAML.swift:435 · mattermost/adapter.py:120-121
- LOW · PRE · `applyConfigWrite` never refreshes rawConfigYAML/personalities · SettingsViewModel.swift:175
- LOW · PRE · resolved TODO(WS-8-Q2) xai voice_id · HermesConfig.swift:274-277, SettingsViewModel.swift:496-497
- LOW · PRE · providerDisplayNameOverrides applied on 2 of 5 paths · ModelCatalogService.swift:135,190 vs 252,294,328
- LOW · PRE · stale citations to `hermes_cli/cli.py` (does not exist) · AdvancedTab.swift:427-431, DisplayTab.swift:71-78
- LOW · PRE · `openedAtPath` dead; schema flags never reset on failed refresh · LocalSQLiteBackend.swift:33,190-192,226-234
- LOW · PRE · `SQLValueInliner.encode(.real:)` emits `nan`/`inf` · SQLValueInliner.swift:126-128

### Gateway / Platforms
- HIGH · PRE · GatewayConfigWriter hardcodes 2/4-space indent; a 4-space section gets an indent-2 key spliced → PyYAML error → Hermes discards whole config.yaml layer · GatewayConfigWriter.swift:78-79,313,414-431 · gateway/config.py:786-791
- HIGH · PRE · non-empty inline flow mapping (`slack: {reply_to_mode: first}`) not recognised → duplicate top-level key appended, original clobbered · GatewayConfigWriter.swift:278-293,512,433
- MED · PRE · `yamlQuoteIfNeeded` misses `[ ] { } , ! % \` ?` and newlines · GatewayConfigWriter.swift:538-556; GatewayBehaviorViewModel.swift:150-152
- MED · PRE · `PlatformsViewModel` misses `slack: {}` / `slack:  # comment` (requires hasSuffix(":")) · PlatformsViewModel.swift:106
- MED · PRE · stale PID shown beside "not running" · GatewayView.swift:145-149
- MED · PRE · gateway `load()` has no change-token/cancellation; each watcher tick spawns 3 subprocesses · GatewayView.swift:53, GatewayViewModel.swift:114-137
- LOW · PRE · comments cite `gateway list --json` (no such flag) · GatewayViewModel.swift:93, GatewayView.swift:72
- LOW · PRE · `headerDigest` platform clauses and empty branch unreachable · HermesGatewayListService.swift:48-81
- LOW · PRE · `saveList` doc says main-actor-safe; caller detaches for a reason · GatewayConfigWriter.swift:217-221
- LOW · PRE · dead `"imessage"` arms · PlatformsView.swift:187-188, PlatformsViewModel.swift:142

### Cron
- MED · PRE · unticking all skills in edit is a silent no-op (needs `--clear-skills` / `--add-skill` / `--remove-skill`) · CronView.swift:199, CronViewModel.swift:518-522 · hermes_cli/cron.py:607-618, subcommands/cron.py:100-103
- MED · PRE · "Run now" success for `Ran now: failed.` (exit 0) · CronViewModel.swift:399-413 · hermes_cli/cron.py:635-678
- MED · PRE · ~11 `cron/jobs.py:` citations stale by 500–1500 lines · HermesCronJob.swift:185…709, CronViewModel.swift:201,302,390
- LOW · PRE · edit sheet never seeds Repeat; `repeatSpec` has no consumer · CronView.swift:1428-1445
- LOW · PRE · doctor findings lost for ids containing a space · HermesCronDoctorParser.swift:164-167
- LOW · PRE · `parseHermesTimestamp` naive→UTC, Hermes uses local/configured tz; `oneShotIsUnresumable` lacks the ±12h window · HermesCronJob.swift:314-328 · cron/jobs.py:807-814
- LOW · PRE · `latenessDisplay` rounds where Hermes truncates; no negative clamp · HermesCronJob.swift:884-895 · hermes_cli/cron.py:88-100
- LOW · PRE · doctor/incidents not refreshed after a mutation · CronViewModel.swift:567

### Kanban / Sessions / HermesDataService
- HIGH · PRE · `sessions export` exits 0 on every error; error text written to the user's file as "success" · SessionsViewModel.swift:727-746,800-820 · sessions_cmd.py:295-335,46-48
- HIGH · PRE · hallucination-gate surface (`hallucination_gate_status`, `auto_blocked_reason`) keyed on fields Hermes has never emitted; Reject button, dim glyph, banner all unreachable · HermesKanbanTask.swift:46-55,193-194,237-238; KanbanInspectorPane.swift:376-478,862-869; KanbanCardView.swift:78-82…384 · kanban_output.py:18-24, kanban_db.py:700-940 (no such columns)
- MED · PRE · goal-mode badge and diagnostics never render (`goal_mode`, `diagnostics` not in `_TASK_DICT_FIELDS`; diagnostics only via `kanban diagnostics --json`) · HermesKanbanTask.swift:56-59,86-93; KanbanCardView.swift:293-329,411-416
- MED · PRE · `sessions rename` no `--` before title · SessionsViewModel.swift:488-490
- MED · PRE · create sheet says max-retries "Defaults to 3"; Hermes `DEFAULT_FAILURE_LIMIT = 2`, and 1 = no retries · KanbanCreateSheet.swift:50,176-179; KanbanCreateRequest.swift:24-32 · kanban_db_dispatch.py:33,1006-1033
- MED · PRE · Archive tooltip claims no hard-delete; board ships `archive --rm` · KanbanInspectorPane.swift:896
- LOW · PRE · five dead `HermesDataService` methods, two unbounded · HermesDataService.swift:1272-1279,1606-1686
- LOW · PRE · `api_call_count` at hardcoded index 20 · HermesDataService.swift:2093-2097

### Capabilities / roster
- MED · PRE · seven v0.20-group flags floored one release too high; v2026.7.30 is 0.19.1 (numbered) → 0.19.1 hosts hide six working surfaces · HermesCapabilities.swift:646,652,658,671,680,691,698
- MED · PRE · web-backend pickers have no `""` inherit option; stock config renders blank, no way back · WebToolsBackendRoster.swift:38,51,61 · config_defaults.py:350-352
- MED · PRE · roster "only widens" implemented for tavily only; unknown-version host with `perplexity` selected renders blank · WebToolsBackendRoster.swift:65-70
- MED · PRE · pre-v0.21.1 Fast Mode toggle clobbers `auto`/`cold` when the probe failed; `HermesServiceTier.options` old-host branch unreachable · AgentTab.swift:101-109, HermesServiceTier.swift:102-104
- LOW · PRE · ten citations past EOF of the modularised main.py / moved cron lines · HermesCapabilities.swift:751…900
- LOW · PRE · 32 flags with no consumer; two assert surfaces that don't exist (transform_llm_output, cron --reasoning-effort) · HermesCapabilities.swift:223,811
- LOW · NEW · photon roster floor literal duplicates `hasPhotonPlatform` · HermesTool.swift:171
- LOW · PRE · header narrative stops at v0.16 · HermesCapabilities.swift:8-23

### File service / Fleet / Credential pools
- LOW · PRE · credential-pool argv sends numeric index although label resolves first; label "2" collides · CredentialPoolsViewModel.swift:413,535-551 · credential_pool_admin.py:87-111
- LOW · PRE · fleet apply with all script-only jobs reports `.applied` · FleetApplyExecutor.swift:382

## Verified sound (do not redo)
C3 (no state.db writes anywhere); C4 (all detection PRAGMA/sqlite_master/state_meta); every cron/kanban/auth/mcp/sessions/skills/plugins argv against the tagged argparse except the `--` gaps listed; all v0.21.1 flag floors both directions; all KnownPlatforms floors; the tavily/keenable/perplexity windows; every v0.21.1 config default; the messages_fts contract; SQLValueInliner text encoding; ProjectTemplateInstaller path traversal; FleetApplyExecutor task group; project.pbxproj.

## Proposed remediation phases (same process: Opus agent, tests that fail without the fix, fresh-eyes, memory)
- P9 Exit-code-as-truth (C5 class): skills install, sessions export, mcp login, cron run-now, plugins enable, security audit findings-vs-failure. Shared rule: judge by emitter output; add a `HermesCLIOutcome` helper if three sites can share it.
- P10 YAML writers and parser: GatewayConfigWriter indent/inline-flow/quoting; MCP scalar writers via `yamlScalar`; addMCPServerSSE result; CRLF; block-scalar variants; PlatformsViewModel `{}`.
- P11 Main-actor (C10): SettingsViewModel writes/check/migrate; AdvancedTab diagnostics; gateway load coalescing + cancellation; saveList doc.
- P12 Skills hub + MCP login: browse Identifier column; Updates tab Status parse; install `--`; device-prompt partial line + flush + remote stop; mcp test tool rows; SSE glyph; clear-token error; boolish enabled.
- P13 Config read correctness: three default drifts; five raw bools; ~20 true-default bools; enum `str` normalisation; `ignore_root_dm` ceiling; mattermost reply_mode; rawConfigYAML refresh; approval `auto`; busy `steer`; WAL 0; meta-ai/opencode-free vision aliases; provider canonicalisation; display-name consistency; stale TODOs/citations.
- P14 Kanban/Sessions: delete or re-derive hallucination gate; goal/diagnostics via `kanban diagnostics --json` or drop; rename `--`; max-retries copy/default; archive tooltip; dead HermesDataService methods; api_call_count by name.
- P15 Cron: skills diff on edit; repeat seed; doctor id with space; naive timestamp window; lateness truncate; refresh after mutation; citations.
- P16 Capabilities/roster hygiene: `isV0191OrLater` re-floor; roster `""` + widen-selected; fast-mode bounded fallthrough; citations; flag annotations; header; photon; HealthViewModel dead stack; gateway list dead branches; PID gate; imessage arms; capturable row; compat banner hoist; audit tooltip; LocalSQLiteBackend flags; inliner nan; credential internalID; fleet status.
