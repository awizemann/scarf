# S08-cron — verdict: WORKS-WITH-ISSUES

Primary cron journeys (list, create, edit, pause/resume/re-arm, delete, Run Now verdict, run history, doctor, incidents)
are correct against Hermes 0.21.5 (tag v2026.9.24). Every argv matches the tagged argparse (LIVE `--help` probes plus a
parse simulation using Hermes's own `build_cron_parser` under the venv's Python 3.11). Every exit-0 failure path in
`hermes_cli/cron.py` is handled. There are three findings, all P2/P3.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | List jobs (direct `cron/jobs.json` read, profile/remote via `context.paths`) | WORKS | — |
| 2 | Create job (schedule positional, --name/--deliver/--failure-deliver/--repeat/--skill/--script/--workdir/--no-agent/--pin, `--` guard) | WORKS | — |
| 3 | Edit job (diffed skills, prompt/repeat clear gestures, --pin/--unpin, `-- <id>`) | WORKS | — |
| 4 | Pause / Resume / Resume --run-now | WORKS | — |
| 5 | Delete (`cron remove`) | WORKS | — |
| 6 | Run Now (synchronous `cron run` + outcome judging) | DEGRADED | F1 |
| 7 | Run history (`cron runs <id> --limit 20`) + latest output file | WORKS | — |
| 8 | Cron doctor + incidents list/ack | WORKS | — |
| 9 | Schedule formatting / timezone | DEGRADED | F3 |
| 10 | OAuth keep-alive cron service | WORKS | — |
| 11 | Project cron-status dashboard widget | DEGRADED | F2 |
| 12 | iOS cron list (CLI pause/resume/re-arm; jobs.json writes) | WORKS | JSON-write path TRACKED (deliberate design) |

## Findings

### S08-cron-F1 · P2 · SOURCE · NEW
- Claim: every Run Now is followed by an unconditional `hermes cron tick` with a 300 s cap. On v0.18+ this tick is not "redundant but harmless" as the code comment says: it synchronously fires every other due or overdue job inside the Scarf-spawned process, and Scarf kills that process at 300 s.
- Scarf: `scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift:902-916` (tick after every verdict, `mutationRunner(["cron","tick"], 300)`); rationale comment `:860-866`.
- Hermes @v2026.9.24: `hermes_cli/cron.py:289-307` (`cron_tick` → `tick(verbose=True)`); `cron/scheduler_tick.py:33-37` (the file lock is held only while a tick runs, so a CLI tick between gateway ticks acquires it); `:62-116` (`get_due_jobs`, submit all, `sync=True` waits on every future); `cron/jobs.py:2789-2798` (a job stale by more than one period "still fires ONCE now").
- Failure scenario: the gateway is not running (the case the comment names as common) and jobs B and C are overdue. The user clicks Run Now on job A. A runs synchronously and the bar says "Run finished". Then the follow-up tick fires B and C in the CLI process, which delivers their output to Telegram/Discord/etc. That is an action the user never asked for. Any of them still running at 300 s is SIGTERMed mid-LLM-call, leaving a claimed execution and a failed or stale run. That is the same damage `runNowTimeout`'s own doc comment (`:731-738`) says the old 30 s cap caused. The tick's non-zero exit is only logged. With a gateway running, the same thing can happen to any job that came due since the gateway's last 60 s tick.
- Evidence: `_tick_admitted` → `due_jobs = _sched.get_due_jobs()` … `for job in due_jobs: _submit_with_guard(...)` … `if sync: for f in as_completed(_all_futures)`. Scarf's comment says the tick "runs every due job once and exits".
- Suggested fix: send the follow-up `cron tick` only when the run verdict is `.started` on a pre-v0.18 host (no `Ran now:` line). Never send it after `.ran`/`.failed`/`.refused`/`.alreadyRunning`.

### S08-cron-F2 · P2 · SOURCE · NEW
- Claim: the project dashboard's cron-status widget badges raw `enabled`/`state` instead of the effective state. As a result, every paused job and every finished one-shot shows "DISABLED", and a job never shows "PAUSED" or "COMPLETED".
- Scarf: `scarf/scarf/Features/Projects/Views/Widgets/CronStatusWidgetView.swift` `stateBadge(for:)` (`if !job.enabled { return ("DISABLED", .neutral) }` before the state switch). Compare `HermesCronJob.effectiveState` (`scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesCronJob.swift:703-714`), which the Cron tab uses.
- Hermes @v2026.9.24: `cron/jobs.py:2073-2074` (pause writes `enabled: False, state: "paused"`); `:1563` (completion writes `enabled=False, state="completed"`); `:527-540` (`effective_job_state`: terminal states win, and disabled plus a pause marker means "paused").
- Failure scenario: the user pauses a project's job, or a one-shot finishes. The Cron tab shows paused/completed, but the project dashboard widget shows a grey "DISABLED" for both, a state Hermes never reports for either.
- Suggested fix: badge from `job.effectiveState` (paused → warning, completed → neutral/success, error → danger).

### S08-cron-F3 · P3 · SOURCE · NEW
- Claim: cron-expression schedules are rendered as wall-clock phrases ("Daily at 9 AM", "Weekdays at 4 AM") with no zone. Hermes evaluates them in its own configured timezone, which can differ from the Mac's. One-shots, by contrast, are rendered in the Mac's zone.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/CronScheduleFormatter.swift:146-213` (`translate`) vs `:99-108` (`onceDescription`, rendered via `Date.formatted` in the Mac's zone). Both are used by the Mac rows (`CronView.swift:620,740`) and iOS (`CronListView.swift:250`).
- Hermes @v2026.9.24: `cron/jobs.py:1023` (`croniter(expr, _hermes_now())`); `hermes_time.py:3-5` (zone = `HERMES_TIMEZONE` → config `timezone` → server-local).
- Failure scenario: an SSH server running in UTC, or a host with `timezone:` set, viewed from a Mac in PST. `0 9 * * *` is shown as "Daily at 9 AM" but fires at 2 AM local. The relative "Next run in …" line is correct, so the two lines disagree.
- Suggested fix: append the host zone when it is known (config `timezone`), or label the phrase "(host time)" for remote contexts.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `~/.hermes[/profiles/X]/cron/jobs.json` read (`{"jobs":[…],"updated_at"}`) | file | HermesFileService.swift:333-345; HermesPathSet.swift:71 | cron/jobs.py:73-74,153-167,1477-1478 | OK |
| job fields (id,name,prompt,skills/skill,model,schedule{kind,expr,minutes,run_at,display},enabled,state,deliver(str),next_run_at,last_run_at,last_error,script,last_delivery_error,workdir,context_from,no_agent,attach_to_session; others kept in `extra`) | JSON shape | HermesCronJob.swift:183-245,1465-1481 | cron/jobs.py:1815-1851 | OK |
| `cron/output/<id>/<YYYY-mm-dd_HH-MM-SS>.md` latest | file | HermesFileService.swift:358-376 | cron/jobs.py:3281-3292,411-419 | OK |
| `cron create [--name= --deliver= --failure-deliver= --repeat= --skill=… --script= --workdir= --no-agent --pin] -- <schedule> [<prompt>]` | argv | CronViewModel.swift:1031-1070 | subcommands/cron.py:23-89; cron.py:698-722 (exit 1 on failure) | OK (LIVE) |
| `cron edit [flags] -- <id>` incl. --clear-skills/--add-skill/--remove-skill/--prompt=""/--repeat=0/--agent/--pin/--unpin | argv | CronViewModel.swift:1099-1227 | subcommands/cron.py:91-146; cron.py:725-763 | OK (LIVE) |
| `cron pause <id>` / `cron resume <id>` | argv | CronViewModel.swift:463,548 | cron.py:766-794,812-820 | OK |
| `cron resume <id> --run-now` | argv | CronViewModel.swift:567 | subcommands/cron.py:152-155; cron.py:812-832 | OK |
| `cron remove <id>` | argv | CronViewModel.swift:921; OAuthKeepaliveCronService.swift:124 | cron.py:895; cronjob_tools.py:648-657 | OK |
| `cron run <id>` (1800 s) + verdict markers (Triggered/Ran now/skip sentences) | argv+parse | CronViewModel.swift:611-621,783-809,889; HermesCLIOutcome.swift:696-732 | cron.py:766-809; cronjob_tools.py:184-205,670-720 | OK |
| `cron tick` (300 s, after every Run Now) | argv | CronViewModel.swift:909 | cron.py:289-307; scheduler_tick.py:7-121 | FINDING-F1 |
| `cron runs <id> --limit 20` + line parser | argv+parse | CronViewModel.swift:268; HermesCronRunsParser.swift | subcommands/cron.py:168-171; cron.py:310-322 | OK (LIVE) |
| `cron incidents` list parser | argv+parse | CronViewModel.swift:322; HermesCronIncidentsParser.swift | cron.py:329-372 | OK |
| `cron incidents ack <id>` (exit-0 miss) | argv+parse | CronViewModel.swift:350-371 | cron.py:336-345 | OK |
| `cron doctor` (exit 1 = findings) + parser/sentinels | argv+parse | CronViewModel.swift:415-458; HermesCronDoctorParser.swift | cron.py:611-667 | OK |
| `--pin` did-not-take check (`model` empty after reload) | JSON | CronViewModel.swift:111-162; HermesCronJob.swift:1094 | cron/jobs.py:1593-1610,1928-1941 | OK |
| OAuth keep-alive `cron create --name <n> "0 4 * * *" "<prompt>"` / remove / detect by name | argv+JSON | OAuthKeepaliveCronService.swift:73-133 | cron.py:698-722 | OK |
| Widget badge from enabled/state | JSON | CronStatusWidgetView.swift stateBadge | cron/jobs.py:527-540,1563,2073 | FINDING-F2 |
| Schedule phrase / next-run rendering | display | CronScheduleFormatter.swift | cron/jobs.py:772-866,1023; hermes_time.py:3-5 | FINDING-F3 (next-run relative OK) |
| iOS `hermes cron pause|resume <id> [--run-now]` via transport (30 s) | argv | IOSCronViewModel.swift:451-477 | cron.py:766-832 | OK |
| iOS jobs.json whole-file rewrite (create/edit/delete/toggle fallback) with baseline guard | file write | IOSCronViewModel.swift:503-603 | cron/jobs.py:1477 | TRACKED (.memory/decisions/hermes-v0-21-1-compatibility-decisions.md:4313; absent-vs-unreadable…md:36) |

## Not audited / couldn't verify
- Did not run any mutating verb. The Run Now / tick behaviour is traced from source only.
- Whether a cron-fired session actually refreshes a Nous OAuth refresh token (the keep-alive's premise). The scheduler resolves the runtime provider (`cron/scheduler.py:1725-1743`), but the provider's refresh-on-resolve internals are S06's territory.
- Remote SSH: kill-on-timeout semantics for the remote process (the local process is terminated; the remote `hermes` may keep running). Belongs to S15.
- iOS create/edit field-by-field parity with `update_job` validations: already covered by prior rounds (P50/P50b/P56) and not re-derived.
