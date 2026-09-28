# S08-cron — verdict: WORKS-WITH-ISSUES

Hermes reference: `~/.hermes/hermes-agent-v0215` @ `v2026.9.24`. Everything primary (list, create, edit, pause/resume,
re-arm, delete, Run Now verdicts, run history, doctor, incidents, keep-alive) matches the tagged argparse and output
formats, and every exit-0 failure path found (`cron run` "Ran now: failed." / skip sentences, `incidents ack` miss,
`doctor` exit 1 on findings) is judged correctly. Three secondary defects, none P0/P1.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | List jobs (Mac + iOS read `cron/jobs.json`; per-record tolerant decode; effective state) | WORKS | — |
| 2 | Create job (`cron create` flags + `--` + schedule/prompt positionals; `--pin` follow-up check) | WORKS | — |
| 3 | Edit job (diffed `--prompt/--repeat/--skill*/--pin|--unpin`, job id after `--`) | WORKS | — |
| 4 | Pause / Resume / Resume & Run Now (`--run-now`) incl. terminal/past-one-shot pre-checks | WORKS | — |
| 5 | Delete (`cron remove <id>`; iOS: guarded jobs.json rewrite) | WORKS | iOS JSON write = TRACKED design |
| 6 | Run Now (synchronous; exit-0 "Ran now: failed." / skip sentences; 1800 s cap) | WORKS | F3 (stale diagnostics after run) |
| 7 | Last-run output panel + project Cron Status widget (`cron/output/<id>/…`) | DEGRADED | F1 (monitor jobs) |
| 8 | Run history (`cron runs <id> --limit 20`) | WORKS | — |
| 9 | Doctor + incidents (`cron doctor`, `cron incidents [ack <id>]`) | WORKS | — |
| 10 | Schedule phrase + host-zone note | DEGRADED | F2 (natural-language phrases get no zone) |
| 11 | OAuth keep-alive cron (create/remove by name) | WORKS | — |
| 12 | iOS cron list/toggle/editor | WORKS | — |

## Findings

### S08-cron-F1 · P2 · SOURCE · NEW
- Claim: For monitor-mode jobs (`--monitor-script`/`--monitor-url`), Scarf's "LAST RUN OUTPUT" panel and the project Cron Status widget show Hermes's monitor snapshot file instead of the job's last run output.
- Scarf: `scarf/scarf/Core/Services/HermesFileService.swift:399-401` (`listDirectory(perJobDir)` → `runs.sorted().last`, no `.md` filter); consumers `scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift:201,265`, `scarf/scarf/Features/Projects/Views/Widgets/CronStatusWidgetView.swift:178`.
- Hermes @v2026.9.24: `cron/monitor.py:30` (`_SNAPSHOT_FILENAME = "monitor_last_output.txt"`), `cron/monitor.py:62-64` (`_job_output_dir(job_id) / _SNAPSHOT_FILENAME`), `:77-85` (written on every monitor evaluation); run outputs are `cron/jobs.py:3287` `<YYYY-MM-DD_HH-MM-SS>.md`. Hermes's own readers filter `glob("*.md")` (`tools/cronjob_tools.py:379`, `cron/jobs.py:3267`).
- Failure scenario: a job created with `hermes cron create "every 1h" --monitor-url https://…` (or by the agent's cronjob tool). After its first tick the per-job dir holds `2026-09-27_10-00-00.md` and `monitor_last_output.txt`; `"monitor_last_output.txt"` sorts after every `2026-…` name, so Scarf shows the raw fetched page / script stdout as the "last run output" — permanently, even after the agent runs and writes new `.md` files. The widget tail shows the same wrong content.
- Evidence: lexical order `'m' (0x6D) > '2' (0x32)`; Hermes only ever lists `*.md` as run output.
- Suggested fix: filter the per-job listing to `*.md` (matching Hermes) before taking the last name.

### S08-cron-F2 · P3 · SOURCE · NEW
- Claim: The host-zone note (added so an SSH host's "9 AM" isn't read as Mac time) is never shown for schedules created from Hermes's natural-language phrases ("every monday 9am", "weekdays at 9am", "every day at 7:30pm"), which Hermes evaluates in its own zone exactly like a cron expression.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/CronScheduleFormatter.swift:113-116` (`namesTimeOfDay` returns false whenever `display` doesn't look like raw cron) and `:132-139` (such a `display` is returned verbatim, justified by a "`hermes cron set-display`" verb that does not exist in `hermes_cli/subcommands/cron.py`). Rendered at `scarf/scarf/Features/Cron/Views/CronView.swift:400-401,634,754-756`, iOS via `IOSCronViewModel.schedulePhrase`.
- Hermes @v2026.9.24: `cron/jobs.py:780-791` (`_natural_every_to_cron` → `_cron_schedule(cron_expr, original, …)`, i.e. `{"kind":"cron","expr":"0 9 * * 1","display":"every monday 9am"}`), fired via `croniter(expr, _hermes_now())` in the configured/host zone (`hermes_time.py:83-106`). `display` is always derived by `parse_schedule`; no CLI verb sets a free label.
- Failure scenario: remote host in UTC, Mac in PST, job scheduled "every day at 9am" (typed by the user or by the agent). Scarf shows "every day at 9am" with no "(host time)" / zone suffix, and the raw sub-line "0 9 * * *" also omits it; the job fires at 2 AM Mac time. The same job written as `0 9 * * *` does get the note.
- Suggested fix: decide `namesTimeOfDay` from `schedule.expression` when `kind == "cron"`, regardless of what `display` holds.

### S08-cron-F3 · P3 · SOURCE · NEW
- Claim: Run Now never refreshes the doctor findings or incident badges, so after a manual run the row keeps the pre-run health state until the user presses Reload (or the job roster changes).
- Scarf: `scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift:917-958` (`runNow` calls only `load(force: true)`); `load` re-runs doctor only when the id roster changed (`:210-230`). Every other mutation goes through `runAndReload` → `refreshDiagnosticsAfterMutation()` (`:1360`), whose own doc comment (`:1300-1305`) cites the `cron run` "Ran now: failed." case as its reason to exist.
- Hermes @v2026.9.24: a failed run records `last_status="error"`/`last_error` (`cron/jobs.py:2303-2305`) which `cron doctor` reports (`hermes_cli/cron.py:614-616`) and opens a durable incident (`cron/incidents.py`); a successful run clears `last_error` (`cron/jobs.py:2305`) so doctor's "last run failed" issue disappears.
- Failure scenario: a job flagged by doctor "last run failed: …" — the user fixes the cause and presses Run Now; the bar says "Run finished", but the row's doctor warning (and open-incident badge) stays. Conversely a Run Now that fails shows no new incident badge until Reload.
- Suggested fix: call `refreshDiagnosticsAfterMutation()` in `runNow`'s MainActor completion (and after the follow-up tick).

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `~/.hermes/cron/jobs.json` `{"jobs":[…],"updated_at"}` / bare list / id-keyed map | file read | HermesFileService.swift:370-382; HermesCronJob.swift:1519-1612 | cron/jobs.py:1335-1380 | OK |
| job fields id,name,prompt,skills/skill,model,schedule,enabled,state,deliver,next_run_at,last_run_at,last_error,script,last_delivery_error,workdir,context_from,no_agent,attach_to_session (+`extra` passthrough) | JSON shape | HermesCronJob.swift:108-245 | cron/jobs.py:1809-1851 | OK |
| schedule `{kind: cron/interval/once, expr, minutes, run_at, display}` | JSON shape | HermesCronJob.swift:1401-1484 | cron/jobs.py:756-834 | OK |
| effective state / pause marker (`paused_at`) | derived | HermesCronJob.swift:703-752 | cron/jobs.py:527-540, 515-518 | OK |
| failure_deliver, last_dispatch, last_delivery_unverified, monitor_*, repeat (via extra) | JSON read | HermesCronJob.swift:955-1245 | cron/jobs.py:1809-1851 | OK |
| `cron/output/<id>/<ts>.md` latest | file read | HermesFileService.swift:396-414 | cron/jobs.py:3282-3292; cron/monitor.py:30,62 | FINDING-F1 |
| `hermes cron create [--name= --deliver= --failure-deliver= --repeat= --skill=… --script= --workdir= --no-agent --pin] -- <schedule> [<prompt>]` | argv | CronViewModel.swift:1052-1084 | subcommands/cron.py:23-89; cron.py:698-722 | OK |
| `Created job: <id>` (pin follow-up) | output parse | CronViewModel.swift:115-124 | hermes_cli/cron.py:712 | OK |
| `hermes cron edit [--schedule= --prompt= --name= --deliver= --failure-deliver= --repeat= --clear-skills/--add-skill=/--remove-skill= --script= --workdir= --no-agent/--agent --pin/--unpin] -- <id>` | argv | CronViewModel.swift:1235-1264 | subcommands/cron.py:91-146; cron.py:725-763; tools/cronjob_tools.py:728-848 | OK |
| `hermes cron pause <id>` | argv | CronViewModel.swift:490; IOSCronViewModel.swift:434-441 | subcommands/cron.py:149-150; cron.py:766-794 | OK |
| `hermes cron resume <id>` / `resume <id> --run-now` | argv | CronViewModel.swift:559,579; IOSCronViewModel.swift:290 | subcommands/cron.py:152-155; cron.py:812-832 | OK |
| `hermes cron remove <id>` | argv | CronViewModel.swift:960; OAuthKeepaliveCronService.swift:124 | subcommands/cron.py:161-163 | OK |
| `hermes cron run <id>` + verdict markers (`Triggered job:`, `Failed to run job:`, `Ran now: succeeded./failed.`, skip sentences) | argv + exit-0 parse | CronViewModel.swift:917-958, 670-829; HermesCLIOutcome.swift:696-732 | cron.py:766-809; tools/cronjob_tools.py:185-199, 670-719 | OK |
| `hermes cron tick` (pre-v0.18 hosts only) | argv | CronViewModel.swift:946 | subcommands/cron.py:195; cron.py:289-307 | OK |
| `hermes cron runs <id> --limit 20` + row grammar | argv + parse | HermesCronRunsParser.swift; CronViewModel.swift:293 | subcommands/cron.py:168-171; cron.py:310-322 | OK |
| `hermes cron incidents` / `incidents ack <id>` (exit-0 miss) | argv + parse | HermesCronIncidentsParser.swift; CronViewModel.swift:337-399 | subcommands/cron.py:174-181; cron.py:329-372 | OK |
| `hermes cron doctor` (exit 1 = findings; header/bullet/closing hint) | argv + parse | HermesCronDoctorParser.swift; CronViewModel.swift:443-487 | subcommands/cron.py:193; cron.py:611-667 | OK |
| Refusal texts (`Cannot activate terminal cron job`, `Cannot re-arm recurring jobs`, `Blocked:`, past one-shot) | output parse | CronViewModel.swift:731-786 | cron/jobs.py (terminal/rearm guards); cron.py:710-711 | OK |
| `.env` `HERMES_TIMEZONE`, config `timezone` | config read | CronScheduleFormatter.swift:88-105; CronViewModel.swift:180-189 | hermes_time.py:83-106 | OK |
| Schedule phrase + zone note | display | CronScheduleFormatter.swift:30-139 | cron/jobs.py:772-834; :1023 | FINDING-F2 |
| Next-run ISO parse (`isoformat()` with/without µs) | display | CronScheduleFormatter.swift:175-221 | cron/jobs.py (`_hermes_now().isoformat()`) | OK (verified µs + offset parse) |
| Post-Run-Now diagnostics refresh | UI state | CronViewModel.swift:917-958 | — | FINDING-F3 |
| OAuth keep-alive `cron create --name "[scarf:oauth-keepalive] …" "0 4 * * *" "<prompt>"` | argv | OAuthKeepaliveCronService.swift:98-113 | subcommands/cron.py:23-28 | OK |
| iOS jobs.json guarded whole-file rewrite (delete/upsert/toggle fallback) | file write | IOSCronViewModel.swift:541-611 | cron/jobs.py:1491-1534 (merge-on-save) | TRACKED (.memory/decisions/absent-vs-unreadable-is-the-discriminator-every-scarf-json.md; hermes-v0-21-1-compatibility-decisions.md) |
| iOS interval-minutes field missing | UI | CronListView.swift | — | TRACKED (t-b74c65a4) |
| Repeat field "forever"/"once" | argv | CronViewModel.swift:1071 | cron/jobs.py normalize_repeat_value | TRACKED (t-63ffcac4) |
| Project cron status widget state badge/last error | display | CronStatusWidgetView.swift:120-140 | cron/jobs.py:2303-2306 | OK (output tail: FINDING-F1) |

## Not audited / couldn't verify
- Live behaviour of `--` end-of-options through Hermes's nested argparse subparsers was not executed (mutating verbs are off-limits); relied on the documented convention in `.memory/decisions/section-audit-remediation-2026-09.md:29` and argparse semantics.
- Whether a cron-fired agent run actually refreshes the OAuth refresh token (keep-alive premise) was not traced through `hermes_cli/runtime_provider.py`; keep-alive also only fires while a gateway/scheduler is running, which the Credential Pools copy doesn't mention (not a Hermes-contract defect).
- `CronView`/`CronStatusWidgetView` treat `state == "running"` as a live-run indicator, but Hermes at the tag never writes `running` (only scheduled/paused/completed/error) — dead branch, no false information shown; not reported.
- Remote-transport specifics (HERMES_HOME per profile, SSH timeout/kill of a 1800 s Run Now) belong to S15 and were taken as given.
