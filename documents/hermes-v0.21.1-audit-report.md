# Hermes v0.21.1 (v2026.9.7) audit against Scarf v3.1.0

Date: 2026-09-08. Prior target: v0.21.0 (v2026.8.31), fully audited and shipped in Scarf v2.23.0 on 2026-09-01 (see `hermes-v0.21.0-audit-report.md`). This report covers only the v2026.8.31 → v2026.9.7 delta (~5,995 commits, 4,364 files; mostly a codebase modularization so file diffstats are moves, and every finding below was verified on semantics at both tags).

Installed Hermes at audit time: main commit 1cb3ab61 (2026-09-02), between the two tags.

## Verdict

- **state.db schema Scarf reads: unchanged.** `messages` DDL byte-identical. `sessions` gained two additive columns (`tool_names`, `compression_recovery_deadline`), plus a new unrelated table `conversation_generations` and index `idx_sessions_effective_activity`. SCHEMA_VERSION 26→30 but every new migration is FTS-only. All Scarf column reads are already PRAGMA-gated; no new gate needed.
- **ACP wire: nothing new reaches the client.** Pure module split. Same 9 advertised commands, same 9 `session_update` discriminators, same permission/mode/content-block/initialize/session-method shapes. `hermes acp` flags unchanged.
- **CLI: zero removals/renames/arity/output changes on any of the 88 argv Scarf issues.** The 15 "new" subcommand files are moves out of `main.py`.
- **Provider tables: value-identical** (overlays 42, aliases 89, aggregators 8, labels, xAI retirement, models.dev cache path/TTL). Image-gen catalog and default model unchanged.
- **Gateway platform roster: identical** (24-member Platform enum, same directories). Allowlist keys still top-level.
- **MCP catalog, skills-hub table, curator verbs/output/exit codes, cron runs/incidents/doctor grammar: unchanged.**

So this is a light additive cycle. The forced work is small; most of the value is in a handful of new cron/MCP surfaces and in pre-existing bugs found on the way.

## A. Forced by v0.21.1 (Scarf is wrong on a v0.21.1 host today)

| # | Action | Finding | Hermes | Scarf | Conf |
|---|---|---|---|---|---|
| A1 | CHANGE | `scripts/check-hermes-tables.py` **crashes** (AttributeError on `ast.DictComp`): `ALIASES` is now built by inverting `_ALIAS_GROUPS`. With the parser patched, result is 0 FAIL / 3 dormant WARNs. | `hermes_cli/providers.py:117,139` | `scripts/check-hermes-tables.py:57` | high |
| A2 | CHANGE | **Tavily web backend is back** (`plugins/web/tavily/` re-added after the v0.21.0 removal; commit 428e084dcd). `hasTavilyWebBackend { !isV021OrLater }` now hides a live backend on every v0.21+ host, and the Web Tools footer copy ("v0.21 removed the Tavily backend…") is false. Needs floor = v0.21.1 for the "removed" window (0.21.0 only) or drop the removal flag. | `plugins/web/tavily/__init__.py:1` | `HermesCapabilities.swift:952`, `WebToolsTab.swift:26-64,107` | high |
| A3 | ADD | New web backend `perplexity` (search + extract). `keenable` has existed since v0.20.6 and was never added to the picker arrays either. | `plugins/web/perplexity/` | `WebToolsTab.swift:34-47` | high |
| A4 | CHANGE | `agent.service_tier` accepts two new values `auto` and `cold` (plus new `agent.fast_auto_seconds: 60`). Scarf's Bool "Fast Mode" toggle shows OFF for `auto`/`cold` and one tap overwrites them with `fast`/`normal` (both still valid on both tags). Needs a 4-way picker gated on v0.21.1, toggle below. | `cli.py:274-284`, `agent/fast_mode.py:16` | `AgentTab.swift:46-48` | high |
| A5 | CHANGE | Advanced tab telemetry copy claims "there is no remote sink — nothing leaves this machine". v0.21.1 adds `telemetry.shared_metrics.send` (default false) and `.endpoint` (telemetry.nousresearch.com). Collection stays local while `send` is false, so the toggle isn't broken, but the copy is wrong and the opt-in switch should be surfaced. | `hermes_cli/config_defaults.py` (`telemetry.shared_metrics`) | `AdvancedTab.swift:205,220` | high |
| A6 | CHANGE | `gateway status` gained a first branch: `✓ Gateway is running via the default-profile multiplexer` with no PID. `isGatewayRunning` still true, but `isServiceLoaded` falls to `pid != nil` → satellite profile badged "not loaded" while served. Same for `gateway list`: new `— served by the default multiplexer` clause (parser degrades to pid=nil, cosmetic). | `hermes_cli/gateway.py:6112-6115, 1517-1522` | `GatewayViewModel.swift:178-215`, `HermesGatewayListService.swift:113-123` | high |
| A7 | CHANGE | `cron doctor` no longer emits `last run failed:` for `last_status == delivery_failed` (reported only via the delivery-error issue). Any per-job issue counting shifts by one. Parser grammar unchanged. | `hermes_cli/cron.py::_cron_doctor_issues_for_job` | `HermesCronDoctorParser.swift` | medium |
| A8 | GATE | `create_job` now hard-rejects a one-shot `run_at` older than the grace window (non-zero exit) instead of storing a ghost job. Scarf's one-shot path should pre-check (it already models `oneShotGraceSeconds = 120`). | `cron/jobs.py::_next_run_or_reject_past_oneshot` | `HermesCronJob.swift:291` | high |
| A9 | GATE | Cron lifecycle guard can now refuse `cron create --script` on cloud-placeholder files (iCloud/OneDrive) with a "refused without opening" message; surface stderr verbatim. | `cron/lifecycle_guard.py:367-389,780-800` | `FleetApplyPlan.swift:370` | medium |
| A10 | CHANGE | `messages_fts` now indexes only the first 8,192 chars of `content` for NEW `role='tool'` rows (rows above `state_meta.fts_tool_full_content_high_water`). Scarf's search silently under-returns hits deep in large tool outputs; no LIKE fallback. Also a one-time full FTS rebuild runs at first v0.21.1 open (partial MATCH results meanwhile; `fts_rebuild_progress`/`fts_rebuild_high_water` in `state_meta`). | `hermes_state_common.py:215-236,555-580`; `hermes_state_schema.py:287-352` | `HermesDataService.swift:798-806` | high |
| A11 | VERIFY | `sessions.auto_prune` default flipped false→true (retention 90d, runtime default, not a migration). Ended sessions older than 90d now get deleted at Hermes startup. Confirm no Scarf view assumes unbounded history; consider surfacing the `sessions.*` retention block. | `hermes_cli/config_defaults.py` (`sessions.auto_prune`) | Sessions views | medium |
| A12 | VERIFY | New `hermes_state_dbfile.py` can quarantine a zeroed `state.db` by MOVING it aside. Scarf's file watcher holds a path, not an inode; confirm it re-opens rather than reading a stale fd. | `hermes_state_dbfile.py:238-244` | `HermesFileWatcher.swift` | medium |

Migrations: config v39→v41. v40 retires `model_catalog.ttl_hours` (Scarf only writes `excluded_providers`), v41 rewrites SOUL.md. No key Scarf writes was removed or relocated. Managed scope: pure refactor. Security commits: all server-side no-ops.

## B. Pre-existing bugs found while in here (identical at v2026.8.31)

| # | Action | Finding | Hermes | Scarf | Conf |
|---|---|---|---|---|---|
| B1 | CHANGE | **`skills search` results are always discarded.** Search prints a 5-column table (no `#` column); Scarf feeds it to `parseHubList`, which skips any row whose second cell isn't an integer. Fix: pass `--json` (emits `{name, identifier, source, trust_level, description}`, also fixing the identifier guess). | `hermes_cli/skills_hub.py:325,336-340` | `SkillsViewModel.swift:389`, `HermesSkillsHubParser.swift:65` | high |
| B2 | GATE | **`debug share` can never succeed from Scarf.** `_confirm_upload` exits 1 on a non-TTY without `--yes`. Add `-y` behind a confirm sheet (the curator prune/purge pattern) or use `--local`. | `hermes_cli/debug.py:441-450` | `HealthViewModel.swift:667` | high |
| B3 | ADD | `hubSources` omits 8 of 15 `--source` choices: browse-sh, nvidia, openai, anthropic, huggingface, voltagent, gstack, minimax. | `hermes_cli/subcommands/skills.py:17-20` | `SkillsViewModel.swift:100` | high |
| B4 | ADD | `KnownPlatforms.all` (21) is missing 13 real platform ids at both tags. Widens task t-0c0b1aa7: user-facing → dingtalk, sms, irc, wecom, weixin, bluebubbles, qqbot, msgraph_webhook, api_server, photon; internal (don't surface) → wecom_callback, relay, local; borderline → a2a, raft. `dingtalk` already has an allowlist mapping that is unreachable. Discord `allowed_channels` gap confirmed real. | `gateway/config.py` Platform enum; `plugins/platforms/discord/adapter.py:4620` | `HermesTool.swift:94`, `GatewayAllowlistKind.swift:79-96` | high |
| B5 | CHANGE | `GatewayPlatformSettings` docs a per-platform `busy_ack_enabled` (really `display.*`) and `slash_command_notice_ttl_seconds` (exists nowhere in Hermes at either tag); the field is dead. Also `gateway_restart_notification` default drift: Hermes true, Scarf false. | n/a | `GatewayPlatformSettings.swift:6-7,50-66` | high |
| B6 | CHANGE | `imageGenModels` list is stale vs Hermes's catalog (Scarf: gpt-image-1, DALL·E 3, Imagen, flux-pro-1.1…; Hermes: flux-2/klein, gpt-image-2, nano-banana, seedream v5, recraft v4…). Free-text, degrades gracefully. | `tools/image_generation_catalog.py:37` | `ModelCatalogService.swift:712` | high |
| B7 | GATE | Six plugin-registered providers are unreachable in Scarf's picker (absent from models.dev, overlays, and `overlayOnlyProviders`): meta-ai, router, commandcode, commandcode-anthropic, gemini, custom. All api_key auth. The drift script has no lane for plugin providers. | `hermes_cli/models_catalog_static.py:356-367` | `ModelCatalogService.swift:737`, `check-hermes-tables.py:143` | medium |
| B8 | NO-OP | ACP `plan` and `usage_update` still fall to `.unknown` (safely dropped). Product decision, not a regression. | `acp_adapter/events.py:48` | `ACPMessages.swift:395-451` | high |

## C. New v0.21.1 surfaces worth adopting (all gate on a new `isV0211OrLater`)

Ranked by user value.

1. **`plugins compat [--json]`** — flags installed plugins importing pre-decomposition module paths; exit 1 when affected, and they stop loading after the removal date. Given this release IS the decomposition, it's the one thing that tells a user their plugins will break. JSON `{removal_date, in_effect, plugins: {name: [hits]}}`. (`hermes_cli/plugins_cmd.py:2013-2018`)
2. **`cron create --paused [--paused-reason]`** — replaces the create-then-`cron pause` race in `ProjectTemplateInstaller.swift:346` and `FleetApplyExecutor.swift:349`. Prints `Created PAUSED — …` instead of `Next run:`. (`subcommands/cron.py:47-49,84-87`)
3. **`cron create/edit --failure-deliver <target>`** + job field `failure_deliver` — Scarf round-trips it via `extra` but can't show/edit it, and `FleetApplyPlan.cronCreateArgs` drops it when cloning. (`subcommands/cron.py:33,94`, `cron/jobs.py:1546`)
4. **Cron job fields `last_dispatch` {scheduled_at, dispatched_at, kind on_time|late|catch_up, lateness_seconds} and `last_delivery_unverified`**; `cron list` gains `Dispatch:` and `⚠ Delivery UNVERIFIED:` rows; `cron status` gains a late-fire block. (`hermes_cli/cron.py:103-121,433-444`)
5. **`kanban … --completion-contract`** + `kanban list --json` fields `completion_contract`, `last_failure_error` (real failure reason without a second `show`). (`kanban_parser.py:189`, `kanban_output.py:18-24`)
6. **`auth priority <p> <t> <n>`, `auth refresh <p> [t]`, `auth add --priority`, optional target on `auth reset`** — Credential Pools can't reorder or clear one credential's cooldown today. (`subcommands/auth.py:19`)
7. **MCP device-code OAuth**: `mcp login <n> --flow {browser,device}` + config `mcp_servers.<n>.oauth.flow`; device flow prints a URL + user code that must be surfaced. (`subcommands/mcp.py:59`, `tools/mcp_oauth_device.py:108-126`)
8. **`computer-use doctor --json` / `permissions status --json`** — machine-readable macOS TCC state for the Health pane. (`subcommands/computer_use.py`)
9. **Config keys**: `telemetry.shared_metrics.send` (pairs with A5), `agent.fast_auto_seconds` (pairs with A4), `sessions.{auto_prune,retention_days,vacuum_after_prune,…}` (pairs with A11), `updates.check`, `display.bell_on_prompt`, `model.streaming` (distinct from `display.streaming`), `gateway.trust_env`, `tool_loop_guardrails.non_interactive_hard_stop_enabled` (now default ON for unattended sessions), `delegation.{independent_completions,fallback_providers,compression_threshold_tokens}`, `display.resume_last_session`.
10. **`sessions.tool_names`** column (JSON array of enabled tools per session) — could badge sessions.
11. Lower: `browser close-profile`, `gui --local`, `hermes serve`, image-gen provider `meta-ai`, Slack `api_human_users`, `fallback_providers.models.*`, `local_runtime.*` (new bundled local-model runtime, 933-line router; deserves its own pass given `LocalModelConfigPlanTests`).
12. Bundled skills 58→60 (`research/rss-feeds`, `social-media/reddit-reading`); roster is filesystem-scanned so fixture/doc only.

## D. Test gaps

- No test pins Scarf's web-backend picker arrays against the Hermes plugin roster; the parity test uses `tavily` only as a fixture value, which is exactly why A2/A3 slipped through. Add one asserting `searchBackends`/`extractBackends` against a pinned v0.21.1 list.
- Add `HermesCapabilitiesTests` cluster for v0.21.1 (parse, all-flags-on, v0.21.0 host hides them, patch-release-still-on).
- Optional `HermesV0211SchemaTests` fixture asserting `sessions.tool_names` / `compression_recovery_deadline`.
- `cronRunsFormatUnchangedAtV021`-style drift alarms for the `Dispatch:` and `Delivery UNVERIFIED` rows.

## E. Release-note claims vs source

The v2026.9.7 notes are deliberately non-enumerating ("full notes ship with v0.22.0"), so there were few claims to falsify. Two things the notes imply that are NOT surface changes: "desktop session controls and browser annotations" (Electron-only), "codebase modularization" (zero wire/CLI change). One thing the notes don't say that matters: Tavily's return.

## Suggested phasing

- **Phase 1 (forced, small):** A1 script fix; A2/A3 web-backend floor + Perplexity/Keenable; A4 service_tier picker; A5 telemetry copy + `send` toggle; A6 multiplexer status branch; A7–A9 cron guards; `isV0211OrLater` flag group + tests; check-hermes-tables green.
- **Phase 2 (pre-existing bugs):** B1 skills search `--json`; B2 debug share `-y`; B3 hub sources; B4 widen t-0c0b1aa7; B5 dead field/doc cleanup; B6/B7 provider and image-gen lists + script lane 4.
- **Phase 3 (adopt):** C1–C8 in rank order; C9 config keys as a Settings batch.
- **Decide:** A10 (FTS 8KB ceiling: LIKE fallback or a note in search UI) and A11 (auto-prune surfacing) are product calls.
