---
title: Hermes cron recovery is three doors, not one — and Scarf must model all three
type: note
permalink: scarf/architecture/hermes-cron-recovery-is-three-doors-not-one-and-scarf-must
tags: [hermes, cron, capability-gating, v0.21]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesCronJob.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/CronRecoveryOffer.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/IOSCronViewModel.swift, scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift]
source_paths_inferred: false
source_sha: ca6ae1e8832242f31b5c6ccdd3b390186b1af8cb
created: 2026-09-10
updated: 2026-09-10
reviewed: 2026-09-10
reviewed_by: claude-opus-5
---

Hermes has three separate activation doors for a cron job, each with its OWN terminal predicate. Scarf modelled them as one (`isTerminal`) and produced two dead ends. `CronRecoveryOffer` + `HermesCronJob.recoveryOffer(hostRefusesTerminalJobs:hostRecoversErrorRecurring:)` is the single port; both platforms' view models delegate to it, and `scarfTests/CronRecoveryOfferP30Tests` is the drift alarm.

| door | Hermes predicate @ v2026.9.7 | recurring `error` | recurring `completed` | terminal `once` |
|---|---|---|---|---|
| `resume_job` -> `update_job` | `is_terminal_job and not _is_recoverable_error_job` (`cron/jobs.py:1865-1878`) | OK from v0.21.0 | refused | refused |
| `rearm_oneshot` (`resume --run-now` / `--at`) | the job's OWN `schedule.kind != "once"` raises `_REARM_RECURRING_ERROR` (`:2040-2042`, `:2065-2066`) | refused | refused | OK |
| `trigger_job` (`cron run`) | bare `is_terminal_job` (`:2012`) | refused | refused | refused |

The `rearm_oneshot` guard is checked twice: once on the PARSED `run_at` (always `once` for an injected `now`, so it never fires on the `--run-now` path) and once on the job's own schedule inside `apply` — only the second one matters. `cron_resume` turns either into exit 1 (`hermes_cli/cron.py:691-695`).

## Observations
- [constraint] `_is_recoverable_error_job` is `state == "error" and schedule.kind in {"cron","interval"}`; first tag with it is v2026.8.31 (0.21.0), last without it v2026.8.27 (0.20.6) — hence `hasCronRecoverableErrorResume = isV021OrLater` #capability-gating
- [constraint] Re-arm (`cron resume --run-now`) is one-shot-only and always has been: the own-schedule guard is inside `rearm_oneshot` at the function's first tag, v2026.8.27 (0.20.6) — the same floor as `hasCronResumeRunNow`, so it needs no flag of its own #cron
- [gotcha] The resume gate and the run gate are DIFFERENT predicates: `update_job` exempts recoverable-error jobs, `trigger_job` does not — so a recurring job in `error` is resumable and not runnable, and sharing one `refusesTerminalJobLocally` for both is a bug #cron
- [decision] A recurring job that reached `completed` gets no button in Scarf, only the hint "No future occurrences — edit the schedule to run it again" — every Hermes door is shut for it (round-3 product decision 1) #cron
- [gotcha] Hermes's pause marker is `bool(job.get("paused_at"))` (`cron/jobs.py:479`), Python truthiness — `""`, `0`, `false`, `[]`, `{}` are NOT markers; reading any non-null as one made Scarf render "paused" for a job the host kept firing #cron

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Hermes Capability Gating Pattern]]
