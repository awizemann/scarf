---
id: t-a16aae07
title: B01 Transcript & sessions data: compacted history, remote JSON probe, export lineage
status: done
added: 2026-09-27
priority: urgent
---

## Description

Wave 1. Findings: S02-F1 (P1 compacted turns hidden — use Hermes display projection active=1 OR compacted=1, honour display_kind hidden), S04-F1 (P1 remote sqlite JSON by version → probe json_valid), S04-F2 (export compressed chain → whole lineage / --lineage logical), S04-F3 (hide tool/kanban/oneshot sources like Hermes), S11-F1 (project Sessions tab 200-newest window). Correct .memory/decisions/hermes-v0-18-compatibility-decisions.md:18. Plan: documents/plans/hermes-v0215-blind-reaudit-remediation-plan.md.

## Plan

B01 (worktree Scarf-wt/b01, branch fix/hermes-v0215-blind-b01).
- S02-F1: HermesDataService transcript clause -> Hermes display projection when messages.compacted exists: (active=1 OR compacted=1), generation dedupe (keep first row of each logical message so id ordering/paging stay valid), drop micro-compaction model_only rows, keep display_kind hidden filter. Covers skeleton/full/tool-range/reconcile/polling/Load earlier/Sessions detail (Mac + iOS share ScarfCore). Reconcile: drop kept older rows superseded by a window copy. Pre-compacted hosts: SQL unchanged (C1/C4). Tests: real v0.21.5 DDL DB with in-place compaction seed; cross-check with Hermes get_resume_conversations.
- S04-F1: remote preflight runs `sqlite3 -json :memory: "SELECT json_valid('{}')"` (failure tolerated) and uses that for JSON support; version rule only when probe output absent. Local probe unchanged. Tests: preflight parse with probe 1/0/absent.
- S04-F2: export of a compression chain covers the whole lineage: md/qmd get `--lineage logical` (verify argparse @ v2026.9.24); jsonl/trace per-segment export concatenated or honest copy. Tests: argv + multi-segment.
- S04-F3: session list hides Hermes INTERNAL_LISTING_SOURCES (kanban/tool/oneshot), gated per C1; cite Hermes filters.
- S11-F1: ProjectSessionsViewModel queries attributed ids directly (chunked IN + chain tip projection) instead of filtering global top-200; fix empty-state copy (Mac + iOS).
Memory: correct hermes-v0-18-compatibility-decisions.md:18, search notes/wiki for sqlite JSON version gate, export, project sessions, list filters.

## Artifacts

Merged into fix/hermes-v0215-blind (B01 incl. JSONL archived-turns note 0fd13a1a/b4e06bbc; older-host chain + carried-tail work reverted per scope rule). App suites deferred to B10.

