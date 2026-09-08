---
title: Project Dashboards Feature
type: note
permalink: scarf/features/project-dashboards-feature
tags: [dashboards, feature]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift, scarf/docs/DASHBOARD_SCHEMA.md]
source_sha: 168f30e914d476427d2de7a165d8f905edb4e923
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-09-08
reviewed_by: audit:claude-code (background)
---

## Observations
- [feature] Project Dashboards are custom, agent-generated visualizations per project. Schema supports a variety of widget types: stat boxes, progress bars, rich text, tables, charts, checklists, embedded web views, markdown file rendering, log file tailing, cron job status, status grids, Kanban summaries, and local/remote images — all defined in a simple JSON file at `.scarf/dashboard.json`. #schema
- [design] Dashboards are intended to be authored and maintained by the Hermes agent itself (agent writes the JSON; Scarf renders with live refresh and validates columns). #agent-authored
- [implementation] Schema decoding uses salvage-logging for robustness: malformed optional fields drop only that field rather than the entire row or file, allowing agent-written files to remain resilient to data corruption and agent mistakes. #salvage

## Relations
- documented_in [[Scarf Project Overview]]
