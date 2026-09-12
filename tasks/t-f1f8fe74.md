---
id: t-f1f8fe74
title: Audit P30: cron recovery semantics — recurring resume and re-arm
status: done
added: 2026-09-10
priority: high
---

## Description

Round-3 whole-surface audit (`documents/hermes-v0.21.1-whole-surface-audit-round3.md`, cron section). Both PRE-existing, HIGH. Needs product decision 1 (cron) from the report before scoping.

- HIGH · "Resume & Run Now" can never succeed on a recurring job, and Scarf offers it for every paused one: `rearm_oneshot` rejects a non-`once` schedule (`cron/jobs.py:2040-2042,2065-2066` @ v2026.9.7, `_REARM_RECURRING_ERROR`), `cron_resume` returns 1 (`hermes_cli/cron.py:691-695`). Scarf shows the button for any paused job (`CronView.swift:596-605`, `CronViewModel.swift:408-414`, `BotRoutinesView.swift:129-136`).
- HIGH · A recurring job in `state == "error"` has no recovery path in Scarf though Hermes has one: `_reject_terminal_activation` exempts `_is_recoverable_error_job` (`cron/jobs.py:1865-1878`, `:504-522`), so plain `cron resume` recovers it; Scarf's `isTerminal` (`HermesCronJob.swift:509-513`) blocks Resume client-side (`CronViewModel.swift:389-391,401-404,419-422`) and points at the dead-end re-arm. iOS (`IOSCronViewModel.swift:142`) lets the CLI decide, so the two platforms disagree.
- LOW · "Resumed — running now" overstates `--run-now` (sets `next_run_at`, no dispatch until the scheduler tick) · `CronViewModel.swift:412-414` · `cron/jobs.py:2055,2072-2075`.
- LOW · pause-marker truthiness: Hermes `bool(job.get("paused_at"))` (`cron/jobs.py:479`), Scarf any non-null · `HermesCronJob.swift:484-488`.
- LOW · `HermesKanbanTask` never decodes emitted `project_id`/`provider_override` (`kanban_output.py:20,22`) · `HermesKanbanTask.swift:142-159`, consumer `KanbanInspectorPane.swift:220`.

Fix shape: mirror both Hermes predicates (`isRecoverableErrorJob`, re-arm only for `schedule.kind == "once"`), align iOS and Mac, tests both directions.

## Plan



## Artifacts

Commit `017be699` `fix(p30): mirror Hermes's three cron recovery doors instead of one isTerminal` on `fix/whole-surface-audit-r3`.

**Shipped**
- `HermesCronJob.isRecoverableErrorJob` (port of `_is_recoverable_error_job`, `cron/jobs.py:504-522` @ v2026.9.7) and `HermesCronJob.isRearmableOneShot` (port of `rearm_oneshot`'s own-schedule guard, `:2040-2042`, `:2065-2066`).
- New `CronRecoveryOffer` + `HermesCronJob.recoveryOffer(hostRefusesTerminalJobs:hostRecoversErrorRecurring:)` — one function; `CronViewModel`, `BotRoutinesViewModel` and `IOSCronViewModel` all delegate to it, so Mac and iOS make identical offers.
- New capability `hasCronRecoverableErrorResume = isV021OrLater`, mirrored by `CronView`, `BotsView` and (new) iOS `CronListView`, `.onChange` included. Floor walked across all 32 `v2026.*` tags: first tag `v2026.8.31` (0.21.0), last without `v2026.8.27` (0.20.6).
- Decision-1 behaviour: plain Resume for paused + recoverable-error recurring; "Resume & Run Now" only for `once`; recurring `completed` gets no button, only "No future occurrences — edit the schedule to run it again".
- LOW: re-arm toast is now "Re-armed — will run at the next scheduler tick".
- LOW: `isTruthyPauseMarker` — Python truthiness for `paused_at`, matching `bool(job.get("paused_at"))` (`:479`).

**Deliberate NO-OPs**
- `refusesTerminalJobLocally` left as the BARE `is_terminal_job` test: `trigger_job` (`:2012`) has no recoverable-error exemption, so Run Now stays refused for a job Resume now accepts. Pinned by `runNowStaysRefusedForARecoverableErrorJob`.
- Re-arm's one-shot-only restriction got NO new flag: the guard is inside `rearm_oneshot` at that function's own first tag (v2026.8.27), which is already `hasCronResumeRunNow`'s floor.
- LOW 3 (`project_id` / `provider_override` on `HermesKanbanTask`) deferred — no consumer needs either. Filed as `t-dafcc4a5`, which also asks whether `KanbanTenantResolver.swift:7`'s "Hermes Kanban has no `project_id` column" is still true.

**Tests**: `HermesCronRecoveryP30Tests` (14, ScarfCore), `CronRecoveryOfferP30Tests` (5, scarfTests, including a full state × kind × floor Mac/iOS parity matrix), plus 3 new/rewritten cases in `CronViewModelErrorClassificationTests` and the flag added to the four-test capability pattern. ScarfCore 2617/2617.

**Memory**: new note `scarf/architecture/hermes-cron-recovery-is-three-doors-not-one-and-scarf-must`; P30 section appended to `scarf/decisions/hermes-v0-21-1-compatibility-decisions`; two stale claims corrected in `scarf/decisions/hermes-v0-21-compatibility-decisions`.

