---
id: t-d65dfc28
title: Kanban inspector Block action missing on Hermes v0.22.5 (UI test)
status: done
added: 2026-10-26
priority: high
---

## Description

CronKanbanJourneyUITests/testKanbanCardCreateAndMoveColumn fails on v0.22.5 only: "Inspector never opened (or offered no Block action)". Decide product bug vs test, fix, verify in the VM.

## Plan



## Artifacts

Not a product bug: test clicked the new card while the create sheet (create → dispatch → refresh) still covered it. Fix 60a20240 waits for the sheet to close, then bounded click-until-Block. Audit PASS. VM v0.22.5 PASS; v0.21.5 VM run blocked on sanitizer gap at the time.

