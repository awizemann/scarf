---
id: t-6ba8c1ce
title: Audit P25: Surface completeness and copy
status: done
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

Commits on `fix/whole-surface-audit-r2`: `eac1efa3`, `5dbc2f0e`, `2b6e2960`, plus the test re-pin commit.

FIXED
- iOS `UpdatesView` now renders `vm.updateFaults` in the Mac pane's three-state shape (`scarf/Scarf iOS/Skills/Updates/UpdatesView.swift`).
- "Export All" no longer offers `trace` (the CLI's no-arg trace branch exports ONE session; its multi-session path writes a directory, so stdout capture is impossible). Sheet explains where to get a trace. `SessionsViewModel.availableExportFormats` + `exportAllExcludesTrace`.
- Decision 1: iOS kanban card body is plain `Text`; the Mac comment now names the iOS twin as the third site that must not diverge.
- "3 min. ago ago" fixed in both the `.done` and default arms; `relativeTimeLabel`/`relativeShort` extracted as pure `now`-injectable statics and pinned by tests. Accessibility label reuses the same string, so it is fixed too.
- iOS diagnostic sheet copy: "verify, reject, or unblock" → "unblock, complete, or archive" (Verify/Reject deleted by P14; Unblock/Complete/Archive verified present in `KanbanInspectorPane`).
- Decision 2: `reloadSkills()` → `rescanSkills()`; button "Re-scan skills", new tooltip + accessibility label, banner "Skills re-scanned"/"Re-scan failed", doc comment citing `skills_hub.py:879-904` and `gateway/slash_commands.py:1038-1048`. No iOS twin of the button exists.
- Decision 3: new `hasSessionsExportNoRedact` (floor v0.21.1, verified by a walk of all 32 v2026.* tags — `--no-redact` first registered at v2026.9.7, three releases after `--format trace`). `trace` + toggle OFF ⇒ `--no-redact`; ON ⇒ nothing; `--redact` never sent for trace. Below the floor the toggle renders ON and disabled with a caption.
- Cron Skills block rows = roster ∪ the job's own skills, so the block (and "Clear all skills on save") is reachable on an empty roster; turning clear on disables the checkboxes with a caption instead of discarding them at save.
- Four dead `KanbanService` verbs deleted (`claim`, `swarm`, `link`, `unlink`) — zero callers in Mac, iOS or tests.

NO-OP (with evidence)
- `hasKanbanGoalMode` kept. P18 already gave it the `**No consumer yet**` note the file's convention requires, and `HermesCapabilities.swift` deliberately retains other consumer-less flags with verified floors (`hasInsightsCommand:651`, `hasDashboardCommand`). Deleting only this one would discard a source-verified floor and break the file's own convention. Flag for Alan if deletion is still wanted.

TESTS
- New `scarf/scarfTests/AuditP25SurfaceCopyTests.swift` (9 tests). Verified to FAIL (4 tests, 9 issues) when the argv branch, the export-all filter and the two label arms are reverted.
- `HermesCapabilitiesTests`: `hasSessionsExportNoRedact` added to all-on / 0.21.0-hides / patch-still-on / empty-false, with the "`--format trace` itself stays on at 0.21.0" counter-assertion.
- `SessionExportRemoteDestinationTests` "redact with trace over stdout" re-pinned — it asserted the old no-op `--redact` shape.
- ScarfCore: 2586 tests, 171 suites, all pass. Mac target: full run green apart from known parallel-load flakes (ACP `session/cancel` suites, `BotAgentViewModelTests`, `AnalyticsFeatureUsageEventsTests`) which pass in isolation.
- `scripts/check-hermes-tables.py` not run: it scans none of the files touched.

TASK CREATED
- `t-14f9a3e5` — `SkillDetailView.swift:301` renders a skill's own SKILL.md through `AttributedString(markdown:)` with no link-scheme allowlist (same vector, out of phase).

