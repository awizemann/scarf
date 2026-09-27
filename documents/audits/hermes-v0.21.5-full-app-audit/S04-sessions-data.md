# S04-sessions-data — verdict: WORKS-WITH-ISSUES

Hermes ref: `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (0.21.5, SCHEMA_VERSION 30, `hermes_state_common.py:239`).
DDL now lives in `hermes_state_common.py:328-460` (sessions/messages/session_model_usage/state_meta) and FTS in `:700-900`.
Every column Scarf SELECTs exists at the tag with the type/meaning Scarf assumes. Read-only open is correct on both
backends (local READONLY, query_only+NO_CKPT_ON_CLOSE fallback; remote `sqlite3 -readonly -json`, relaxed form with
`.dbconfig no_ckpt_on_close on` probe + existence guard). CLI verbs (rename/delete/export) match argparse and exit codes.
The issues are all about *which rows* Scarf shows/sums vs Hermes's own listing semantics — none is P0/P1.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Sessions list + quick/project filters (local & SSH) | DEGRADED | F1, F3 |
| 2 | Open a session transcript (skeleton/tool hydration/reasoning lazy-load) | WORKS | F4 (minor), obs. O1 |
| 3 | Search (FTS5 phrase-quoted + deep tool-content LIKE top-up, rebuild status) | WORKS | F4 (minor) |
| 4 | Rename session (`sessions rename -- <id> <title>`) | WORKS | — |
| 5 | Delete session (`sessions delete --yes -- <id>`) | WORKS | — |
| 6 | Export session / export all (stdout jsonl/trace; path html/md/qmd local only) | WORKS | — |
| 7 | Dashboard stats + recent sessions + recent tool calls + By-model (Mac) | DEGRADED | F2, F1 |
| 8 | Insights (period sessions + insightsSnapshot; Scarf does NOT call `hermes insights`) | DEGRADED | F2 |
| 9 | Activity feed (tool-call skeleton + hydrate) | WORKS | — |
| 10 | Session→project attribution (sidecar `~/.hermes/scarf/session_project_map.json`) | WORKS | obs. O2 |
| 11 | iOS Dashboard (fetchStats all-time, fetchSessionsChecked, previews, attribution) | DEGRADED | F1, F2 |

## Findings

### S04-sessions-data-F1 · P2 · SOURCE · NEW
- Claim: Scarf's session-list predicate omits Hermes's `archived = 0` and `_delegate_from IS NULL` clauses, so sessions the user archived (and orphaned delegate-subagent rows) keep appearing in every Scarf list and aggregate while Hermes hides them.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift:339-354` (`sessionListPredicate` = listable-child + `hidden = 0` only); used by `fetchSessionsChecked` :469, `fetchSessionsInPeriod` :491, `statsSQL` :1714-1733, `dashboardSnapshot` :1867, `sessionListSnapshot` :1964, `insightsSnapshot` :2030-2060. No `archived` handling anywhere in Scarf Swift sources (grep).
- Hermes @v2026.9.24: `hermes_state_sessions.py:103-104` (`exclude_children` adds `_LISTABLE_CHILD_SQL` AND `_delegate_from IS NULL`), `:124-127` (`s.archived = 0` unless include/only archived), `:1281-1282` (`s.hidden = 0`); DDL `hermes_state_common.py:394` (`archived INTEGER NOT NULL DEFAULT 0`); writer `hermes_state_sessions.py:905-907` `set_session_archived` ("Soft-hide … a session and its compression lineage"); CLI `hermes sessions archive` (live `--help`: "Bulk-archive (soft-hide) sessions matching filters"), plus desktop/web dashboard archive (`hermes_cli/web_routers/sessions.py`) and ws-orphan-reap auto-archive (`unarchive_recoverable_session` :909-921). Orphaned delegate roots tagged by migration v16 `hermes_state_schema.py:1011-1027` (`'$._delegate_from' = '__orphaned__'`).
- Failure scenario: user archives 40 old sessions via `hermes sessions archive --older-than 30d` or the Hermes desktop/web UI → Hermes's list/TUI/desktop no longer show them; Scarf's Sessions tab, chat sidebar, Dashboard recent list, iOS Dashboard and stat totals still list/count them, so Scarf and Hermes disagree about what exists. Same for rows Hermes tagged `_delegate_from='__orphaned__'` (tool-only subagent leftovers) which Scarf shows as untitled roots.
- Evidence: Hermes `where.append("s.archived = 0")` (sessions.py:127); Scarf predicate has no equivalent.
- Suggested fix: PRAGMA-detect `sessions.archived` and append `s.archived = 0` plus `json_extract(COALESCE(s.model_config,'{}'),'$._delegate_from') IS NULL` inside `sessionListPredicate` (optionally an "Archived" filter pill).

### S04-sessions-data-F2 · P2 · SOURCE · NEW (interacts with decision `.memory/decisions/section-audit-remediation-2026-09.md:81-83`)
- Claim: Dashboard stat cards, Insights totals (tokens, cost, messages, tool calls) and the Insights tool histogram sum only listable sessions, so all spend/tokens/tool calls recorded on delegate-subagent sessions (and rotated compression continuations) are silently dropped; `hermes insights` counts them.
- Scarf: `HermesDataService.swift:1714-1733` (`statsSQL … FROM sessionListFrom WHERE sessionListPredicate`), `:491` (`fetchSessionsInPeriod`), `:2034-2050` (insights tool/user-message counts joined through the same predicate); `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/InsightsViewModel.swift:159,190-198` (totals = reduce over periodSessions); iOS `IOSDashboardViewModel.swift:99`.
- Hermes @v2026.9.24: token/cost counters accrue per `session_id` (`hermes_state_usage.py:275-304`, `update_token_counts`); a delegated subagent runs as its own session row (`tools/delegate_tool.py:246,277` — child session_db, `parent_session_id=parent_sid`, `_delegate_from`); Hermes's own analytics sum every session in the window (`agent/insights.py:95` `SELECT … FROM sessions WHERE started_at >= ?`, tool counts `:121-128` join all sessions).
- Failure scenario: a user whose agent uses `delegate_task` → every subagent's tokens and cost are excluded from Scarf's "Last 7 days" Cost/Tokens cards and Insights Total Cost, while `hermes insights` (and the "By model · all time" section, which reads `session_model_usage` for all sessions, :1796-1804) include them. Scarf under-reports spend with no "partial" marker.
- Evidence: decision note records the rule "every aggregate on a page must run the SAME population predicate as the list" — that fixed count consistency but made money/token sums omit child sessions; it does not discuss this consequence, so filed as NEW for the maintainer to weigh.
- Suggested fix: keep COUNT(*) on the list predicate, but compute SUM(tokens/cost/tool_call_count) over all non-hidden, non-archived sessions whose root is in the window (or label the cards "top-level sessions only").

### S04-sessions-data-F3 · P2 · SOURCE · NEW
- Claim: for a rotated compression chain, Scarf lists the ended root row (its id, end_reason 'compression', stale counts/title) and opens only the pre-compression transcript; the continuation holding every later turn is excluded from all lists and is unreachable in the Sessions tab. Hermes projects each root onto its live tip.
- Scarf: `HermesDataService.swift:339-354` (continuations excluded, correctly), but no tip projection anywhere except Bot Chat (`compressionTip(for:)` :1520, only caller `locateCanonicalBotChat` :1585); `scarf/scarf/Features/Sessions/ViewModels/SessionsViewModel.swift:438-442` (`selectSession` fetches messages for the root id).
- Hermes @v2026.9.24: `hermes_state_sessions.py:1263` (`project_compression_tips: bool = True`), `:1360-1361`, `:1028-1065` (`_project_compression_tips` replaces id/ended_at/end_reason/message_count/title/preview… with the tip's).
- Failure scenario: any chain created with `compression.in_place: false` (rotation mode) or by an older Hermes before in-place became default (`agent/agent_init.py:1536-1538`, default True — hence P2 not P1) → Sessions tab shows the conversation as ended with N messages; clicking shows the transcript stopping at the compression point; later turns never appear.
- Suggested fix: after the list query, batch-resolve `end_reason='compression'` roots to their tip (Scarf already ports the walk in `compressionTip`) and load/display the tip, as Hermes does.

### S04-sessions-data-F4 · P3 · SOURCE · NEW
- Claim: rows Hermes marks `display_kind = 'hidden'` (model-facing scaffolding) are not filtered from Scarf transcripts, search hits, or previews; Hermes excludes them from search and previews and its TUI history.
- Scarf: `HermesDataService.swift:577-583` (fetchMessagesOutcome), `:612-617` (skeleton), `:919-927` (search), `SessionPreviewSQL.swift:289-300` (preview) — no `display_kind` reference in Scarf (grep).
- Hermes @v2026.9.24: `hermes_state_search.py:149-150` (search excludes hidden), `hermes_state_common.py:113-114` (preview excludes), `tui_gateway/session_history.py:211-213` (history skips); writers `agent/conversation_loop.py:309-311` (empty interrupted-assistant placeholder), `agent/session_persistence.py:249-252` (muted diagnostic notification replies), `tui_gateway/prompt_turn.py:1008-1009`.
- Failure scenario: gateway/TUI sessions with muted diagnostic turns or interrupted replies → Scarf's transcript shows empty assistant bubbles / diagnostic replies the user never saw; search can return them. Uncommon, cosmetic.
- Suggested fix: PRAGMA-detect `messages.display_kind` and add `COALESCE(display_kind,'') <> 'hidden'` to transcript, search and preview predicates.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| sessions cols id…estimated_cost_usd, reasoning_tokens, actual_cost_usd, cost_status, billing_provider, api_call_count, rewind_count, pinned, last_activity_at/description, last_read_at | SQL cols | HermesDataService.swift:247-284 | hermes_state_common.py:338-398 | OK |
| last_active freshest-of expression | SQL | HermesDataService.swift:302-313 | hermes_state_common.py:217-228 | OK |
| listable-child / reset-child / branch predicates | SQL | HermesDataService.swift:339-374 | hermes_state_common.py:161-201 | OK |
| hidden = 0 | SQL | HermesDataService.swift:351-353 | hermes_state_sessions.py:1281-1282 | OK |
| archived = 0 / _delegate_from IS NULL | SQL (missing) | HermesDataService.swift:339-354 | hermes_state_sessions.py:103-127 | FINDING-F1 |
| subagent child predicate | SQL | HermesDataService.swift:381-397 | hermes_state_common.py:204-207 | OK |
| messages cols id…finish_reason, reasoning, reasoning_content | SQL cols | HermesDataService.swift:399-465 | hermes_state_common.py:402-429 | OK |
| messages.active = 1 (transcripts, activity, dashboard tool calls) | SQL flag | HermesDataService.swift:577,612,799,1146,1180,1896 | hermes_state_common.py:423; search.py:761 | OK (see O1) |
| (active=1 OR compacted=1) search/preview | SQL flag | HermesDataService.swift:1021-1026; SessionPreviewSQL.swift:237-246 | hermes_state_search.py:143-148 | OK |
| display_kind hidden | SQL (missing) | — | hermes_state_search.py:149-150 | FINDING-F4 |
| messages_fts MATCH + ORDER BY rank, phrase-quoted terms | FTS | HermesDataService.swift:919-927,2305-2319 | hermes_state_common.py:714-728 | OK |
| messages_fts sqlite_master sql contains messages_fts_src | schema probe | HermesDataService.swift:980-990 | hermes_state_common.py:722-727 | OK |
| state_meta fts_tool_full_content_high_water / fts_rebuild_progress / fts_rebuild_high_water | SQL keys | HermesDataService.swift:962-968,1087-1093; HermesSearchIndex.swift:38,71-72 | hermes_state_common.py:272,734; hermes_state_dbfile.py:727 | OK |
| deep tool-content LIKE top-up (8192 prefix) | SQL | HermesDataService.swift:1028-1076 | hermes_state_common.py:272,714-720 | OK |
| session previews (carrier-aware first user row) | SQL | SessionPreviewSQL.swift:201-370 | hermes_state_common.py:96-150 | OK (F4 minor) |
| session_model_usage GROUP BY model | SQL | HermesDataService.swift:1796-1804 | hermes_state_common.py:431-451 | OK/TRACKED (label "all time", upstream audit F8) |
| stats/insights aggregates population | SQL | HermesDataService.swift:1714-1733,2030-2060 | agent/insights.py:95-150 | FINDING-F2 |
| compression tip walk (Bot Chat only) | SQL | HermesDataService.swift:1520-1570 | hermes_state_sessions.py:1028-1065 | OK / FINDING-F3 (list not projected) |
| fetchSessionByExactTitle incl. hidden | SQL | HermesDataService.swift:1470-1484 | hermes_state_schema.py:128 (unique title) | OK |
| PRAGMA table_info(sessions/messages), sqlite_master session_model_usage | schema detect | LocalSQLiteBackend.swift:311-366; RemoteSQLiteBackend.swift:158 | — | OK |
| Local open READONLY; query_only + NO_CKPT_ON_CLOSE fallback | open mode | LocalSQLiteBackend.swift:75-190 | hermes_state_wal.py (WAL) | OK |
| Remote `sqlite3 -readonly -json` / relaxed `-cmd '.dbconfig no_ckpt_on_close on'` + `PRAGMA query_only=1`, quoted heredoc, `char(n)` inlining, marker-split batches | CLI/SSH | RemoteSQLiteBackend.swift:137-330,674-800; SQLValueInliner.swift:63-215 | — | OK |
| state.db path (`<home>/state.db`, `~` expanded via probed $HOME) | path | HermesPathSet.swift:61; RemoteSQLiteBackend.swift:833-850 | — | OK |
| `hermes sessions rename -- <id> <title>` | argv | SessionsViewModel.swift:512-513,542-554 | hermes_cli/sessions_cmd.py:726-744 (exit 1 on errors); main.py:3614-3618 | OK (LIVE --help) |
| `hermes sessions delete --yes -- <id>` | argv | SessionsViewModel.swift:522-523,607-640 | sessions_cmd.py:575-590 (not-found → 1) | OK (LIVE --help) |
| `hermes sessions export - [--format jsonl|trace] [--no-redact|--redact] [--session-id X]` stdout + payload validation | argv | SessionsViewModel.swift:844-1010 | sessions_cmd.py:317-360, 70-90 | OK (LIVE --help) |
| path export html/md/qmd (local only; md/qmd = directory) | argv | SessionsViewModel.swift:686-700,799-812,893-938 | sessions_cmd.py:476-478; --help "md/qmd: a directory" | OK |
| state.db / -wal mtime stat | file | HermesDataService.swift:2098-2107 | — | OK |
| `~/.hermes/scarf/session_project_map.json` (Scarf-owned sidecar) | file | SessionAttributionService.swift:51-213; SessionProjectMap.swift | — (not a Hermes file) | OK (O2) |
| Dashboard "Last 7 days" window / "By model · all time" | UI | DashboardViewModel.swift:85-112; DashboardView.swift:271,326 | — | OK/TRACKED (upstream audit F8, t-e84e6e1c) |
| iOS Dashboard fetchStats (all-time, "Activity" header) | UI/SQL | IOSDashboardViewModel.swift:99-110; Scarf iOS/Dashboard/DashboardView.swift:170-186 | — | OK (F1/F2 apply) |

## Observations (not filed)
- O1: Transcripts are active-only by recorded decision (`documents/plans/2026-07-04-v2.16.0-release-prep.md:8`). Premise "Hermes reloads only the active set" is now only half true: in-place compaction is the default (`agent/agent_init.py:1536-1538`), Hermes's TUI display projection includes compacted turns (`tui_gateway/server.py:2865-2868`), while the web REST default excludes them (`hermes_cli/web_routers/sessions.py:600`). Scarf renders the summary carrier, so it's honest; worth revisiting (a search hit on a compacted row opens a transcript that doesn't contain it). TRACKED(decision).
- O2: `SessionProjectMap.swift` doc says state.db has no `cwd` column — stale; `sessions.cwd`/`git_repo_root` exist (`hermes_state_common.py:363-365`) and are known in `.memory/architecture/hermes-has-no-project-concept-infer-working-dirs-from.md`. Attribution via sidecar still works; sessions started outside Scarf simply stay unattributed (design).
- Starred pill = `pinned` within the 500-row window; Hermes back-fills older pins (`include_pinned`). Minor.
- `selectSessionById` from a search hit in a session outside the loaded list (hidden/subagent/older than 500) is a silent no-op. Minor.

## Not audited / couldn't verify
- CJK search: Hermes falls back to `messages_fts_trigram`/`messages_fts_cjk` (hermes_state_search.py:1038-1140); Scarf queries only `messages_fts` (unicode61), so CJK substring search may miss. Not a mainstream path; not traced further.
- Chat-side consumers of these fetches (resume, sidebar unread) belong to S01-S03.
- No live DB queries were run (read-only brief); all SQL checked against DDL by reading.
