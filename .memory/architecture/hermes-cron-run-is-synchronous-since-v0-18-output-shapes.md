---
title: hermes cron run is synchronous since v0.18 — output shapes and Scarf's verdict
type: note
permalink: scarf/architecture/hermes-cron-run-is-synchronous-since-v0-18-output-shapes
tags: [hermes, cron, cli-contract]
source_paths: [scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift]
source_paths_inferred: false
source_sha: 70efa831cb229c14ceafbcddfbf611856e610c30
created: 2026-09-26
updated: 2026-09-26
reviewed: 2026-09-26
reviewed_by: audit:claude-code (background)
---

What `hermes cron run <id>` actually does per host generation, verified against tagged source (P7f, 2026-09-26). Scarf judges it in CronViewModel.runNowVerdict.

## Observations
- [fact] <=v0.17 `cron run` only marks the job due and prints 'It will run on the next scheduler tick.' (hermes_cli/cron.py:315-316 @ v2026.6.19); from v0.18.0 it RUNS the job synchronously via _execute_job_now (tools/cronjob_tools.py:604 @ v2026.7.1), and from v0.20.2 _job_action forces the sync path with _SESSION_ASYNC_DELIVERY.set(False) #cron
- [gotcha] A run that was skipped still exits 0 after the green 'Triggered job:' line: 'Job is paused/disabled; resume it before running.', 'Job no longer exists; nothing to run.', '(Job is a|A)lready being fired by the scheduler; not run again.' (cronjob_tools.py:192-198, :716-717 @ v2026.9.24) #cron
- [gotcha] Relay-fronted jobs are forwarded to the gateway (POST /api/jobs/{id}/run); the result has no job dict, so the CLI prints 'Triggered job: <id> (<id>)' + the old next-tick line — indistinguishable from a v0.17 mark-due #cron
- [decision] Scarf caps cron run at 1800 s (ONESHOT_RUN_CLAIM_TTL_SECONDS) and reads its own transport timeout as amber 'unconfirmed', never a failure; a short cap SIGTERMs a live agent run and leaves a stale claim #cron
- [gotcha] `cron create/edit --pin` with no model.default configured silently stores an unpinned job (_main_model_pin returns (None, None), cron/jobs.py:1593-1610); only the reloaded record reveals it #cron
