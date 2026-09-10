---
id: t-6ba8c1ce
title: Audit P25: Surface completeness and copy
status: todo
added: 2026-09-09
---

## Description

Round-2 whole-surface audit phase P25. Source: `documents/hermes-v0.21.1-whole-surface-audit-round2.md`; brief: `documents/hermes-v0.21.1-parity-agent-brief.md`. Opus agent, tests that fail without the fix, fresh-eyes review, memory note. No HIGH findings — medium priority. See product decisions 1 (iOS markdown), 2 (skills audit-as-reload) and 3 (Redact toggle for trace) in the report; those three items need Alan's call before implementation.

- MED · iOS `UpdatesView` never renders `vm.updateFaults`, so `orphaned`/`unavailable`/`invalid_install` rows parsed by P12 are silently dropped and the tab shows "No updates" — the Mac pane added `updateFaultsSection` in the same phase · `scarf/Scarf iOS/Skills/Updates/UpdatesView.swift:108-116` vs `scarf/scarf/Features/Skills/Views/SkillsView.swift:844-847`
- MED · "Export All" + Trace exports only ONE session (the most recent) while the banner reports a full export — `_export_trace` takes the `not session_id and not filters` branch and resolves via `list_sessions_rich(limit=1)`; `exportAll` passes neither, and `trace` is offered on every context · `scarf/scarf/Features/Sessions/ViewModels/SessionsViewModel.swift:633-635,724-730` · `hermes_cli/sessions_cmd.py:383-388`
- MED · iOS renders a worker-authored kanban card body through `AttributedString(markdown:)` with no scheme allowlist; the Mac inspector deliberately renders the same field as plain `Text` and its comment says the two "must not diverge" — a worker body can plant `[Approve](javascript:…)` (product decision 1) · `scarf/Scarf iOS/Kanban/ScarfGoKanbanDetailSheet.swift:82-88` vs `scarf/scarf/Features/Kanban/Views/KanbanInspectorPane.swift:498-509`
- MED · Every non-running/blocked card's footer reads "3 min. ago ago" — `relativeShort` already returns `localizedString(...)` and the `.done`/`default` arms append a second " ago"; also in the accessibility label · `scarf/scarf/Features/Kanban/Views/KanbanCardView.swift:423-432,449-457`
- MED · iOS diagnostic sheet tells the user to "verify, reject, or unblock" on the Mac app — Verify and Reject were deleted by P14 · `scarf/Scarf iOS/Kanban/DiagnosticDetailSheet.swift:68`
- MED · `reloadSkills()` runs `hermes skills audit` and reports "Skills reloaded", but `do_audit` only re-runs the security scanner and cannot touch a running gateway; the real reload is `/reload-skills`, which has no CLI form (product decision 2) · `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/SkillsViewModel.swift:608-632`, `SkillsView.swift:64-70` · `hermes_cli/skills_hub.py:879-904,113-131`; `gateway/slash_commands.py:1038-1048`
- LOW · The export sheet's "Redact secrets" toggle is a no-op for `trace` — redaction is on by default and opted out with `--no-redact`; `--redact` is ignored (product decision 3) · `SessionsViewModel.swift:724-730`, `SessionsView.swift:597-599` · `sessions_cmd.py:394`, `subcommands/sessions.py:83-84,92-93`
- LOW · The whole Skills block, including "Clear all skills on save", is hidden when the skills roster is empty, so a job's existing skills cannot be edited or cleared on such a host · `scarf/scarf/Features/Cron/Views/CronView.swift:1381,1432`
- LOW · Contradictory skills UI: "Clear all skills on save" and the per-skill checkboxes can both be set; `--clear-skills` (correctly) wins, wiping selections with no warning · `scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift:591` · `hermes_cli/cron.py:612-618`
- LOW · Four `KanbanService` verbs are dead code with zero callers — `claim(taskId:ttlSeconds:)`, `swarm(...)`, `link`, `unlink`; `claim` is contradicted by `KanbanTransitionStep`'s own doc · `KanbanService.swift:332,434,440,516`
- LOW · `hasKanbanGoalMode` now has no consumer at all after P14 · `HermesCapabilities.swift:599`

## Plan



## Artifacts



