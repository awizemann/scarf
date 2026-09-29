# S08-cron — verdict: WORKS

Hermes paths are relative to ~/.hermes/hermes-agent-v0215 (v2026.9.24). Scarf paths are relative to /Users/awizemann/Developer/Scarf/scarf.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | List jobs: reads `cron/jobs.json` directly ({"jobs":[...]}), with a tolerant decode and a warning banner when decoding fails | WORKS | – |
| 2 | Create job (Mac): `cron create [--name= --deliver= --failure-deliver= --repeat= --skill=… --script= --workdir= --no-agent --pin] -- <schedule> [prompt]` | WORKS | – |
| 3 | Edit job (Mac): `cron edit [--schedule= --prompt= … --add-skill/--remove-skill/--clear-skills --agent/--no-agent --pin/--unpin] -- <id>` | WORKS | – |
| 4 | Pause / Resume / Resume & Run Now / Delete (`cron pause|resume [--run-now]|remove <id>`) | WORKS | – |
| 5 | Run Now (`cron run <id>`): exit 0 with "Ran now: failed.", and the skip sentences on exit 0 | WORKS | – |
| 6 | Last run output: `cron/output/<id>/<YYYY-MM-DD_HH-MM-SS>.md`, newest file | WORKS | – |
| 7 | Run history (`cron runs <id> --limit 20`), incidents list/ack, doctor (exit 1 when it finds issues) | WORKS | – |
| 8 | Schedule display + time-zone note (HERMES_TIMEZONE in .env, then config `timezone`) | WORKS | – |
| 9 | OAuth keep-alive toggle (create/remove a named job) | WORKS | – |
| 10 | Project cron status widget (by job id) + project attribution tags | WORKS | – |
| 11 | iOS cron: pause/resume/re-arm through the CLI; edit/create/delete write jobs.json under a guarded compare-and-swap | WORKS (known gap tracked) | TRACKED t-b74c65a4 (no interval-minutes field in the iOS editor) |

## Findings
None new.

Verified against Hermes:
- **Mutation exit codes.** `cmd_cron` forwards the return code (hermes_cli/main.py:1925, `forward_return=True`). Every refusal returns 1 (hermes_cli/cron.py:711,733,736,756,787,818,826,829). Scarf also keeps the `Failed to … job:` prefix check for exit-0 refusals (Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift:2263-2282, used by CronViewModel.swift:1345 and IOSCronViewModel.swift:504).
- **Run Now.** `_job_action` prints `Triggered job:` and then the `_run_outcome` line, and still exits 0 (hermes_cli/cron.py:789-809). Scarf lets the failure marker win over the success marker for "Ran now: failed.". The paused, missing and already-firing skip sentences match tools/cronjob_tools.py:194-198 and :716-717. A timeout (exit -1 at 1800 s) is shown as "unconfirmed", not as success.
- **Resume & Run Now.** `resume --run-now` exists (hermes_cli/subcommands/cron.py:155; confirmed LIVE with `hermes cron resume --help`), and `--at` and `--run-now` are mutually exclusive. `rearm_oneshot` works on one-shot jobs only; Scarf offers the button only when `offer.canRearm` is true.
- **Doctor.** `cron_doctor` returns 1 when it has findings (hermes_cli/cron.py:667). Scarf judges the run by the output sentinel, not the exit code (CronViewModel.swift:462-466). Both closing-hint spellings are recognised (HermesCronDoctorParser isChrome), and the header/bullet layout matches hermes_cli/cron.py:659-666.
- **Incidents.** The block format, banner and footer match hermes_cli/cron.py:356-372 and :152-158. The `--state` choices match subcommands/cron.py:176 (confirmed LIVE). An ack for an incident that is not found exits 0 with "not found or already closed", and Scarf maps that to an honest message (CronViewModel.swift:379-385).
- **Runs.** The row format matches hermes_cli/cron.py:318-324 (id, status, job=, source=, claimed_at, plus an indented error line).
- **Output files.** Hermes writes them in cron/jobs.py:3287 (`%Y-%m-%d_%H-%M-%S.md`). Lexical sorting equals time order, and Scarf filters on `.md` so the monitor snapshot is excluded.
- **ISO parsing.** Interval next_run_at values carry microseconds (cron/jobs.py:1178-1179). A live Swift probe confirmed that ISO8601DateFormatter with `.withFractionalSeconds` parses 6-digit fractions.
- **Time-zone note.** Timezone resolution uses HERMES_TIMEZONE from .env first, then config `timezone`. Wall-clock cron fires in the configured zone (cron/jobs.py:1200-1214), so the note is accurate.

## File coverage (mandatory — one row per manifest line, none skipped)
| File | Hermes touchpoints? | Status |
|---|---|---|
| Packages/ScarfCore/Sources/ScarfCore/Models/CronRecoveryOffer.swift | yes (models resume/rearm refusals) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Models/CronScheduleArgument.swift | yes (schedule argv value for fleet apply) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Models/CronScheduleFormatter.swift | yes (schedule shape, HERMES_TIMEZONE/config timezone) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Models/HermesCronJob.swift | yes (jobs.json schema, effective_job_state port) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesCronDoctorParser.swift | yes (`cron doctor`) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesCronIncidentsParser.swift | yes (`cron incidents [ack]`) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesCronRunsParser.swift | yes (`cron runs`) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Services/ProjectCronAttribution.swift | no (Scarf-owned name tags) | NO-TOUCHPOINT |
| Packages/ScarfCore/Sources/ScarfCore/ViewModels/IOSCronViewModel.swift | yes (pause/resume/--run-now CLI; jobs.json CAS write) | OK / TRACKED (t-b74c65a4 via editor) |
| Scarf iOS/Cron/CronListView.swift | yes (builds the jobs.json record) | TRACKED (t-b74c65a4) |
| scarf/Core/Services/OAuthKeepaliveCronService.swift | yes (`cron create`/`cron remove`) | OK |
| scarf/Features/Cron/ViewModels/CronViewModel.swift | yes (all cron verbs) | OK |
| scarf/Features/Cron/Views/CronView.swift | yes (capability gating, deliver hints) | OK |
| scarf/Features/Projects/Views/Widgets/CronStatusWidgetView.swift | yes (jobs.json + output read) | OK |
| scarf/Core/Services/HermesFileService.swift lines 361-415 (Cron) | yes (jobs.json, cron/output) | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `<home>/cron/jobs.json` read | file | HermesFileService.swift:370-384 | cron/jobs.py:74,1355-1373,1478 | OK |
| `<home>/cron/output/<id>/*.md` | file | HermesFileService.swift:396-414 | cron/jobs.py:3281-3292 | OK |
| `cron create … -- sched [prompt]` | argv | CronViewModel.swift:1097-1140 | subcommands/cron.py:23-89; cron.py:698-722 | OK |
| `cron edit … -- id` | argv | CronViewModel.swift:1264-1300 | subcommands/cron.py:91-147; cron.py:725-763 | OK |
| `cron pause/resume/remove <id>` | argv | CronViewModel.swift:492,585,986 | cron.py:766-794,812-832 | OK |
| `cron resume <id> --run-now` | argv | CronViewModel.swift:604; IOSCronViewModel.swift:285 | subcommands/cron.py:155; cron.py:812-832 | OK (LIVE) |
| `cron run <id>` | argv | CronViewModel.swift:946 | cron.py:766-809; tools/cronjob_tools.py:185-199,716 | OK |
| `cron tick` (pre-v0.18 only) | argv | CronViewModel.swift:973 | cron.py:289-307 | OK |
| `cron runs <id> --limit N` | argv | HermesCronRunsParser.swift:args | cron.py:310-324 | OK |
| `cron incidents` / `ack <id>` | argv | HermesCronIncidentsParser.swift listArgs/ackArgs | subcommands/cron.py:174-181; cron.py:329-372 | OK (LIVE) |
| `cron doctor` | argv | HermesCronDoctorParser.swift args | cron.py:648-667 | OK |
| keep-alive `cron create --name … "0 4 * * *" prompt` / `cron remove` | argv | OAuthKeepaliveCronService.swift | cron.py:698-722 | OK |
| HERMES_TIMEZONE (.env), `timezone` (config.yaml) | config read | CronScheduleFormatter.configuredZone; CronViewModel.swift load | cron/jobs.py:1200 (get_timezone) | OK |
| iOS jobs.json write (edit/create/delete) | file write | IOSCronViewModel.swift:580-637 | cron/jobs.py load/normalize | OK by design / TRACKED t-b74c65a4 (interval) |

## Not audited / couldn't verify
- Profile HERMES_HOME resolution and SSH quoting inside `runHermesCLI`/`context.paths.home` belong to S15. This audit assumes them correct.
- No verbs were executed (read-only rule). Output formats were verified from source, plus the `--help` probes noted above.
