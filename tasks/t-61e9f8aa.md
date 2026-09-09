---
id: t-61e9f8aa
title: v0.21.1 P3: Cron — paused create, failure-deliver, dispatch diagnostics, guards
status: done
added: 2026-09-08
priority: high
---

## Description

Phase 3 of the Hermes v0.21.1 parity plan (brief: documents/hermes-v0.21.1-parity-agent-brief.md; findings: documents/hermes-v0.21.1-audit-report.md). Depends on P0. Read memory note decisions/hermes-v0-21-compatibility-decisions section W7 (cron parity) first — it documents the existing cron contracts and gotchas (doctor exits 1 on findings, terminal-job guards, capability re-run on .onChange).

Scope, all verified against v2026.9.7 source (hermes_cli/subcommands/cron.py, hermes_cli/cron.py, cron/jobs.py, cron/scheduler_delivery.py, cron/lifecycle_guard.py):
1. C2 `cron create --paused [--paused-reason TEXT]` (subcommands/cron.py:47-49,84-87; jobs.py:1781; prints `Created PAUSED — resume to schedule, or explicitly run now.` instead of `Next run:`). Gate on `hasCronCreatePaused`. Use it to replace the create-then-`cron pause` two-step in ProjectTemplateInstaller.swift:346 and FleetApplyExecutor.swift:349 when the host supports it, keeping the two-step fallback for older hosts. Update the create-output parser for the new success line.
2. C3 `--failure-deliver <target>` on create/edit (subcommands/cron.py:33,94; jobs.py:1546,1589,1803; scheduler_delivery.py:790-801; `local` suppresses failure notices). Model `failureDeliver` on HermesCronJob (currently rides in `extra`), edit it in the cron editor next to Deliver with the same target grammar and the same `supportsCronDeliver` gating, and make FleetApplyPlan.cronCreateArgs (FleetApplyPlan.swift:370-386) forward it only to hosts with `hasCronFailureDeliver`.
3. C4 read-only diagnostics: decode `last_dispatch {scheduled_at, dispatched_at, kind: on_time|late|catch_up, lateness_seconds}` and `last_delivery_unverified` (jobs.py:1418, hermes_cli/cron.py:103-121,433-444); render them in the job detail pane (late/catch-up badge, "delivery unverified" warning). Schema-detect by field presence, not version.
4. A7: `cron doctor` no longer emits `last run failed:` when last_status == delivery_failed. Confirm HermesCronDoctorParser and any issue counting still behave; add the new doctor issue string `last delivery unverified (adapter acked without evidence): <targets>` to the fixture and make sure it parses into a distinct, rendered issue kind.
5. A8: `create_job` rejects a one-shot `run_at` older than the grace window with a non-zero exit (jobs.py::_next_run_or_reject_past_oneshot). Pre-check in the create sheet using the existing `oneShotGraceSeconds` (HermesCronJob.swift:291) and translate the Hermes error text via friendlyCronFailure.
6. A9: lifecycle guard may refuse `cron create --script` on cloud-placeholder files with a "refused without opening" message (lifecycle_guard.py:367-389,780-800). Surface stderr verbatim in the create failure path rather than a generic message; add a test with that stderr.
7. Drift alarms: fixtures captured from the tagged f-strings for `cron list` `Dispatch:` and `⚠ Delivery UNVERIFIED:` rows and the `Created PAUSED` line; reconfirm `cronRunsFormatUnchangedAtV021`-style tests still pass and add the v0.21.1 sibling.

Out of scope: deliveries.db / executions table (server-side).

## Plan



## Artifacts

Commit `d1bd1b3d` on `feat/hermes-v0211-parity` — "feat(cron): v0.21.1 paused create, failure-deliver, dispatch diagnostics" (9 files, +821/-16).

Shipped, all seven scope items:
1. **C2 `--paused`** — `FleetApplyPlan.cronCreateArgs(…, paused:)` appends `--paused` only when `caps.hasCronCreatePaused`. `ProjectTemplateInstaller.createCronJobs` and `FleetApplyExecutor` now skip the create-then-`cron pause` second write entirely on a v0.21.1 host (`guard !caps.hasCronCreatePaused`), keeping the two-step for older ones. The executor's "N could NOT be paused" tally accounts for the one-write path.
2. **C3 `--failure-deliver`** — `HermesCronJob.failureDeliver` accessor; new "Failure deliver" editor row + hint (hidden AND stripped below v0.21.1); detail-pane row that names `local` suppression explicitly; `createJobArguments(failureDeliver:)` / `updateJob(failureDeliver:)` (`""` forwarded on edit = Hermes's clear gesture); `cronCreateArgs` forwards it through BOTH gates (`hasCronFailureDeliver` for the flag, `supportsCronDeliver` for the value).
3. **C4 diagnostics** — new `CronDispatchStamp` (kind on_time/late/catch_up + a port of `_format_lateness`) and `lastDeliveryUnverifiedTargets`, rendered in the detail pane as a late/catch-up badge and a "delivery unverified" note, gated on `hasCronDispatchDiagnostics` and decoded by field presence.
4. **A7 doctor** — parser grammar unchanged (confirmed against `_cron_doctor_issues_for_job`); added `HermesCronDoctorFinding.severity/problemIssues/unverifiedIssues` so the new "last delivery unverified" issue renders and counts apart from real faults, and the new string is in the fixture.
5. **A8 past one-shot** — `HermesCronJob.oneShotScheduleIsPastGrace(_:now:)` pre-check in `createJob`, gated on `isV0211OrLater`; `friendlyCronFailure` also translates Hermes's own rejection text.
6. **A9 lifecycle guard** — `CronViewModel.blockedSentence(in:)` surfaces the whole `Blocked: …` sentence verbatim instead of the `prefix(200)` stub that cut off the remedy.
7. **Drift alarms** — `HermesV0211CronParityTests` (18 tests) incl. `cronRunsFormatUnchangedAtV0211` and a `Dispatch:` / `Delivery UNVERIFIED` content fixture.

Deliberate NO-OPs: `last_dispatch` / `last_delivery_unverified` / `failure_deliver` are NOT added to `CodingKeys` (read through `extra` so the pause/resume rewrite keeps their bytes verbatim); `cron list` / `cron status` text parsing untouched (Scarf reads jobs.json); deliveries.db out of scope as stated.

Tests: ScarfCore `swift test` 2336 tests / 150 suites — only the known `ACPClientStartIdempotenceTests` parallel-load flake, green in isolation. App target `-only-testing:scarfTests` 821 tests / 107 suites, all pass. Both build targets clean.

Follow-up filed: `t-ff609789` — `FleetApplyPlan.cronCreateArgs` and `ProjectTemplateInstaller.createCronJobs` are both missing argparse's `--` end-of-options marker that `CronViewModel.createJobArguments` has (a dash-leading prompt aborts the copy / the whole template install).

Memory: Phase 3 section appended to `scarf/decisions/hermes-v0-21-1-compatibility-decisions`.

