# Next Scarf release — Hermes v0.21.4 / v0.21.5 + open GitHub issues (plan, 2026-09-26)

Baseline: Scarf 3.3.0 targets Hermes **v0.21.3 (v2026.9.14)**. New: **v0.21.4 (v2026.9.21)**, **v0.21.5 (v2026.9.24)**. 6,811 upstream commits; most are desktop/server-side no-ops. Source-verified by five read-only audit passes (state.db+ACP, CLI argv, config/providers, gateway/MCP/cron, issues). Line refs are at the floor tag.

## Verdicts
- **state.db schema:** no messages/sessions column Scarf reads changed. New `sessions.transport_profile` (gateway-only), `idx_sessions_tool_names`, and an **FTS redesign** (tool rows truncated in the index, `fts_tool_full_content_high_water` marker deleted, new `messages_fts_src` view) — silently narrows Scarf search. `hermes_state_schema.py:139,343-366@9.21`.
- **ACP:** one new unhandled event — permission / edit-approval requests are closed by a `tool_call_update` for ids `perm-check-N` / `edit-approval-N` that never had a start; Scarf appends an empty tool row. `acp_adapter/permissions.py:54-64@9.21`, `edit_approval.py:199-207@9.24`.
- **CLI:** no verb removed Scarf uses (`cli.py` shrink was non-argparse). But ~10 output/exit-code changes break Scarf's outcome judges.
- **Biggest theme:** the gateway became multiplex-by-default (0.21.4) and profiles can be *parked* (0.21.5).

## Phase A — forced by the upgrade (must ship)
| # | Fix | Hermes | Scarf | Floor |
|---|---|---|---|---|
| A1 | Kanban `diagnostics --json` now ends with a `{"task_id": null, …}` row → whole decode throws | `hermes_cli/kanban.py:683-687` | `Models/HermesKanbanDiagnostic.swift:207` | 0.21.4 |
| A2 | Ignore `tool_call_update` for unknown ids (stray empty tool rows during approvals) | `permissions.py:54-64` | `RichChatViewModel.swift:2291-2339` | 0.21.4 |
| A3 | Search: detect `messages_fts_src` and run LIKE fallback with high-water 0 | `hermes_state_common.py:714-727` | `HermesDataService.swift:824-853`, `HermesSearchIndex.swift:25-36` | 0.21.4 |
| A4 | Multiplex: missing `gateway.multiplex_profiles` = on (≥0.21.4); hide the "off" switch (explicit false is retired, rewritten to true at 0.21.5) | `config_defaults.py:2120`, `gateway_multiplex_mode.py:32,132,170-195` | `ProfileRoutesYAML.swift:78`, `ProfileRoutesSection.swift:92,171-183`, `SettingsViewModel.swift:1233` | 0.21.4 |
| A5 | Gateway start/stop/restart on a served profile print "parked / served by / restarted by the host gateway" → Scarf reports failure; `gateway status` has a "parked" early return | `gateway_profile_lifecycle.py:18-87`, `gateway.py:5021` | `HermesCLIOutcome.swift:965-1016,1704`, `GatewayViewModel.swift:331-372` | 0.21.5 |
| A6 | `sessions optimize` refuses (exit 1) while any process holds state.db → gate `--force` or explain | `sessions_cmd.py:1006-1032` | `HermesCLIOutcome.swift:2157` (Health) | 0.21.4 |
| A7 | Backup: partial archive exits 1 but is kept; warning line reworded | `main.py:2269-2271`, `backup.py:737,750` | `HermesCLIOutcome.swift:2254-2320` | 0.21.4 |
| A8 | MCP `enabled: 0/1` is now a real bool in Hermes; Scarf treats a bare number as "default" (inverts) | `tools/mcp_tool_common.py:128-129` | `HermesFileService.swift:2343-2382` | 0.21.5 |
| A9 | Output text: skills "Not installed:"; cron doctor closing hint; cron incident state `resolved`; `profile delete` "settlement pending" exit 1 after a real delete; `peer dm` `queued` / "accepted… Do NOT resend" | `skills_hub.py:726`, `cron.py:325,666`, `profiles.py`, `subcommands/peer.py` | `HermesCLIOutcome.swift:311-320,840`, `HermesCronDoctorParser.swift`, `HermesCronIncidentsParser.swift:49,83`, `ProfilesViewModel.swift:178`, `HermesPeerCLI.swift:231-245` | 0.21.4 |
| A10 | Catalog: `opencode-free` removed (hide on ≥0.21.4 only); add `chatgpt`/`chatgpt-codex` → openai-codex aliases; new `openai-native` search backend; `compression.threshold_tokens` default None→256000; WhatsApp `decline` DM behaviour | `providers.py:122`, `auth.py:1255`, `plugins/web/openai_native/provider.py:68`, `config_defaults.py:570`, `gateway/config.py:139,627` | `ModelCatalogService.swift:555,1037-1043,1120,1165`, `ModelPreflight.swift:111`, `WebToolsBackendRoster.swift:47-53`, `HermesConfig+YAML.swift:469`, `WhatsAppSetupViewModel.swift:44` | 0.21.4 |
| A11 | `HermesCapabilities` v0.21.4 + v0.21.5 groups, `isV0214OrLater`/`isV0215OrLater`, degradation tests; `check-hermes-tables.py --tag v2026.9.24` to exit 0 `lanes=5/5`; bump `HERMES_TARGET_TAG` | — | `HermesCapabilities.swift:2148+`, `scripts/check-hermes-tables.py:92` | — |

Pre-existing, found in passing (cheap, include): `kimi-for-coding` overlay unreachable in picker (fails at 9.14 too); cron duplicate copies runtime `quota_hold_until` → copy only Hermes's authored field list (`cron/job_definition.py:13-18@9.24`); stale doc comments citing removed `_compute_provider_model_snapshots`.

## Phase B — GitHub issues
- **#146 resuming a hermes-webui session spawns new chats (bug).** Confirmed first spawn: Hermes ACP `session/load` only restores `source == "acp"` sessions (`acp_adapter/session.py:428`, `server.py:616-624`); Scarf silently falls back to a new session and shows the old transcript, so the model has no context. Fix: check source before resume (Bot Chat already does, `BotConversationViewModel.swift:209`), and say plainly "continues as a new session" or resume via CLI transport; resolve `compressionTip` before load. Second spawn needs a live repro. Related: t-e875803c.
- **#145 branch/fork + the "3-dot" icon.** The dots are the waiting-for-first-event indicator; its `.symbolEffect(.pulse)` never animates plain circles, so it looks frozen. Fix: "Working · 0:12" elapsed timer from existing `currentTurnStart` (`RichChatMessageList.swift:159-166,233-251`). Branch *display*: Scarf already lists children; mark them via `parent_session_id` / `_branched_from`. Branch *action*: ACP `session/fork` exists but writes no lineage (`session.py:197-208`) — recommend defer + file upstream.
- **#141 ScarfGo "sqlite3: not found".** Friendly message exists in `HermesDataService.humanize` but isn't applied to `lastOpenError` (`HermesDataService.swift:104,123,139`). Quick fix: humanize + banner title. Proper fix: fall back to Hermes's own Python `sqlite3` module (read-only URI) when the binary is missing.
- **#140 CPU pegged during chat.** Throttle + incremental markdown already shipped in 2.22.0; reporter never retested. Remaining hotspot: eager `VStack` re-layout of up to 30 groups per 50 ms flush (`RichChatMessageList.swift:45-80`), whole-pane re-evaluation (`ChatTranscriptPane.swift:84-104`). Fix direction: isolate the streaming row in its own observable.
- **#142 / PR #144 HERMES_ENVIRONMENT_HINT.** Direction is right; PR needs rework: reader floor is **v0.16.0** (`prompt_builder.py:1052-1056`, first in v2026.6.5) but PR is ungated and strips the block on older hosts; it overrides the user's own hint instead of composing; drops Kanban tenant / slash-marker / secrets rules (cron + chat Kanban tasks land "Untagged"); breaks Cockpit context preview and `ProjectUpgradeServiceTests`; weak tests. Quoting is safe.
- **#139 TestFlight.** Resolved by the App Store release — close.

## Phase C — optional new surfaces (floor 0.21.4 unless noted)
`cron create/edit --pin/--unpin` (cron now follows the main model), `usage --json` (rate-limit windows), `sessions optimize --force` (A6), `kanban create --body-file`, `config get --raw`, `webhook subscribe --mirror-to-session` (0.21.5). New config keys (`agent.text_verbosity`, `tts.keep_warm_seconds`, …) → backlog.

## Deliberate no-ops
Platform roster unchanged (22). TTS roster unchanged. Config migration v45/v46 doesn't touch keys Scarf writes (v46 rewrites MCP `disabled`→`enabled`, which Scarf already uses). Hermes "projects" live in Hermes's DB, separate from Scarf projects. Memory approval pinning, dashboard credential previews, plugin event bridge, desktop branch methods: server/desktop-side.
