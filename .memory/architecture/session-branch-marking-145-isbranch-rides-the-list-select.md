---
title: Session branch marking (#145): isBranch rides the list SELECT via branchChildSQL
type: note
permalink: scarf/architecture/session-branch-marking-145-isbranch-rides-the-list-select
tags: [sessions, branch, hermes-lineage, issue-145]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesSession.swift]
source_paths_inferred: false
source_sha: 4beace9d6d71c2aae455ed7eae5b600642f0f3b0
created: 2026-09-29
updated: 2026-09-29
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

GitHub #145: Scarf marks sessions created by Hermes /branch in the Mac Sessions list, the chat sidebar, the ScarfGo Dashboard session lists and ScarfGo's project session list (shared `SessionBranchBadge_iOS` in DashboardView.swift). Sessions search results deliberately don't show it (Alan, 2026-09-29).

## Observations
- [decision] HermesSession.isBranch / branchParentTitle are decoded by name from `is_branch` / `branch_parent_title` columns that `branchLineageColumns` appends to the LIST shapes only (sessionListColumns, sessionListSnapshot no-unread, dashboardSnapshot); single-session, subagent and analytics fetches leave them false/nil #sessions
- [invariant] One `branchChildSQL` (Hermes `_BRANCH_CHILD_SQL`, hermes_state_common.py:150-153 @ v0.21.5) feeds the listing predicate, the subagent-child predicate and the badge columns, so they can never disagree #hermes-lineage
- [fact] Lineage signals: parent end_reason='branched' since v2026.4.8, stable model_config._branched_from marker since v2026.6.5; both gated behind hasListableChildSupport (v0.20.4 columns + JSON1), and without it the SELECT is byte-identical and nothing is marked (C1) #gating
- [convention] The branch badge is a text 'Branch' capsule, never arrow.triangle.branch — that glyph means Subagent in SessionDetailView; compression/reset children are never marked #ui
- [gotcha] Compression-tip projection keeps the ROOT row's isBranch/branchParentTitle (projectedOntoCompressionTip / addingUsage), since the root is the listed branch #sessions
