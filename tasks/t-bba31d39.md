---
id: t-bba31d39
title: v0.20 Wave C1 — pinned/last-activity sidebar + per-model costs
status: done
added: 2026-08-03
---

## Description

Schema-detected (PRAGMA) adds: sessions.pinned + last_activity_at/last_activity_description in sidebar (pin indicator + sort/pin section; graceful absence pre-0.20 DBs); session_model_usage table → per-model token/cost breakdown on Dashboard (only when table exists). HermesDataService + backends; follows existing hasCompactedColumn detection pattern. Tests with fixture DBs old+new.

## Plan



## Artifacts



