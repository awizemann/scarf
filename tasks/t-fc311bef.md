---
id: t-fc311bef
title: Upstream P6: show unknown session cost honestly (use cost_status) + P1 cleanups
status: done
added: 2026-09-21
priority: high
---

## Description

Found by P1 validation (report: documents/upstream/2026-09-21-scarf-validation.md; memory: scarf/architecture/hermes-stores-an-unknown-cost-as-0-0-cost-status-is-the). Orchestrator confirmed live: every cli/acp/cron session in ~/.hermes/state.db has cost_status='unknown' with estimated_cost_usd=0.0, and Scarf renders "$0.00" / "$0.0000 est." — it claims the session was free when Hermes said it does not know.

Fix:
1. One shared, tested rule in ScarfCore (on HermesSession or a small formatter next to it) that decides how a session's cost is presented from (actualCostUSD, estimatedCostUSD, costStatus). cost_status 'unknown' with zero amount → "unknown" presentation (em dash, matching the existing "—" idiom), never "$0.00". 'included' → a true zero. nil costStatus (older hosts) → rendering byte-identical to today (charter C1). Verify the full set of cost_status values against tagged Hermes source v2026.9.21 agent/usage_pricing.py (C2).
2. Use it in every cost surface: SessionsView costLabel, SessionInfoBar, and any other place found by searching displayCostUSD / estimatedCostUSD (Mac and ScarfGo). Aggregates (dashboard/insights sums) must not present a total as complete when it includes unknown-cost sessions — decide the smallest honest treatment and justify it.
3. Correct two stale comments: RichChatViewModel.swift ~619 and SessionInfoBar.swift ~8 (ACP token counts ARE in state.db since Hermes v2026.7.1; the fallback stays for mid-turn display and older hosts).
4. Add a test that pins WHICH id reaches kanban `--session` (the ACP session id), so a refactor feeding a different id fails.
Commit on a branch fix/unknown-session-cost; no push.

## Plan



## Artifacts



