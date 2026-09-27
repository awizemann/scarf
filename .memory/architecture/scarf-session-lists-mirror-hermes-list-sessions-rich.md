---
title: Scarf session lists mirror Hermes list_sessions_rich: predicate, compression-tip projection, hidden display rows
type: note
permalink: scarf/architecture/scarf-session-lists-mirror-hermes-list-sessions-rich
tags: [sessions, state-db, hermes-parity, compression]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SessionPreviewSQL.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesSession.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SessionAttributionService.swift]
source_paths_inferred: false
source_sha: d6533b8fc52976a84b6ca58711e874e03fce50fc
created: 2026-09-26
updated: 2026-09-27
---

How Scarf decides which session rows a list shows and how a rotated compression chain appears, after the Hermes v0.21.5 audit R11 (S04, t-e5c479d1). Hermes refs @ v2026.9.24.

## Observations
- [invariant] `sessionListPredicate` = Hermes `_session_filter_where` (hermes_state_sessions.py:103-127): listable-child + `_delegate_from IS NULL` (with listable-child support, v0.20.4+ + JSON1) + `archived = 0` (column-detected, v0.16+) + `hidden = 0`. Every JSON marker uses Hermes's json_valid guard (`HermesDataService.jsonMarker`) — a bare json_extract over one malformed model_config fails the WHOLE list with "malformed JSON" #sessions
- [fact] Rotated compression chains (root end_reason='compression') are projected onto their live tip like `_project_compression_tips` (:1028-1065): row id = TIP id, tip's live fields, root started_at/tokens/pin kept, `lineageIds` root→tip. One recursive CTE (`compressionChains`) shares `compressionChainStepSQL` with `compressionTip(for:)`; gated on hasListableChildSupport so older hosts are unchanged #compression
- [gotcha] Project attribution is keyed by the id a chat STARTED with (the root) but lists/resume carry the tip id. `SessionLineageIndex` (in-memory, filled by the projection) lets `SessionAttributionService.projectPath(for:)` fall back to chain ids; list views use `HermesSession.carryingLineageLabels` / `allSessionIds`. Any new id-keyed lookup must do the same #attribution
- [fact] `messages.display_kind = 'hidden'` rows (v0.19.1+, column-detected) are dropped from transcripts, search and previews via `displayVisibleClause` / `SessionPreviewSQL.activeClause(hasDisplayKindColumn:)`, as hermes_state_search.py:149-150 and hermes_state_common.py:113-114 do #display
- [done] R16b (t-25209c91): the chat pane reads a chain's whole lineage (`RichChatViewModel.lineageSessionIds` / `transcriptSessionIds`; Mac + iOS resume pass `SessionLineageIndex.lineage`), and a mid-chat rotation announced by `session_info_update` `_meta.hermes.sessionProvenance` (acp_adapter/provenance.py; emitted by `_finish_turn`, server.py:952-962 @ v2026.9.24) extends it — the ACP id stays the root while turns land on the continuation. The Mac sidebar matches the live chat by lineage (`ChatViewModel.isAttached(to:)`) #compression
- [gotcha] `hermes sessions delete` removes ONE row and orphans compression children (`delete_session`, hermes_state_sessions.py:1531-1577 @ v2026.9.24), so deleting a chain row's tip resurfaced the earlier segments. Both Scarf delete surfaces delete every lineage id tip-first (`SessionChainDelete`), stopping at the first failure so the rest stays a (shorter) chain #delete
- [fact] A search hit the list omits (archived, delegate, hidden, beyond the 500 loaded rows) opens via `HermesDataService.fetchSessionForDetail`, which walks compression parents and projects a chain onto its tip; the Sessions detail sheet says why the list doesn't show it (R14-1) #search

- [invariant] List previews are fetched for exactly the LISTED rows (R18b, t-486aed3f): `dashboardSnapshot` and `sessionListSnapshot` use `listedSessionPreviewStatement(limit:)` — the preview join restricted to `session_id IN (<same listing SELECT … LIMIT ?>)`, same batch round trip — and the iOS Dashboard asks `fetchSessionPreviews(sessionIds:)` for its rows' `allSessionIds`. "The newest N first user messages anywhere" counted delegates, hidden and archived rows, so a delegating agent pushed untitled listed rows out and they showed raw ids. Hermes computes previews per listed row (`_PREVIEW_RAW_SUBQUERY_SQL`, hermes_state_common.py:163-165 @ v2026.9.24). `dashboardSnapshot` no longer takes `previewLimit` #previews
- [invariant] A failed list read is REPORTED, never rendered as empty (R18b): `SessionListSnapshot.queryError` / `InsightsSnapshot.queryError`, plus `fetchSessionsInPeriodChecked` / `fetchUsageAggregatesInPeriodChecked`. Sessions tab, Insights and Project Sessions (Mac + iOS) keep their last good rows and show `StateReadErrorBanner` (shared with the Dashboard, `error.banner` id); the chat sidebar keeps its rows silently. Insights clears figures only when the failed load was for a DIFFERENT period than the ones on screen. Open failures surface only on REMOTE hosts (`HermesDataService.reportableOpenError`, the Dashboard's rule): a local home with no state.db is a fresh install and the section sweep asserts no `error.banner` there; query failures after a good open surface everywhere #failure-path
- [gotcha] Two registry rows can share a path (Doctor `duplicatePath`); any path-keyed map over `registry.projects` must use `uniquingKeysWith` — `SessionAttributionService.projectNames(mappings:projects:)` is the shared first-row-wins helper (Sessions tab, chat sidebar, iOS Dashboard). `Dictionary(uniqueKeysWithValues:)` there crashed the app on every Sessions load (R15 T2-F1, P1). Add Project and the template installer now refuse a normalized duplicate path, like `project_register` #projects



## Relations
- relates_to [[Section-audit remediation 2026-09]]
- relates_to [[Bot Mode Phase B Decisions]]

- [gotcha] `session/load` (and new/resume) responses also carry `_meta.hermes.sessionProvenance` (`_session_response_fields`, acp_adapter/server.py:597-602 @ v2026.9.24), but on v2026.9.24 a fresh `hermes acp` restores the agent under the REQUESTED id (`_restore`, acp_adapter/session.py:444-446), so `currentHermesSessionId` at load always equals the id Scarf asked for. R17 parses it (`ACPClient.loadSessionWithProvenance`) and follows a differing head defensively (`ChatViewModel.noteLoadedHead`, `RichChatViewModel.lineage(_:for:addingLoadedHead:)`); only the post-turn `session_info_update` actually announces rotations #compression
