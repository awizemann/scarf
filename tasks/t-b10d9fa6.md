---
id: t-b10d9fa6
title: Upstream P1: validate Scarf code that relies on landed Hermes changes
status: done
added: 2026-09-21
priority: high
---

## Description

Three of our Hermes upstream requests landed. Confirm the Scarf code that depends on them is correct against the tagged Hermes source (v2026.9.21 = v0.21.4) and against the live local Hermes install.

Scope:
1. Kanban session filter (Hermes PR #28447, shipped v2026.5.28). Scarf passes `--session <acp-session-id>` (ScarfCore/Models/KanbanFilters.swift:66), gated on `hasKanbanSessionFilter`. Verify: the argv matches the tagged argparse exactly (charter C5), the capability floor is cited against tagged source (C2), JSON `session_id` field is decoded, and a live `hermes kanban list --session ... --json` behaves as Scarf expects (including unknown-session and pre-feature-host behaviour).
2. ACP token + cost in state.db (Hermes implemented it itself, shipped v2026.7.1). Find how Scarf reads token/cost columns for ACP sessions; confirm column probing follows C4 (PRAGMA table_info, tolerate absence); find any leftover "ACP sessions have no tokens" fallback, placeholder text or special-casing that is now dead or wrong on current hosts but must stay correct on old hosts (C1).
3. Auxiliary "payment / credit error" wording (Hermes #113970, v0.21.4). Confirm nothing in Scarf (log viewer, health/diagnostics, banners, localized strings, tests) matches on that wording.

Deliverable: a report at documents/upstream/2026-09-21-scarf-validation.md with file:line evidence per item, test results, and a list of proposed fixes. REPORT-ONLY for product code: do not change Scarf source; propose fixes so the orchestrator can create follow-up tasks.

## Plan



## Artifacts



