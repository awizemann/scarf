# T2-sessions-insights — verdict: WORKS-WITH-ISSUES

Hermes ref: `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (live `hermes --version`: v0.21.5 (2026.9.24)).
Code: `/Users/awizemann/Developer/Scarf-wt/integration` @ 8b311060.

The Hermes-facing contract of this section is sound at the tag. Every state.db column and table Scarf reads exists, and schema
detection uses PRAGMA/sqlite_master only. The list predicate now exactly ports `_session_filter_where` + `hidden = 0`
(listable-child, `_delegate_from IS NULL`, `archived = 0`), with the `json_valid` guard. Compression-tip projection mirrors
`_project_compression_tips`. Chain walk mirrors `_CHAIN_STEP_SQL`. Search visibility (`active=1 OR compacted=1`,
`display_kind <> 'hidden'`) matches `_search_filter_clauses`. Usage sums match `hermes insights`' population and reconciliation.
Delete, rename and export argv match argparse (live `--help`), and exit codes propagate (`main.py:3614-3617`).
The three findings are app-side: a crash on a registry state the app itself can create, failure-as-empty on two
pages, and a preview population mismatch. S04-F1..F4 are all remediated in the current code.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Sessions tab list + quick/project filters (local & SSH) | DEGRADED | F1 (crash), F2 (failure shown as empty) |
| 2 | Open a session / transcript across a rotated compression lineage | WORKS | — |
| 3 | Search (FTS phrase + deep tool-content top-up + rebuild note) and search-hit open (archived / subagent / middle segment) | WORKS | — |
| 4 | Rename (`sessions rename -- <id> <title>`) | WORKS | — |
| 5 | Delete incl. chain delete (`sessions delete --yes -- <id>` tip→root) | WORKS | — |
| 6 | Export single / all (stdout jsonl/trace; path html/md/qmd local only) | WORKS | chain export = tip segment only (TRACKED) |
| 7 | Mac Dashboard (7-day stats, recent sessions, recent tool calls, by-model all-time) | WORKS | F3 (P3 previews) |
| 8 | Insights (conversation population + uncapped usage aggregates, tool histogram, notable sessions → open) | WORKS | F2 (failure shown as zeros) |
| 9 | Project attribution sidecar + Project Sessions list | DEGRADED | F1, F2 |
| 10 | iOS Dashboard (open error banner, checked fetches, previews, attribution) | DEGRADED | F1, F3 |

## Findings

### T2-sessions-insights-F1 · P1 · SOURCE · NEW
- Claim: two registry projects that share a path crash the app when Sessions / chat sidebar / iOS Dashboard load. The cause is `Dictionary(uniqueKeysWithValues:)` over `registry.projects.map { ($0.path, $0.name) }`, which traps on a duplicate key. The app's own Add Project flow can create that registry state.
- Scarf: `scarf/scarf/Features/Sessions/ViewModels/SessionsViewModel.swift:406-408` (inside `loadImpl`'s OffPool batch, runs on every Sessions load/watcher tick); `scarf/Packages/ScarfIOS/Sources/ScarfIOS/IOSDashboardViewModel.swift:129-131`; same pattern outside this manifest at `scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:2973-2975` (chat sidebar `loadRecentSessions`). Cause: `ProjectsViewModel.addProject` (`scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectsViewModel.swift:430-442`) rejects only a duplicate NAME, never a duplicate path, and the template installer `registerProjectLocked` (`scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:396-407`) appends without a path check. `ProjectRegistry` decoding does not dedupe. The codebase already expects duplicates: the Project Doctor reports `duplicatePath` (`ProjectDoctorService.swift:403-417`), and `ProjectMenuProbeCache.swift:111-117` uses `uniquingKeysWith` for exactly this reason.
- Hermes @v2026.9.24: n/a. This is Scarf-owned state (`~/.hermes/scarf/projects.json`).
- Failure scenario: the user adds folder `/Users/me/app` as "App", and later adds the same folder again as "App (work)", or hand-edits `projects.json` the way the Doctor anticipates. The next Sessions tab load (and the chat sidebar refresh, which runs on the watcher) hits a Swift runtime trap, "Fatal error: Duplicate values for key", and the app crashes. It keeps crashing on relaunch until the user edits `projects.json` by hand. The iOS Dashboard crashes the same way against that server.
- Evidence: `let pathToName = Dictionary(uniqueKeysWithValues: registry.projects.map { ($0.path, $0.name) })` at all three sites. `addProject` has `guard !registry.projects.contains(where: { $0.name == name })` and no path guard.
- Suggested fix: use `Dictionary(_:uniquingKeysWith: { first, _ in first })` at the three sites. Optionally also refuse a duplicate normalized path in `addProject`.

### T2-sessions-insights-F2 · P2 · SOURCE · NEW
- Claim: the Sessions tab, Insights and Project Sessions show a failed state.db read as an empty or zero result, with no banner. The Dashboard and iOS Dashboard already surface the same failures.
- Scarf:
  - Sessions tab: `SessionsViewModel.swift:382` (`guard opened else { return }`, no error kept), and `HermesDataService.swift:2550-2553` (`sessionListSnapshot` catch returns `SessionListSnapshot(sessions: [], previews: [:])`). The empty list then renders `SessionsView.swift:418` "No sessions match this filter." and the header reads "0 sessions · 0 messages".
  - Insights: `InsightsViewModel.swift:158-161` (open failure: stops loading, no message), and `HermesDataService.swift:553-569/699-700/2646-2647` (`fetchSessionsInPeriod`, `fetchUsageAggregatesInPeriod` and `insightsSnapshot` all return empty on error). The Overview cards then show 0 sessions and $0.00 or "—".
  - Project Sessions: `ProjectSessionsViewModel.swift:98` ignores `refresh()`, and `:107` uses the non-checked `fetchSessions`, so a failure produces the hint "…none are in the recent history. They may have been deleted from Hermes."
- Hermes @v2026.9.24: n/a (read path). The trigger is the open/query failures `HermesDataService` already classifies: `lastOpenError`, `lastOpenErrorKind == .sqlite3Missing` (gh#141), and `QueryFailure`.
- Failure scenario: a remote host without `sqlite3`, an SSH timeout on the 500-row batch, or a permission-denied state.db. The Dashboard shows "sqlite3 is not installed on host…". The Sessions tab says there are no sessions matching the filter, Insights reports zero usage for the period, and Project Sessions claims the project's chats may have been deleted. A transient remote failure during a watcher tick also wipes an already-populated Sessions list until the next tick.
- Evidence: the `…Checked` API and `QueryFailure` exist precisely because "a failed session list [rendered] as 'No sessions yet'" (`HermesDataService.swift` QueryFailure doc). Only the iOS Dashboard uses them (`IOSDashboardViewModel.swift:103-104`), and the Mac Dashboard has its own `queryError`.
- Suggested fix: carry `lastOpenError` and a query-failure string through `sessionListSnapshot` and the Insights fetches, like `DashboardSnapshot.queryError`, and show the existing banner. On failure, keep the previous rows instead of assigning `[]`.

### T2-sessions-insights-F3 · P3 · SOURCE · NEW
- Claim: the Dashboard's recent sessions (Mac, 5 rows) and the iOS Dashboard (25 rows) get their previews from a different population than the rows they label. The preview query is "the newest N first-user-message rows across every session", which includes delegate subagents, hidden and archived rows. Untitled listed rows can therefore show the raw session id instead of their opening line.
- Scarf: `HermesDataService.swift:2417-2427` (`dashboardSnapshot` preview statement, `ORDER BY m.timestamp DESC LIMIT previewLimit`; `DashboardViewModel.swift:100` passes 5); `IOSDashboardViewModel.swift:113` (`fetchSessionPreviews(limit: 25)`); `SessionPreviewSQL.swift` `firstEligibleUserRowSQL(hasActiveColumn:…)` has no session filter. The Sessions tab (`sessionListSnapshot`, 500/500) has the same shape but a far wider window.
- Hermes @v2026.9.24: Hermes computes the preview per listed row (`_PREVIEW_RAW_SUBQUERY_SQL`, `hermes_state_common.py:163-165`, correlated on `s.id`). A delegate child persists its own user turn (`tools/delegate_tool.py:246,277`, which gives the child its own session row).
- Failure scenario: an agent that delegates creates subagent sessions whose goal messages are newer than an untitled top-level session's first message. That session's Dashboard row shows its UUID. The fix already exists for Insights and Activity (decision note `section-audit-remediation-2026-09.md:88`): `fetchSessionPreviews(sessionIds:)`.
- Suggested fix: fetch previews for the listed ids (`fetchSessionPreviews(sessionIds:)`) after the batch, as Insights does.

### TRACKED items confirmed still present (not re-filed)
- A chain row exports only the tip segment: `SessionsViewModel.swift:752-758` passes `session.id` (the tip). Hermes `--lineage logical` exists only for md/qmd (`hermes_cli/sessions_cmd.py:501-537`). Tracked in `tasks/t-86bb3d9f.md` (R11 carry-over "chain delete/export act on tip only (export could use --lineage logical)"). Delete has since been fixed.
- Transcripts show the active set only, while search also admits `compacted=1` rows: S04 obs O1 / `HermesDataService` comment "O1 decision".
- The Insights conversation population is capped at `QueryDefaults.periodSessionLimit` (the Sessions card and Notable Sessions). This is deliberate: `section-audit-remediation-2026-09.md:86`.
- Project Sessions scans only the 200 newest sessions: an accepted roadmap limit stated in `ProjectSessionsViewModel.swift` comments.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| sessions cols id…estimated_cost_usd, reasoning_tokens, actual/cost_status/billing_provider, api_call_count, rewind_count, pinned/last_activity_*, last_read_at | SQL cols | HermesDataService.swift:268-306 | hermes_state_common.py:336-398 | OK |
| `last_active` expression (MAX(last_activity_at, MAX(messages.timestamp)) ?? started_at) | SQL | HermesDataService.swift:309-319 | hermes_state_common.py (`_sql_session_last_active`) | OK |
| list predicate: listable child + `_delegate_from IS NULL` + `archived = 0` + `hidden = 0`, json_valid guard | SQL | HermesDataService.swift:366-384, 388-417 | hermes_state_sessions.py:94-127, 1276-1283; hermes_state_common.py:67-74, 139-209 | OK |
| subagent child predicate (not branch/compression/reset) | SQL | HermesDataService.swift:419-433 | hermes_state_common.py:178-190 | OK |
| messages cols id…finish_reason, reasoning, reasoning_content, active, compacted, display_kind | SQL cols | HermesDataService.swift:435-510, 1300-1330 | hermes_state_common.py (messages DDL) | OK |
| transcript fetch (active=1, display_kind≠hidden, multi-id lineage, skeleton + hydration + tool-range) | SQL | HermesDataService.swift:780-1127 | hermes_state_messages.py:1273-1293 | OK |
| `fetchReasoningContent` lazy | SQL | :1129-1139 | — | OK |
| FTS search `messages_fts MATCH` + `(active=1 OR compacted=1)` + display_kind | SQL | :1165-1230 | hermes_state_search.py:137-162 | OK |
| `state_meta` keys fts_tool_full_content_high_water / fts_rebuild_high_water / fts_rebuild_progress; `messages_fts_src` layout probe; 8192 prefix | SQL | :1238-1270, 1402-1430; HermesSearchIndex.swift:23-85 | hermes_state_common.py:257-272, 702-726; hermes_state_schema.py:139, 283-294; hermes_state_search.py:208-222, 459-490 | OK |
| deep tool-content LIKE top-up (bounded scan) | SQL | :1334-1380 | (Scarf-side fallback over the same rows) | OK |
| previews: carrier-aware first eligible user row | SQL | SessionPreviewSQL.swift (all); HermesDataService.swift:1541-1660 | hermes_state_common.py:91-165; agent/context_compressor.py:251-292, 479-484 | OK (population F3) |
| compression chain step / recursive chains / tip projection | SQL | HermesDataService.swift:1940-2105; HermesSession.swift:201-236 | hermes_state_compression.py:29-49; hermes_state_sessions.py:1028-1065 | OK |
| search-hit resolution (`fetchSessionForDetail`, archived probe) | SQL | :1763-1800 | hermes_state_sessions.py:124-127 | OK |
| usage aggregates (GROUP BY model/source/cost_status, per-session MAX(session, SUM(session_model_usage))) | SQL | :654-744 | agent/insights.py:92-96, 271-368; hermes_state_common.py:431-451 | OK |
| stats: list COUNT + usage SUMs, `since` bound | SQL | :2258-2285 | agent/insights.py:92-96 | OK |
| by-model all-time `session_model_usage` GROUP BY | SQL | :2346-2353 | hermes_state_common.py:431-451 | OK |
| insights: user-msg count, tool_name histogram, start-hour histogram | SQL | :2578-2650 | agent/insights.py:108-137 | OK |
| Dashboard recent tool calls (light cols, active=1) | SQL | :2428-2440 | — | OK |
| canonical Bot Chat title lookup (hidden included) + compressionTip | SQL | :1860-1935, 2125-2140 | hermes_state_sessions.py (UNIQUE title); hermes_state_compression.py:29-49 | OK |
| PRAGMA table_info(sessions/messages), sqlite_master session_model_usage, JSON1 probe | schema | LocalSQLiteBackend.swift (detectSchema); RemoteSQLiteBackend.swift (parsePreflightOutput) | hermes_state_common.py DDL | OK |
| local open READONLY → CANTOPEN → READWRITE + NO_CKPT_ON_CLOSE + query_only | file | LocalSQLiteBackend.swift (open/openQueryOnlyFallback) | charter C3 | OK |
| remote `sqlite3 -readonly -json` / relaxed `.dbconfig no_ckpt_on_close on` + `PRAGMA query_only=1`, 30 s timeouts, batch markers, `$HOME` quoting | SSH/SQL | RemoteSQLiteBackend.swift (open/query/queryBatch/runSQLite/quoteForRemoteShell) | — | OK |
| `~/.hermes/state.db` (+ `-wal` stat) under profile HERMES_HOME | file | HermesPathSet.swift:67; HermesDataService.swift:2653-2662 | hermes_state.py:188-191 | OK |
| `hermes sessions rename -- <id> <title>` | argv | SessionsViewModel.swift:524-526 | hermes_cli/subcommands/sessions.py; sessions_cmd.py:726-744 | OK |
| `hermes sessions delete --yes -- <id>` (per lineage id, tip first) | argv | SessionsViewModel.swift:535-537, 652-700; SessionChainDelete.swift | sessions_cmd.py:575-590; hermes_state_sessions.py:1543-1577; main.py:3614-3617 (live --help) | OK |
| `hermes sessions export <out|-> [--format] [--redact|--no-redact] [--session-id]` + stdout payload validation + path verdict | argv | SessionsViewModel.swift:895-1070 | sessions_cmd.py:317-364 (live --help) | OK (chain = TRACKED) |
| `~/.hermes/scarf/session_project_map.json` (Scarf sidecar, guarded read/locked write, prune) | file | SessionAttributionService.swift; SessionProjectMap.swift | — (Scarf-owned) | OK |
| `~/.hermes/scarf/projects.json` → path→name map | file | SessionsViewModel.swift:406-408; IOSDashboardViewModel.swift:129-131 | — (Scarf-owned) | FINDING-F1 |
| SessionLineageIndex (in-memory lineage → attribution) | internal | SessionLineageIndex.swift | — | OK |
| Sessions/Insights/ProjectSessions failure presentation | UI | SessionsViewModel.swift:382; InsightsViewModel.swift:158-161; ProjectSessionsViewModel.swift:98,107 | — | FINDING-F2 |
| Dashboard / iOS preview population | SQL/UI | HermesDataService.swift:2417-2427; IOSDashboardViewModel.swift:113 | hermes_state_common.py:163-165 | FINDING-F3 |

## Not audited / couldn't verify
- Live remote (SSH) behaviour was traced from source only. No remote host was probed, and no state.db was queried (brief: read-only, no DB access needed).
- DashboardView.swift / InsightsView.swift / SessionsView.swift were read for data wiring and navigation. Pure layout and accessibility were not reviewed (out of scope).
- iOS Dashboard's view-layer labeling of `fetchStats()` (all-time) was not audited; the view file is not in this manifest.
- Edge case noted and dropped as exotic: a search hit inside a delegate subagent of a rotation-mode compressed parent resolves to the parent chain (`fetchSessionForDetail` walks up through any compression-ended parent without checking that the child is a continuation). This needs non-default `compression.in_place: false`.
- Mixed actual/estimated cost on the Mac Dashboard card (`DashboardView.swift:199`, aggregate-level ternary). I dropped it because the agent loop never writes `actual_cost_usd` (`agent/turn_usage.py:256-272` passes only `estimated_cost_usd`), so the mixed case is not reachable on a mainstream setup.
