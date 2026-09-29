---
id: t-e289caea
title: P4 #145 mark branched sessions in session lists
status: done
added: 2026-09-29
---

## Description

See documents/plans/2026-09-29-open-issues-3.5-fixes-plan.md P4. Source: gh#145. Fork blocked on NousResearch/hermes-agent#124540.

## Plan



## Artifacts

Commit 8fac0157, merged 110de22d. Tests: SessionBranchLineageTests (3, real SQLite fixtures); full ScarfCore 4215 green serially (pre-merge). Memory: architecture/session-branch-marking-145-isbranch-rides-the-list-select. Gaps: no badge in ScarfGo project-scoped list (ProjectSessionsView_iOS.swift) or Sessions search results; not seen on screen with a real /branch session (P7).

