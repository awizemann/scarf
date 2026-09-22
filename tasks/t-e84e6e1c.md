---
id: t-e84e6e1c
title: Upstream P10: replace the brittle kanban session-id source-sweep test + low findings
status: done
added: 2026-09-21
priority: low
---

## Description

Small leftovers, one branch fix/small-leftovers. (1) scripts/ui-gate.sh: when a plan's log has no "Executed N tests" line and the result bundle shows the runner failed to initialize ("Timed out while enabling automation mode"), report it as RUNNER-FAILED (distinct from FAIL) in the summary and exit non-zero; document in the script header. (2) CronKanbanJourneyUITests.swift:80 asserts an exact count of 2 seeded cron jobs — scope to the seeded jobs by name like the kanban fix. (3) SessionCostDisplay: treat NaN or negative amounts as "no positive amount" with a test. (4) KanbanView.swift:44-45 stale comment about the removed timestamp. (5) Dashboard "By model" query (HermesDataService.swift ~1655-1662, issued at ~1762 with []) is all-time under a "Last 7 days" heading: apply the same sessionListPredicate window the other dashboard queries use, or change the heading to what it really shows — choose the smaller honest fix, cite what the sessions predicate does, test it. Skip anything that turns out larger than ~30 lines; report it instead.

## Plan



## Artifacts



