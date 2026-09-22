---
title: Hermes messages_fts contract: an 8 KB tool prefix and two rebuild markers
type: note
permalink: scarf/architecture/hermes-messages-fts-contract-an-8-kb-tool-prefix-and-two
tags: [hermes, state-db, search, fts, hermes-v0-21-1]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesSearchIndex.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scarf/Packages/ScarfCore/Tests/ScarfCoreTests/HermesV0211SearchIndexTests.swift]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-09-08
updated: 2026-09-08
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

Everything a reader of Hermes's `messages_fts` needs in order to know what
`MATCH` can and cannot answer for. All of it lives in `state_meta` rows, so
it is DETECTED, never version-gated (charter C4). Scarf's copy of the
contract is `HermesFTSIndex` in `HermesSearchIndex.swift`.

## Observations
- [fact] From v2026.9.7 (0.21.1) the FTS triggers index only `substr(content, 1, 8192)` for `role='tool'` rows whose id is ABOVE `state_meta.fts_tool_full_content_high_water` (FTS_TOOL_CONTENT_PREFIX_CHARS / _fts_indexed_content_sql, hermes_state_common.py:224-234). A term occurring only deeper than that is invisible to MATCH, so a client owes the user either a fallback or a caveat #search
- [invariant] The high-water is stamped ONCE with MAX(messages.id) at migration time and never moves (hermes_state_schema.py:269-273, guarded by a marker-presence early return at :292-295) — rows at or below it keep their full pre-migration token stream. A reader may cache the value for the life of a connection #state-db
- [invariant] `fts_rebuild_high_water` (H) and `fts_rebuild_progress` (P) mark a PENDING chunked backfill: a row is in the index iff `id <= P OR id > H`, and rows in (P, H] are simply absent. Both keys are DELETED TOGETHER when it lands (_CLEAR_REBUILD_MARKERS_SQL, hermes_state_schema.py:124), so their presence is the whole signal — no version comparison, and either key alone still means partial #search
- [gotcha] The rebuild markers are far older than the 8 KB prefix — they first appear at v2026.7.30 and belong to the opt-in `sessions optimize-storage` transition, not to v0.21.1. v0.21.1 swaps the triggers WITHOUT any rebuild (hermes_state_schema.py:287-291), so 'a full FTS rebuild runs at first v0.21.1 open' is false #verification
- [constraint] Any LIKE top-up over these rows must be bounded by rows READ (an inner `ORDER BY id DESC LIMIT n` subquery), not by rows returned: every candidate is a >8 KB payload SQLite must read, so `WHERE … LIKE … LIMIT n` makes the no-result search the expensive one. 400 candidates ≈ 42 MB ≈ 0.06-0.10s on a 1.6 GB state.db #performance

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[WAL state.db without a -shm sidecar cannot be read READONLY; the fix is a query_only fallback]]
