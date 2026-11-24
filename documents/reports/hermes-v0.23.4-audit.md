# Hermes v0.23.0 → v0.23.4 audit (2026-11-24)

Scarf target: v0.23.0 (`scripts/check-hermes-tables.py` HERMES_TARGET_TAG). Latest stable: v0.23.4 (patches v0.23.1–v0.23.4, 13,576 commits). Every finding below re-verified by me against the tagged source; floors found by checking each tag.

## Verdict
- **state.db schema Scarf reads: unchanged.** DDL moved to `persistence/sqlite/_schema_ddl.py`; adds `sessions.prompt_cache_clock`, table `resumable_subagents`, retires `messages_fts_cjk` — none read by Scarf. Session `source` values identical.
- **ACP: nothing new reaches the client unhandled.** No new update types, commands, methods or error reasons. Content-refused turns now replay as a user chunk + agent notice; Scarf builds transcripts from state.db, so no effect.
- **Provider tables:** `check-hermes-tables.py --tag v0.23.4` → OK, lanes=8/8 (WARNs only: deliberate dormant overlays, `kimi-coding` not statically readable).
- So: a light cycle, but **five user-visible regressions/behaviour changes** in CLI output and defaults.

## Forced by the upgrade (fix)
| # | Finding | Floor | Hermes | Scarf |
|---|---|---|---|---|
| U1 | `webhook subscribe` now prints a **masked** secret + "(full value in …/webhook_subscriptions.json)"; Scarf's copy-once sheet shows the mask as the secret | v0.23.2 | `hermes_cli/webhook.py:325` | `Features/Webhooks/ViewModels/WebhooksViewModel.swift:295-307` |
| U2 | New webhook routes default to `signature: generic`; GitHub/GitLab/Linear webhooks created from Scarf are refused. New `--signature generic|github|gitlab|linear` | v0.23.2 | `hermes_cli/webhook.py:180` `_route_signature` | `WebhooksViewModel.swift:205-220` |
| U3 | `profile list` prints `<name> — delete incomplete` rows and a `Deletion of profile '…' did not finish` line; Scarf lists a phantom profile "Deletion" (only after an interrupted delete) | v0.23.4 | `hermes_cli/profile_cmd.py:126-131` | `ScarfCore/Models/HermesProfileList.swift:67-111` |
| U4 | `prompt_caching.cache_ttl` default "5m" → "auto" (+ migration removes the installer's "5m"); Scarf shows "5m" and has no "auto" option | v0.23.3 ("auto" valid since ≤v0.23.0) | `hermes_cli/config_defaults.py:689` | `Parsing/HermesConfig+YAML.swift:1054`, `Settings/Views/Tabs/AdvancedTab.swift:553-559` |
| U5 | Yuanbao left core (now a Hermes Labs plugin); Scarf tells users to "run `hermes setup` and select Yuanbao", which no longer exists | v0.23.1 | `plugins/platforms/yuanbao/` removed | `Models/HermesTool.swift:120`, `Platforms/Views/PlatformsView.swift:217-236` |
| U6 | Cron jobs gain tri-state `wrap_response`; Scarf's "duplicate job" drops it | v0.23.2 | `cron/jobs_tristate.py:16-21`, `cron/job_definition.py:19` | `Models/HermesCronJob.swift` (`authoredExtraKeys`) |

## Behaviour changes to reflect (copy / settings)
- B1 `agent.clarify_timeout` default 3600 → 90 s (v0.23.1): Hermes's clarify questions in Scarf chat now expire after 90 s. Worth a Settings field. `config_defaults.py:219`.
- B2 Graceful restart is now "restart when idle" (v0.23.2): gateway keeps serving, no longer refuses turns while `draining`. Scarf's drain-watch doc says it refuses turns for up to 1800 s; detection still works, but check what the watch shows if Hermes waits past Scarf's deadline. `gateway/restart_when_idle.py:1-15`; Scarf `Services/HermesGatewayRestartDrain.swift:13-16,188-201`.

## Small / optional
- `voice_mention_patterns` new shared platform key → `HermesPlatformSharedKeys.swift:64-74`.
- `gateway.pid` gains `pidns`; multiplexer mirrors `relay`; MCP wrapper checks stricter; "profile runs elsewhere" refusal (surfaces as plain CLI error).
- New config keys not in Scarf: `prompt_caching.route_ttl_ceilings`, `cron.wrap_response`, `skills.index_desc_limit`, `delegation.auto_resume`, `approvals.approvers`, `security.redact_phone_numbers`.

## No-ops checked
All other Scarf CLI verbs (gateway, cron, sessions, profile, plugins, skills, curator, tools, mcp, auth, memory, pairing, kanban, peer, status/doctor/dump…): no verb or flag removed or renamed. `gateway list` and `gateway_state.json` shapes, MCP catalog, bundled skills, curator outputs, launcher shapes (gh#154 fix still matches).

## Proposed scope
Slice A (bugs, gated at their floors): U1–U6. Slice B (copy + settings): B1 Settings field, B2 doc/watch check, `voice_mention_patterns`. Then bump `HERMES_TARGET_TAG` to v0.23.4, `HermesCapabilitiesTests` cluster, memory/wiki, release prep.
