---
id: t-8e9ddad0
title: Audit P42: cron/kanban residue — dash-leading option values, tenant premise, fleet monitor jobs
status: todo
added: 2026-09-10
---

## Description

Round-4 whole-surface audit (documents/hermes-v0.21.1-whole-surface-audit-round4.md, cron/kanban section). Needs round-4 product decisions 5 (completed recurring job: Duplicate affordance), 6 (iOS re-arm gesture or keep the pointer), 7 (dash-leading user text: `--flag=value` vs editor refusal), 8 (fleet-copied monitor jobs).

- MED · PRE · A user-typed option VALUE beginning with `-` makes argparse exit 2 (`--` protects positionals only): `--name/--deliver/--prompt/--workdir/--failure-deliver` in `CronViewModel.swift:637-651,784-800`, `FleetApplyPlan.swift:408-437`; `--author/--result/--summary` in `KanbanService.swift:333-343,347-365` (`subcommands/cron.py:25-31,88-96` @ v2026.9.7). Fix per decision 7: single-token `--name=<value>` form, or editor refusal.
- MED · PRE · `KanbanTenantResolver.swift:7-11` premise "Hermes Kanban has no `project_id` column" is false at target: `tasks` DDL has `project_id TEXT` (`hermes_cli/kanban_db.py:866-869`, plumbing `:1096-1176`), `_TASK_DICT_FIELDS` emits it (`kanban_output.py:18-24`). Re-verify and restate the rationale (tenant is still the Scarf-scoped key because `project_id` references Hermes's projects DB) or adopt `project_id`. Fold t-dafcc4a5.
- MED · PRE · `cronCreateArgs(copying:)` (`FleetApplyPlan.swift:340-384`) drops `monitor_script`/`monitor_url` and `--continuity` silently, so a copied monitor job becomes a full agent job every tick (`subcommands/cron.py:51-66,80-84`). Decision 8: forward behind floors or skip-and-surface like `no_agent` (`FleetApplyExecutor.swift:302-305`).
- LOW · PRE · Detail-pane state badge reads `job.enabled` not `effectiveState` (`CronView.swift:564-565`; `stateDisplay` exists at `HermesCronJob.swift:500`).
- LOW · PRE · `modelOverride` decode comment false: `list --json` also emits `model_override` via `_task_to_dict` (`hermes_cli/kanban.py:429,381`) · `HermesKanbanTask.swift:190-196`.
- LOW · PRE · `kanban complete` appends ids with no `--` while `unblock` does (`KanbanService.swift:363`).
- LOW · PRE (t-dafcc4a5) · `project_id`/`provider_override` emitted, never decoded (`HermesKanbanTask.swift:142-159`, `KanbanInspectorPane.swift:220`).

## Plan



## Artifacts



