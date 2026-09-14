---
title: Hermes v0.16 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-16-compatibility-decisions
tags: [hermes, capabilities, v016, compatibility]
created: 2026-06-14
updated: 2026-09-12
---

## Observations
- [target] Scarf targets Hermes v0.16.0 (v2026.6.5) as of 2026-06-13. v0.15.x and earlier remain fully supported; every v0.16 surface is capability-gated or schema-detected so older hosts render byte-identical. Shipped on branch `feat/hermes-v016-parity` (commit 82ae046): build SUCCEEDED, 621/621 ScarfCore tests. #target
- [schema] v0.16 is the FIRST state.db schema change since v0.11: `messages` gained `active INTEGER NOT NULL DEFAULT 1` (soft-delete). `/undo [N]` flips rewound messages to active=0 and bumps `sessions.rewind_count`. Scarf MUST filter `AND active = 1` on EVERY message-read path, SCHEMA-GATED via `hasMessagesActiveColumn` (LocalSQLiteBackend PRAGMA / RemoteSQLiteBackend preflight) so pre-v0.16 DBs don't throw "no such column". Without it Scarf shows messages the agent has discarded. SQL-shape tests follow the convention in [[Hermes thinking models persist reasoning_content but leave the legacy reasoning column NULL]]. #schema #gotcha
- [acp] v0.16 ACP adds a `session_info_update` notification (session_update discriminator; wire fields `title` + `updatedAt` aliased from `updated_at`), pushed when Hermes (re)generates a session title. There is NO ACP set-title RPC — title-setting is CLI/gateway only. Scarf parses it to `ACPEvent.sessionInfoUpdate` and live-updates the Mac sidebar (`ChatViewModel`); the shared `RichChatViewModel` no-ops it; iOS needs no wiring (static "Chat" header, no co-visible title list, dashboard reloads on appear). #acp
- [cli] New verbs: `hermes sessions rename <id> <title...>` (the ONLY rename path — Scarf already drove it; now gated on `hasSessionsRename`), `hermes sessions optimize` (FTS merge + VACUUM), `hermes insights`, `hermes dashboard`/`desktop`/`gui`, `hermes claw`, `hermes portal`. Flags added: `hasSessionsRename`, `hasSessionsOptimize`, `hasKanbanGoalMode`, `hasInsightsCommand`, `hasDashboardCommand`, `isV016OrLater`. **Two of those floors were wrong and were corrected by P49's re-walk (round 5, `c718237d`, 2026-09-12): `hasInsightsCommand` is DELETED (`hermes insights` is `hermes_cli/main.py:4634` @ v2026.3.30 = 0.6.0, below Scarf's supported minimum, so the flag encoded nothing) and `hasDashboardCommand` re-floored 0.16 → **0.9.0** (`hermes_cli/main.py:4458` @ v2026.4.13 = 0.9.0, absent at v2026.4.8 = 0.8.0). `hasSessionsRename` had already been deleted in P23.** Both survived wrong because nothing read them. #cli
- [skills] `spotify` is NO LONGER a skill — it became a built-in TOOL + native plugin (`plugins/spotify`); `hermes auth spotify` (PKCE) is unchanged. Scarf's SkillsView `name=="spotify"` special-case renders nothing on v0.16, so the sign-in affordance moved to PluginsView (gated `isV016OrLater`); SkillsView path kept for older hosts. #skills
- [catalog] Only `bedrock` was genuinely missing from `overlayOnlyProviders` (absent from models_dev_cache.json). The other v0.16 providers (xiaomi, stepfun, kimi-for-coding, ollama-cloud, opencode/-go, kilo, minimax-cn, alibaba-coding-plan) self-surface from the cache — NO Scarf entry needed. New models (deepseek-v4-flash, MiniMax-M3 [512K ctx, NOT 1M as the release notes claimed], qwen3.7-plus, gemini-3.5-flash) flow automatically. `mistral` stays un-demoted. Upstream catalog TTL is now hourly (`model_catalog.ttl_hours=1`). #catalog
- [non-issues] Release-notes items that do NOT affect Scarf: `--tui` removal (never used), "progressive tool disclosure" (`hermes tools list` output unchanged — verified live), read_file compact gutter (Scarf renders tool output opaquely), CVE-2026-48710/Starlette (server-side), `display.language` (already gated since v0.13). #non-issues
- [deferred] Additive v0.16 surfaces NOT yet built (P2): sessions-optimize maintenance action, kanban goal_mode/goal_max_turns badge, sessions.rewind_count indicator, insights/dashboard affordances, kanban run-terminate (REST `/runs/{id}/terminate` only — no CLI verb, and Scarf's kanban is CLI/SQLite). #deferred

## Relations
- supersedes [[Hermes v0.15 Capability Gating Decisions]]
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes Integration]]
- relates_to [[Hermes thinking models persist reasoning_content but leave the legacy reasoning column NULL]]
