---
id: t-3bd2f50a
title: v0.21 W6: data layer — schema detect + previews
status: todo
added: 2026-09-01
priority: high
---

## Description

HermesDataService/backends: (1) detect messages._compressed_summary column (PRAGMA, pattern of hasCompactedColumn; hermes_state_common.py:475) and decide query impact; (2) session-preview parity — Scarf's naive substr(MIN(id) WHERE role='user') shows compaction boilerplate; mirror Hermes carrier-aware preview (_PREVIEW_ELIGIBLE_SQL hermes_state_common.py:79-115, prefix-strip :143-152, CR/LF flatten :166), add active/compacted filter, schema-gated (HermesDataService.swift:903-912); (3) note gateway_heartbeats table exists (hermes_state_common.py:523-538) — no reader yet, record only; (4) Bot Chat rename: sessions titled "Bot Chat" refuse rename server-side (hermes_state.py:10066,10199-10215) — surface a friendly error in the rename UI path. Tests with fixture DBs both with and without the new column.

## Plan



## Artifacts



