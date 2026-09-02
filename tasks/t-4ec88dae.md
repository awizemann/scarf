---
id: t-4ec88dae
title: Audit F4: Monitor data integrity
status: done
added: 2026-09-02
priority: high
---

## Description

Dashboard: statsSQL gains a since param (7 days means 7 days) + align populations with Sessions list; snapshot failure surfaces an error; recent-tool-calls uses messageColumnsLight + active=1. Insights: one session population for all cards; drop close-per-load (gh#102 regression); LIMIT the period query; cheapen Notable Sessions. Sessions: wire Model column (data already fetched), Updated column uses lastActivityAt, drop the unread correlated subquery from this query, hide/no-op the Starred pill honestly, surface failed delete, detail Reasoning loads via fetchReasoningContent, unify preview/title precedence with Dashboard. Activity: session-filter labels from the right session set. Load-race generation guards for Sessions/Insights/Activity VMs (Dashboard pattern).

## Plan



## Artifacts

Commit d0c6504 on main (13 files, +920/-96). New tests: `scarf/Packages/ScarfCore/Tests/ScarfCoreTests/SectionAuditF4MonitorTests.swift` (11, fixture-backed) and `scarfTests/SessionDeletedSignalTests.failedDeleteSurfacesAnError`. Durable notes appended to `.memory/decisions/section-audit-remediation-2026-09` under "F4 — Monitor data integrity". All items landed; none refuted.

