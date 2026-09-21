---
id: t-e84e6e1c
title: Upstream P10: replace the brittle kanban session-id source-sweep test + low findings
status: todo
added: 2026-09-21
priority: low
---

## Description

Final-audit F5, F7-F12. KanbanChatSessionIdWiringTests is a regex sweep with a fixed 16-line window; two added comments break it and F4 passes it. Replace with a real seam test or delete. Low items: dead shouldRender; Dashboard "By model" SQL is all-time under a "Last 7 days" heading (HermesDataService.swift ~1655-1662, ~1762) and includes auxiliary usage; no NaN/negative guard in SessionCostDisplay; KanbanView.swift:44-45 mentions a removed timestamp; note in memory that the pre-0.15 tenant+time-window kanban fallback was removed in e980b657.

## Plan



## Artifacts



