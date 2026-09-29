---
title: Transcript reads mirror Hermes's display projection
type: note
permalink: scarf/architecture/transcript-reads-mirror-hermes-s-display-projection
tags: [chat, state-db, hermes-parity, compaction]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/HermesQueryBackend.swift]
source_paths_inferred: false
source_sha: ebfef32ea30937a78516be06e7bba5bbf07f0ac3
created: 2026-09-27
updated: 2026-09-27
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

Every Scarf transcript read (chat resume skeleton + full pages, "Load earlier", tool-result hydration, reconnect reconcile, terminal polling, Sessions detail; Mac + iOS share HermesDataService) goes through `transcriptVisibleClause`. Set by blind re-audit B01 (S02-chat-events-F1, 2026-09-27). Hermes refs @ v2026.9.24.

## Observations
- [invariant] With `messages.compacted` present, transcripts read `(active = 1 OR compacted = 1)` like Hermes's display projection `get_resume_conversations` (hermes_state_messages.py:1273-1293, #92080); only Hermes's MODEL projection is active-only. 0.21.5 compacts in place by default (config_defaults.py:658-663), so active-only reads made every reopened compacted chat lose its earlier turns. No compacted column: SQL unchanged #transcript
- [invariant] Compaction generations fold like `_dedupe_display_generations` (:892-908, key role/content/timestamp/tool_call_id/tool_calls/tool_name) but Scarf keeps the FIRST row of each group (Hermes keeps the live row, ordered by first id): same text, and id order stays display order, which every page cursor and the reconcile window depend on. SQL: NOT EXISTS an earlier `active=0 AND compacted=1` row with the same key #dedupe
- [gotcha] Micro-compaction merges adjacent user turns into a `display_metadata.model_only` row whose sources stay in display history; Hermes's DISPLAY_VISIBLE_SQL drops it. Scarf matches the text `"model_only": true` (json.dumps spelling) so it needs no JSON1 on remote hosts; gated on the `display_metadata` column probe (`hasDisplayMetadataColumn`) #model-only
- [fact] From 0.21.5, `archive_and_compact` rewind-flags the carried tail's originals (active=0, compacted=0) and inserts copies; reconcile drops a kept on-screen row below its window floor when the window holds a same-key copy (`CompactionGenerationKey`), else a tail compacted mid-session showed twice #reconcile
- [constraint] Activity feeds and the Dashboard tool-call card stay active-only; search already used the widened set. Known gap: Hermes also folds user handoff-carrier rows (`split_user_originated_turn`), not reproduced in SQL #scope

## Relations
- relates_to [[Scarf session lists mirror Hermes list_sessions_rich: predicate, compression-tip projection, hidden display rows]]
- corrects [[Hermes v0.18 Compatibility Decisions]]
