---
title: Project Dashboards Feature
type: note
permalink: scarf/features/project-dashboards-feature
tags: [dashboards, feature]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift, scarf/docs/DASHBOARD_SCHEMA.md]
source_sha: 466bb7f11b7652ac99876183d0968269cddcac38
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

## Observations
- [feature] Project Dashboards are custom, agent-generated visualizations per project. Schema supports stat boxes, charts, tables, progress bars, checklists, rich text, and embedded web views — all defined in a simple JSON file. #schema
- [design] Dashboards are intended to be authored and maintained by the Hermes agent itself (agent writes the JSON; Scarf renders with live refresh). #agent-authored

## Relations
- documented_in [[Scarf Project Overview]]
