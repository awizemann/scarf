---
id: t-dafcc4a5
title: Decide on kanban project_id / provider_override (P30 LOW deferral)
status: todo
added: 2026-09-10
priority: low
---

## Description

Deferred from P30 (`t-f1f8fe74`), round-3 audit LOW. `HermesKanbanTask` never decodes two keys Hermes emits in every `kanban ... --json` task envelope:

- `hermes_cli/kanban_output.py:20` — `project_id` (inside `_TASK_DICT_FIELDS`)
- `hermes_cli/kanban_output.py:22` — `provider_override` (same tuple), verified at `v2026.9.7`.

Scarf's `CodingKeys` (`scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesKanbanTask.swift:142-159`) has neither. P30 left them undecoded on purpose: the charter's "prefer reusing an existing surface over adding one" rule plus the P18 lesson (ten never-emitted keys were DELETED for being decoded-but-dead) mean a key with no consumer earns no property.

Two things to decide:

1. **`provider_override`** is the obvious sibling of `model_override`, which `KanbanInspectorPane.swift:220` already renders as a read-only `Model: …` chip behind `supportsKanbanV015`. If a `Provider: …` chip is wanted, decode it and add the chip; verify its own floor by walking the tags for `provider_override` in `_TASK_DICT_FIELDS` and gate accordingly (C1/C2).
2. **`project_id`** has no Scarf consumer at all, AND `scarf/scarf/Core/Services/KanbanTenantResolver.swift:7` opens with "Hermes Kanban has no `project_id` column" as the justification for the `scarf:<slug>` tenant surrogate. Confirm against the tagged schema whether that is still true (the emitter now lists the key); if the column exists, the comment is stale even if the tenant surrogate stays the right design, and it should be corrected so nobody re-derives the wrong reason later.

## Plan



## Artifacts



