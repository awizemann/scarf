# S04-sessions-data — verdict: WORKS-WITH-ISSUES

Paths: Scarf = `/Users/awizemann/Developer/Scarf/scarf/...`; Hermes = `~/.hermes/hermes-agent-v0215` (tag v2026.9.24, `hermes --version` → v0.21.5).
Abbreviations: HDS = `Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift`, RSB = `.../Services/Backends/RemoteSQLiteBackend.swift`, LSB = `.../Services/Backends/LocalSQLiteBackend.swift`, SVM = `scarf/Features/Sessions/ViewModels/SessionsViewModel.swift`.

The DDL checked against is `SCHEMA_SQL` in `hermes_state_common.py:328-460` (sessions/messages/session_model_usage/state_meta) and `FTS_SQL` in `hermes_state_common.py:711-760` (v23 external-content `messages_fts` over the `messages_fts_src` view). Every column Scarf selects exists at the tag with the type Scarf reads. Schema gates use PRAGMA/sqlite_master, not SCHEMA_VERSION (LSB:300-414, RSB:321-401). The local handle is READONLY. The WAL-sidecar fallback is READWRITE + `PRAGMA query_only=1` + `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE`, and it refuses to run if the no-checkpoint setting can't be confirmed (LSB:170-199). The remote path does the same with `sqlite3 -readonly -json`, and its fallback is `.dbconfig no_ckpt_on_close on` + `query_only` + a file-existence guard (RSB:717-813). So charter C3 (Scarf never writes state.db, including checkpoints) holds.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Sessions list + quick/project filters (Mac), local | WORKS | F3 (P3) |
| 2 | Sessions list / chat sidebar / Dashboard on a REMOTE host whose sqlite3 CLI < 3.38 (e.g. Ubuntu 22.04) | DEGRADED | F1 |
| 3 | Open a session transcript (skeleton + hydration, lineage-aware, active/display_kind filters) | WORKS (local, remote ≥3.38) | F1 on remote <3.38 |
| 4 | Full-text search (FTS5 phrase quoting, compacted rows, deep tool-content LIKE top-up, rebuild banner) | WORKS | — |
| 5 | Rename session (`hermes sessions rename -- <id> <title>`) | WORKS | — |
| 6 | Delete session (`hermes sessions delete --yes -- <id>`, chain tip-first) | WORKS | — |
| 7 | Export session / export all (jsonl/trace via stdout; html/md/qmd path) | DEGRADED | F2 |
| 8 | Dashboard stats (7-day window, usage source reconciled with session_model_usage), recent sessions, recent tool calls, per-model usage | WORKS | — |
| 9 | Activity feed (tool-call skeleton → hydration → tool result) | WORKS | — |
| 10 | Insights (SQL-only, no `hermes insights` call; usage population vs conversation population) | WORKS | — |
| 11 | Session → project attribution (Scarf sidecar `session_project_map.json`, lineage fallback) | WORKS | — |
| 12 | iOS Dashboard (stats, recent/all sessions, previews, attribution) | WORKS | F1 applies on remote <3.38 |

## Findings

### S04-sessions-data-F1 · P1 · PLAUSIBLE · NEW
- **Claim:** On remote hosts, `hasListableChildSupport` depends on the remote sqlite3 CLI's *version* (≥ 3.38), not on whether `json_extract` actually works. Hosts with an older sqlite3 that still has JSON1 compiled in (Ubuntu 22.04 ships 3.37.2; RHEL/Rocky 9 ship 3.34) drop to the pre-v0.20.4 roots-only listing. The result:
  - every gateway conversation continued after a reset disappears from the Sessions list, chat sidebar, Dashboard and iOS Dashboard;
  - compression chains are never projected onto their tip.
- **Scarf:** RSB:385-387 (gate) and RSB:409-418 (`sqliteHasJSON1`: version ≥ 3.38 only). This single flag gates:
  - the listing predicate (HDS:375-392; the fallback is `parent_session_id IS NULL`);
  - the delegate filter (HDS:384);
  - compression-tip projection (HDS:2106);
  - the detail lookup's chain projection (HDS:~1815-1823);
  - the chain-step reset exclusion.
  The local backend probes `json_extract` directly (LSB:421-428), so this affects remote only.
- **Hermes @v2026.9.24:**
  - Gateway resets create child rows with `parent_session_id` set plus the `_reset_from` marker (`gateway/session_recovery.py:420-434`).
  - The listing surfaces them via `_RESET_CHILD_SQL` / `_LISTABLE_CHILD_SQL` (`hermes_state_common.py:205-212`, used by `_session_filter_where` at `hermes_state_sessions.py:103-113`).
  - Chain tip projection: `hermes_state_sessions.py:1028-1065`.
- **Failure scenario:** Hermes 0.21.5 runs on an Ubuntu 22.04 VPS (Hermes uses its bundled Python sqlite; the system `sqlite3` CLI is 3.37.2). A Telegram chat hits an idle or daily reset, which creates a new child session.
  - Scarf's Sessions list, Dashboard "Recent sessions" and iOS Dashboard never show that conversation, or any later post-reset one. `hermes sessions list` on the same host does show it.
  - A long chat that was compressed is listed under its root: the root's ended fields, and a transcript (`allSessionIds` = root only) that stops at the first compression.
  - Nothing on screen says anything is missing.
- **Evidence:**
  - Tests pin `sqliteHasJSON1("3.37.9 …") == false` (`ScarfCoreTests/RemoteSQLiteBackendPreflightTests.swift:180`).
  - Before 3.38, JSON1 was a compile-time option that Debian/Ubuntu and Fedora/RHEL builds enable. This is the unverified premise: no pre-3.38 remote host was available to probe live, which is why confidence is PLAUSIBLE rather than SOURCE.
- **Suggested fix:** Probe `sqlite3 :memory: "SELECT json_extract('{}','$.x')"` in the preflight script (tolerating failure). Fall back to the version rule only when the probe can't run.

### S04-sessions-data-F2 · P2 · SOURCE · NEW (see note)
- **Claim:** "Export…" on a Sessions row that is a rotated compression chain exports only the live-tip segment. The row and its detail sheet show the whole lineage. For md/qmd, Scarf never passes `--lineage logical`, although Hermes offers it.
- **Scarf:**
  - SVM:766-768: `exportSession` passes `session.id`, which is the TIP id after projection (HDS `projectCompressionTips`).
  - SVM:919-934: `exportArguments` emits only `--session-id <id>`, never `--lineage`.
  - The transcript/detail path reads the full `session.allSessionIds` (SVM `selectSession`), so what the user sees and what they export differ.
- **Hermes @v2026.9.24:**
  - `_cmd_export._one` → `db.export_session(resolved)` for one row only (`hermes_cli/sessions_cmd.py:335-345`; `hermes_state_portability.py:283-288`).
  - The lineage form exists as `export_session_lineage` (`hermes_state_portability.py:290-296`), exposed only for md/qmd as `--lineage {single,logical}` (`hermes_cli/subcommands/sessions.py:95-96`). LIVE: `hermes sessions export --help` shows "--lineage {single,logical} md/qmd only".
- **Failure scenario:** A user opens a long conversation that Hermes compressed twice and chooses Export → JSONL (or Markdown). The file contains only the messages since the last compression. The banner reports "Exported N KB to …" as a complete success.
- **Suggested fix:**
  - md/qmd: add `--lineage logical` when `session.lineageIds.count > 1`.
  - jsonl/trace: run the export once per `allSessionIds` and concatenate, or say plainly in the UI that only the latest segment is exported.
- **Note (disclosure):** A ledger `grep` for "--lineage" printed one line from `tasks/t-86bb3d9f.md`, a ticket this brief excludes. The line mentions that chain export acts on the tip only. I didn't open the ticket. The finding above was derived and verified independently from code. The orchestrator may classify it as TRACKED(t-86bb3d9f) if that ticket is still open.

### S04-sessions-data-F3 · P3 · SOURCE · NEW
- **Claim:** Scarf's list predicate never excludes non-conversation session sources, although Hermes's listings do:
  - `hermes sessions list` hides `source='tool'` (integrations run with `--source tool`) by default.
  - The TUI, Desktop, console and CLI `/sessions` pickers also hide `kanban` workers and `oneshot` runs.
  So these rows appear in Scarf's Sessions list, chat sidebar, Dashboard "Recent sessions" and its session count.
- **Scarf:** HDS:375-392 (no `source` clause). `ChatSessionListPane.swift:395` filters only `cron`.
- **Hermes @v2026.9.24:**
  - `hermes_cli/sessions_cmd.py:259-261` (`_default_exclude` → `["tool"]`).
  - `hermes_state_sessions.py:177` (`INTERNAL_LISTING_SOURCES = ("kanban","tool","oneshot")`), used at `hermes_cli/console_engine.py:602-605`, `hermes_cli/cli_session_mixin.py:319-324` and `tui_gateway/methods_session.py:126-129`.
  - Kanban workers are tagged `HERMES_SESSION_SOURCE=kanban` at `hermes_cli/kanban_db_dispatch.py:2825`.
- **Failure scenario:** A user running a kanban board sees every worker run as a top-level "session" in Scarf. These rows push their own chats down the 5-row Dashboard and inflate "Sessions (last 7 days)". An IDE integration's `--source tool` runs show up the same way. None of them appear in `hermes sessions list`.
- **Suggested fix:** Add `COALESCE(s.source,'') NOT IN ('tool')` (CLI parity) or the full `INTERNAL_LISTING_SOURCES` set (desktop parity) to `sessionListPredicate`. Decide which parity target Scarf wants and record it.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| READONLY open + probe, WAL query_only fallback w/ NO_CKPT_ON_CLOSE | SQLite open | LSB:70-199 | hermes_state_common.py (WAL; `hermes sessions set-journal-mode`) | OK |
| state.db replace detection (inode) | file | LSB:238-248 | hermes_state_dbfile.py (quarantine) | OK |
| `PRAGMA table_info(sessions/messages)`, `sqlite_master` session_model_usage | schema probe | LSB:300-414; RSB:160,321-401 | hermes_state_common.py:338-452 | OK |
| JSON1 probe (local) / version inference (remote) | capability | LSB:421-428; RSB:409-418 | — | FINDING-F1 |
| Remote `sqlite3 -readonly -json <path> <<'__SCARF_SQL__'`, path quoting, $HOME expansion, marker batching, exit-code judging | SSH/CLI | RSB:139-315, 717-864 | — | OK |
| SQLValueInliner (quotes doubled, C0→char(n), non-finite reals) | remote param encoding | SQLValueInliner.swift:63-221 | — | OK |
| sessions SELECT columns (id…estimated_cost_usd, reasoning_tokens, actual_cost_usd, cost_status, billing_provider, api_call_count, rewind_count, pinned, last_activity_at, last_activity_description, last_read_at) | SQL | HDS:262-296, 2719-2815 | hermes_state_common.py:338-400 | OK |
| `last_active` freshest-of expression | SQL | HDS:313-328 | hermes_state_common.py:222-231 | OK |
| list predicate: listable child, `_delegate_from`, archived=0, hidden=0 (json_valid guard) | SQL | HDS:375-420 | hermes_state_common.py:67-74,193-212; hermes_state_sessions.py:103-127,1278-1282 | OK / F1 / F3 |
| source exclusion (tool/kanban/oneshot) | SQL | HDS:375-392 | hermes_state_sessions.py:177; sessions_cmd.py:259-261 | FINDING-F3 |
| subagent child predicate (`_ephemeral_child_sql`) | SQL | HDS:427-443,771-779 | hermes_state_common.py:215-218 | OK |
| compression chain step + recursive CTE, tip projection | SQL | HDS:1951-2140 | hermes_state_compression.py:28-49; hermes_state_sessions.py:1028-1065 | OK (secondary sort uses COALESCE(ended_at,started_at) instead of last_active — tie-only) |
| messages columns (reasoning, reasoning_content lazy, hasReasoningContent) | SQL | HDS:445-532, 2817-2862 | hermes_state_common.py:402-428 | OK |
| transcript filters `active = 1` + `display_kind <> 'hidden'` | SQL | HDS:1348-1357 | hermes_state_search.py:147-150; hermes_state_common.py:113-114 | OK |
| lineage transcript `session_id IN (…)` ordered by id | SQL | HDS:821-875 | hermes_state_messages.py:1273-1293 | OK |
| hydrate tool_calls / tool results in range / reasoning_content by id | SQL | HDS:953-1165 | hermes_state_common.py:402-428 | OK |
| tool_calls JSON decode (OpenAI shape, per-element) | parse | HDS:2881-2923; HermesMessage.swift:366-386 | hermes_state_messages.py:91-98; agent/tool_dispatch_helpers.py:400-422 | OK |
| FTS `messages_fts MATCH ?` joined on rowid, `ORDER BY rank`, `(active=1 OR compacted=1)` | SQL/FTS | HDS:1190-1255 | hermes_state_common.py:722-728; hermes_state_search.py:147-150 | OK |
| FTS sanitize (whitespace split, phrase quoting, `"` stripped) | FTS syntax | HDS:2926-2941 | hermes_state_search.py:793-828 (Hermes strips specials; deliberate divergence) | OK |
| deep tool-content LIKE top-up (8192 prefix, aligned `messages_fts_src` detection, `fts_tool_full_content_high_water`) | SQL | HDS:1263-1420; HermesSearchIndex.swift:23-80 | hermes_state_common.py:272,700-728 | OK |
| rebuild status `state_meta` fts_rebuild_progress/high_water | SQL | HDS:1427-1452 | hermes_state_common.py:686-688,730-735 | OK |
| session previews (carrier-aware, literals) | SQL | SessionPreviewSQL.swift (all); HDS:1557-1705 | hermes_state_common.py:88-165; agent/context_compressor.py:251-292,479-484 | OK (skill-scaffold windowing not mirrored — cosmetic) |
| fingerprint / last message date / most-recent session | SQL | HDS:1709-1776, 2201-2230 | messages table | OK |
| Bot Chat exact-title lookup | SQL | HDS:1905-1920, 2172-2190 | hermes_state_titles.py | OK |
| stats (COUNT from list predicate, SUMs from usage source, 7-day window) | SQL | HDS:2271-2349 | agent/insights.py:92-96,271-292 | OK |
| usage source (MAX(session counter, SUM(session_model_usage))) | SQL | HDS:731-769 | agent/insights.py:271-292,346-368; hermes_state_common.py:431-451 | OK |
| per-model usage (all time, labelled "all time") | SQL | HDS:2397-2404; DashboardView.swift:190 | hermes_state_common.py:431-451 | OK |
| usage aggregates for Insights (GROUP BY model/source/cost) | SQL | HDS:673-729 | agent/insights.py:92-96 | OK |
| insights snapshot (user msgs, tool_name histogram, start-time histogram) | SQL | HDS:2627-2700 | agent/insights.py:108-137,218-236 | OK (tool histogram doesn't max-reconcile with assistant tool_calls JSON; tool rows carry tool_name at the tag, tool_dispatch_helpers.py:416-420) |
| Activity: recent tool calls skeleton/light, `fetchToolResult` by tool_call_id | SQL | HDS:1455-1550; ActivityViewModel.swift:104-219 | messages table | OK |
| `hermes sessions rename -- <id> <title>` + exit-code judge + failure text | argv | SVM:572-574,592-632; SessionRenameFailure.swift | subcommands/sessions.py:252-255; sessions_cmd.py:726-744; main.py:3614-3617 | OK (LIVE) |
| `hermes sessions delete --yes -- <id>` + chain tip-first | argv | SVM:582-584,660-720 | subcommands/sessions.py:101-103; sessions_cmd.py:575-590 | OK (LIVE) |
| `hermes sessions export - [--format jsonl|trace] [--no-redact] [--session-id]` stdout capture + JSON-first-line validation | argv | SVM:919-1100 | subcommands/sessions.py:69-99; sessions_cmd.py:89-95,317-470 | OK |
| `hermes sessions export <path> --format html|md|qmd` (local only) + marker judge | argv | SVM:708-760,972-1017; HermesCLIOutcome.swift:636-662 | sessions_cmd.py:48-50,383-410,472+ | OK (`_not_found` text is now "No session '…'…", which matches no marker, but the unconfirmed-verdict path still reports failure with that line) |
| per-session export of a compression chain (no `--lineage`) | argv | SVM:766-768,919-934 | subcommands/sessions.py:95-96; hermes_state_portability.py:283-296 | FINDING-F2 |
| `~/.hermes/scarf/session_project_map.json` (Scarf-owned sidecar, guarded store + lock) | file | SessionAttributionService.swift; SessionProjectMap.swift | — (not a Hermes file) | OK |
| state.db / -wal mtime + size stat | file | HDS:2706-2715; SVM loadImpl | — | OK |
| backup snapshot of *.db (VACUUM INTO / .backup from -readonly source; query_only + no_ckpt fallback) | shell/SQLite | HermesDatabaseScripts.swift | — | OK |
| profile HERMES_HOME state.db path | path | HermesPathSet.swift:67 | hermes_state.py:168,188-191 | OK |
| iOS Dashboard reads (fetchStats all-time, fetchSessionsChecked, previews by ids) | SQL | IOSDashboardViewModel.swift | as above | OK (F1 applies remotely) |
| UsageEvent.swift | telemetry | scarf/Core/Services/UsageEvent.swift | — | OK (no Hermes touchpoint) |

## Not audited / couldn't verify
- F1's distro premise (JSON1 compiled into the pre-3.38 sqlite3 CLI on Ubuntu 22.04 / RHEL 9) wasn't probed live; no such remote host was available.
- CJK search: Hermes routes short or CJK tokens to `messages_fts_trigram` / `messages_fts_cjk` (`hermes_state_search.py:830-905`); Scarf only queries `messages_fts`. So CJK substring search returns fewer hits than `hermes sessions search`. Not filed: non-default locale, secondary.
- Activity `fetchToolResult(callId:)` isn't session-scoped. It can in theory return another session's result when a provider omits call ids and Hermes's deterministic hash (`agent/message_sanitization.py:490-493`) collides for identical calls. Treated as an edge case; not filed.
- Remote transport internals (`streamScript`, ControlMaster, Citadel on iOS) and `ServerContext.runHermes` profile/env plumbing belong to S15 and weren't re-audited here.
- UI rendering of SessionsView / DashboardView beyond the Hermes-data wiring (labels, filters) wasn't exercised at runtime (no build, per brief).
