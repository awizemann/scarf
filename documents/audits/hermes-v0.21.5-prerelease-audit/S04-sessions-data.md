# S04-sessions-data — verdict: WORKS-WITH-ISSUES

Only one real defect found, and it is minor (P2). Every state.db read checked below matches the DDL at the tag. The read-only guarantees hold locally and over SSH, and the rename/delete argv match `--help` at 0.21.5.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Open state.db, detect schema, read-only (local) | WORKS | — |
| 2 | Same over SSH (sqlite3 -json preflight, JSON1 probe, quoting, query_only fallback) | WORKS | — |
| 3 | Sessions list (listing predicate, compression-tip projection, previews, project filter, Today/Starred) | WORKS | — |
| 4 | Transcript (active/compacted rows, generation dedupe, model_only/hidden display filter, lineage) | WORKS | — |
| 5 | Full-text search (messages_fts MATCH + deep tool-content top-up, rebuild notice) | WORKS | — |
| 6 | Rename (`sessions rename -- id title`) | WORKS | — |
| 7 | Delete, including compression chains (`sessions delete --yes -- id`, tip first) | WORKS | — |
| 8 | Export, one session (jsonl/trace to stdout, then written on the Mac; md/qmd/html to a path, judged by output markers) | WORKS | — |
| 9 | Export All | DEGRADED | F1 |
| 10 | Mac Dashboard (7-day stats, recent sessions, tool activity, per-model usage) | WORKS | — |
| 11 | Insights (usage aggregates, tool histogram, start-hour histogram) and Activity feed | WORKS | — |
| 12 | Session→project attribution (Scarf sidecar) | WORKS | — |
| 13 | iOS Dashboard | WORKS | — |

## Findings

### S04-sessions-data-F1 · P2 · SOURCE · NEW
- **Claim:** Export All offers Markdown and Quarto on a local host, but Hermes always refuses a bulk md/qmd export with no filter, so those two picker choices can never succeed.
- **Scarf:**
  - `scarf/scarf/Features/Sessions/ViewModels/SessionsViewModel.swift:756-764` (`availableExportFormats` removes only `trace` for Export All)
  - `:978-985` (`exportArguments` passes no filter when `sessionId == nil`)
  - `scarf/scarf/Features/Sessions/Views/SessionsView.swift:168,651`
- **Hermes @v2026.9.24:** `hermes_cli/sessions_cmd.py:497-500` (`_export_markdown`): with no `--session-id` and no filter it prints "Refusing bulk export without a filter. Pass --session-id or at least one filter …" and does a bare `return`, so the exit code is 0.
- **Failure scenario:** On a local host the user clicks Export All, picks Markdown, and chooses a folder. The banner says "Export failed: Refusing bulk export without a filter…". This is reported honestly: the refusal is in `HermesCLIMarkers.sessionsExportFailure` (`HermesCLIOutcome.swift:655`). But the option can never work, and the message asks for flags the UI has no way to supply.
- **Evidence:** `hermes sessions export --help` (live) says md/qmd take a directory, one file per session. The code path is quoted above. Nothing about it in TASKS.md, `tasks/` or `.memory/decisions/`.
- **Suggested fix:** Remove `.markdown` and `.quarto` for Export All, the same way `trace` is removed. Alternatively, pass a match-everything filter such as `--min-messages 0`, after checking that `build_prune_filters` treats it as a filter.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| Models/HermesMessage.swift | yes (`tool_calls` JSON shape `{id, function{name, arguments}}`) | OK |
| Models/HermesSession.swift | yes (session columns and cost fields) | OK |
| Models/SessionProjectMap.swift | no (Scarf sidecar) | NO-TOUCHPOINT |
| Backends/HermesQueryBackend.swift | no (protocol) | NO-TOUCHPOINT |
| Backends/LocalSQLiteBackend.swift | yes (READONLY open; query_only + NO_CKPT_ON_CLOSE fallback; `PRAGMA table_info`; sqlite_master) | OK |
| Backends/RemoteSQLiteBackend.swift | yes (`sqlite3 -readonly -json`, preflight, JSON1 probe, heredoc, quoting) | OK |
| Backends/SQLValue.swift | no | NO-TOUCHPOINT |
| Backends/SQLValueInliner.swift | yes (literal encoding for remote SQL) | OK |
| Services/HermesDataService.swift | yes (all SQL) | OK |
| Services/HermesDatabaseScripts.swift | yes (read-only snapshot via VACUUM INTO / .backup / python `mode=ro`) | OK |
| Services/HermesSearchIndex.swift | yes (state_meta keys, `messages_fts_src`, 8192) | OK |
| Services/HermesSessionRenameCommand.swift | yes (argv) | OK |
| Services/SessionAttributionService.swift | no (Scarf sidecar under `paths.sessionProjectMap`) | NO-TOUCHPOINT |
| Services/SessionChainDelete.swift | yes (delete exit codes) | OK |
| Services/SessionLineageIndex.swift | no | NO-TOUCHPOINT |
| Services/SessionPreviewSQL.swift | yes (compaction markers, display_kind) | OK |
| Services/SessionRenameFailure.swift | yes (error text markers) | OK |
| ViewModels/ActivityViewModel.swift | yes (through the data service) | OK |
| ViewModels/InsightsViewModel.swift | yes (through the data service) | OK |
| ScarfIOS/IOSDashboardViewModel.swift | yes (through the data service) | OK |
| Scarf iOS/Dashboard/DashboardView.swift | no (view) | NO-TOUCHPOINT |
| scarf/Core/Services/UsageEvent.swift | no (telemetry enum) | NO-TOUCHPOINT |
| Features/Activity/Views/ActivityView.swift | no (view) | NO-TOUCHPOINT |
| Features/Dashboard/ViewModels/DashboardViewModel.swift | yes (dashboardSnapshot, 7-day window) | OK |
| Features/Dashboard/Views/DashboardView.swift | no (the "By model · all time" label is correct) | NO-TOUCHPOINT |
| Features/Insights/Views/InsightsView.swift | no (view) | NO-TOUCHPOINT |
| Features/Sessions/ViewModels/SessionsViewModel.swift | yes (rename/delete/export argv and verdicts) | FINDING-F1 |
| Features/Sessions/Views/SessionDetailView.swift | no (view) | NO-TOUCHPOINT |
| Features/Sessions/Views/SessionsView.swift | no (drives F1) | FINDING-F1 |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes | Status |
|---|---|---|---|---|
| sessions columns (id, source, user_id, model, title, parent_session_id, started_at, ended_at, end_reason, message_count, tool_call_count, token and cost columns, reasoning_tokens, cost_status, billing_provider, api_call_count, rewind_count, pinned, last_activity_at/_description, last_read_at, archived, hidden, model_config, session_key) | SQL | HermesDataService.swift:254-332 | hermes_state_common.py:338-404 | OK |
| messages columns (id … finish_reason, reasoning, reasoning_content, active, compacted, display_kind, display_metadata, _compressed_summary) | SQL | HermesDataService.swift:474-540 | hermes_state_common.py:406-433 | OK |
| session_model_usage | SQL | HermesDataService.swift:852-873, 2625-2632 | hermes_state_common.py:435-455 | OK |
| state_meta (fts_tool_full_content_high_water, fts_rebuild_*) | SQL | HermesDataService.swift:1397,1658 | hermes_state_schema.py:136-139; hermes_state_common.py:686-734 | OK |
| messages_fts MATCH; `messages_fts_src` detection | SQL | HermesDataService.swift:1341-1346,1418 | hermes_state_common.py:715-728 | OK |
| Listing predicate (listable child, `_delegate_from`, archived, hidden, INTERNAL_LISTING_SOURCES) | SQL | HermesDataService.swift:381-455 | hermes_state_sessions.py:103-127,173; hermes_state_common.py:139-190 | OK |
| Preview compaction markers | SQL | SessionPreviewSQL.swift:89-109 | agent/context_compressor.py:251-292,479-484; hermes_state_common.py:97 | OK |
| Insights usage and tool counts | SQL | HermesDataService.swift:2870-2895 | agent/insights.py:94-140 | OK |
| Read-only open and no checkpoint (local) | SQLite | LocalSQLiteBackend.swift:78-190 | — | OK |
| Read-only and no checkpoint (remote) | shell/sqlite3 | RemoteSQLiteBackend.swift:754-850 | — | OK |
| `sessions rename -- <id> <title>` | argv | HermesSessionRenameCommand.swift:14 | sessions_cmd.py:726-744 (exits 1 on every failure); live `--help` | OK |
| `sessions delete --yes -- <id>` | argv | SessionsViewModel.swift:613 | sessions_cmd.py:575-588; main.py:3616-3618; live `--help` | OK |
| `sessions export - [--format trace] [--redact / --no-redact] --session-id` | argv | SessionsViewModel.swift:978-985 | sessions_cmd.py:317-470, 89-96 | OK (stdout payload validated as JSON) |
| `sessions export <path> --format md/qmd/html [--lineage logical]` | argv | SessionsViewModel.swift:1116-1160 | sessions_cmd.py:472-520 | OK for one session; FINDING-F1 for Export All with md/qmd |
| ~/.hermes/scarf/session_project_map.json | file (Scarf-owned) | SessionAttributionService.swift | — | OK |
| state.db and state.db-wal mtime | stat | HermesDataService.swift:2922-2930 | — | OK |

## Not audited / couldn't verify
- HermesDataService.swift was read in full at its query and predicate builders. The row-parsing helpers (lines 2950-3169) and the tool-call hydration paths (1000-1270) were only skimmed. They are position/name reads matched to the SELECT shapes checked above.
- I did not check whether `HermesPathSet.home` resolves correctly for named profiles. That belongs to another section; this section just uses `paths.stateDB`.
- Search uses only the word index (`messages_fts`), not Hermes's trigram index. This could matter for CJK or substring queries; it is judged a design choice, not a defect.
- Delete and rename failure banners show the exit code, or the last output line, rather than Hermes's "No session …" text. This is cosmetic, so not raised.
- The iOS Dashboard's "Activity" stat cards are all-time totals (`fetchStats()` with no bound). They are labelled neutrally, so this is not misleading.
