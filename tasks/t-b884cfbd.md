---
id: t-b884cfbd
title: P1b Data layer: kanban diagnostics decode, search fallback, sqlite3-missing message (#141)
status: done
added: 2026-09-26
priority: high
---

## Description

A1: `hermes kanban diagnostics --json` ≥0.21.4 appends a trailing row {"task_id": null, "dispatch_profiles": …} (hermes_cli/kanban.py:683-687@v2026.9.21); HermesKanbanDiagnostic.swift:207 taskId is non-optional → whole decode throws. Decode tolerantly (skip/parse the allowlist row). A3: FTS redesign at 9.21 truncates tool rows in the index for ALL rows and deletes fts_tool_full_content_high_water; adds messages_fts_src view (hermes_state_schema.py:139,343-366; hermes_state_common.py:262,714-727@v2026.9.21, commit 42e97f3808). Scarf reads a missing marker as "fully indexed" and skips its LIKE fallback (HermesDataService.swift:824-853, HermesSearchIndex.swift:25-36). Detect via sqlite_master (C4), not version. Combined from Phase B #141: route RemoteSQLiteBackend lastOpenError through HermesDataService.humanize (HermesDataService.swift:104,123,139) and give the ScarfGo dashboard banner an accurate title instead of "Connection issue" (Scarf iOS/Dashboard/DashboardView.swift:132); Python fallback deferred.

## Plan



## Artifacts

Commits 39a6b0bf, 1821f320; merged a114805f. Tolerant kanban decodeList (skips v0.21.4 home-scope row, throws if nothing recognisable); search detects messages_fts_src in sqlite_master → fallback from id 0; #141 lastOpenErrorKind .sqlite3Missing + ScarfGo banner title (only that case humanized — the rest of humanize would mislabel SSH errors). ScarfCore 3650 pass, ScarfIOS 101 pass, Mac+iOS build. Follow-ups: legacy pre-v23 FTS + stale-index recovery edge case; ScarfGo still titles other errors "Connection issue"; ScarfGo has no string catalog.

