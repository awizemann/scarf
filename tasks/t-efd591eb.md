---
id: t-efd591eb
title: R04 Cron: Run Now tick, widget state, timezone, project archive, prefix
status: done
added: 2026-09-26
priority: high
---

## Description

Findings S08-F1, S08-F2, S08-F3, S11-F2, S11-F5, S03-F6. Wave 1. Branch fix/hermes-v0215-audit-r04, worktree Scarf-wt/r04.

## Plan

R04 cron (worktree Scarf-wt/r04, branch fix/hermes-v0215-audit-r04)
- S08-F1: CronViewModel.runNow sends the follow-up `cron tick` only when the verdict is `.started` AND the host is pre-v0.18 (new `hasCronRunSynchronous` = isV018OrLater; floor v2026.7.1 where `_execute_job_now` + `Ran now:` landed). Wired from CronView + BotsView like the other cron flags. Blast radius: Mac Cron tab + Bot routines (same VM). iOS has no Run Now tick. Tests: HermesP7fCronPeersTests (tick sent on v0.17 .started; not on v0.18+ or any non-started verdict).
- S08-F2: CronStatusWidgetView badges from HermesCronJob.effectiveState via a static pure mapping. Mac only. Test: new unit on the mapping.
- S08-F3: CronScheduleFormatter gains a zone note (config `timezone` when it differs from the Mac's zone, "host time" on remote with none) appended to wall-clock cron phrases; Mac CronViewModel + iOS IOSCronViewModel read config.yaml `timezone` off-main. Tests: ScarfCore formatter tests.
- S11-F2: archive pauses only enabled attributed jobs, records the ids it paused in the registry row (extra key), surfaces pause failures via mutationError; unarchive resumes only recorded ids that are still paused, then clears the record. Injectable cron runner on ProjectLifecycleService for tests. Tests: ProjectsD2LifecycleTests round-trip.
- S11-F5: ManagedBlockInput gains projectId; block's Cron jobs line tells the agent the `--name "[proj:<uuid>] …"` convention. Tests: ProjectContextBlockManagedTests.
- S03-F6: rewrite scarf-cron.md to the real argv (positional schedule/prompt, no --json, no print, no context-from), bump version 1.1.0. Verified with live `hermes cron create --help` @ v2026.9.24.
Memory/wiki: search cron run-now/tick, archive/cron pause, project context block, scarf-cron notes; correct as needed.

## Artifacts

Merged as 00ed34d8 (11 commits, ac8159af last). ScarfCore 3843 green on integration. Agent: full scarfTests 1605, Mac+iOS builds. Fresh-eyes: sound, all should-fix + nits fixed. Decisions: legacy archive restore resumes nothing + notice (via mutationError alert); --workdir ungated (floor v0.12.0 recorded); shell-only HERMES_TIMEZONE accepted. [tmpl:] cross-project attribution moved to R12.

