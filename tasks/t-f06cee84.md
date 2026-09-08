---
id: t-f06cee84
title: Kanban: Block sheet said the reason was optional while the plan required it
status: done
added: 2026-09-08
---

## Description

Found by the UI gate Kanban journey (2026-09-08). KanbanService.plan returns .block(reasonRequired: true) for upNext→blocked and running→blocked, but KanbanBlockReasonSheet labelled the field "Reason (optional)" and enabled Block with it empty, so the move failed with "A reason is required to mark a task blocked" in the error banner while the card stayed put. The CLI itself accepts an empty reason; the requirement is Scarf's own design (reasons feed the worker on unblock). Fixed on ui-gate: field labelled required, Block disabled until non-empty, banner carries `kanban.error`, journey types a reason.

## Plan



## Artifacts



