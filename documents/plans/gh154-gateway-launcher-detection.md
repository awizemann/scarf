# gh#154 — "Hermes: Stopped" for a running v0.23 gateway

## Session goal
A v0.23+ gateway started by Hermes's own launchers (systemd, launchd, Docker, foreground `hermes gateway run`) is detected as running, for the right profile, with Stop/Restart enabled — and nothing that is not that profile's gateway is ever detected (it can be SIGTERM'd). Older Hermes behaves exactly as before.

## Verdict: valid (checked against tagged source, unchanged at v0.23.4)
- Services start the gateway via `installation_command` (`hermes_cli/_launchers.py:87-99` @ v0.23.0): the published `bin/hermes` launcher, or `runtime_command` (`:39-72`) when there's no store Python.
- `bin/hermes` = `#!/bin/sh` + `exec <python> -I -c '<source>' "$@"` (`_write_shell` `:520`, `_mint_shell_launcher` `:536`). `exec` replaces the shell, so the live process is `python -I -c <source> [-p name] gateway run`.
- Bundled/Docker `bin/hermes` (`scripts/build/launchers.py:25-75`): `exec "$PYTHON" -P -c 'import os, site, sys; … from hermes_cli.main import main; sys.exit(main())' "$@"`. Not in the report.
- Scarf's `plainArgs` refuses `-c` (and `-P`), so none match. Hermes's own recognizer: `gateway/status_inline_source.py:79-111` (`_BOOTSTRAPS`).

## Blast radius (every consumer of the matcher)
| Consumer | Effect of a match | Risk if over-matching |
|---|---|---|
| `HermesFileService.hermesPIDResult` → Dashboard HERMES card (`DashboardViewModel.swift:147`), menu bar (`scarfApp.swift:851`), `isHermesRunning` | Shows Running + PID, enables Stop/Restart | Wrong "Running" |
| `configDerivedMultiplexServes` (`HermesFileService.swift:234`) | Root gateway liveness → which profiles show as multiplexer-served | Wrong "served" badge |
| `stopHermes` fallback (`HermesFileService.swift:3308`) | **SIGTERMs the PID** when `hermes gateway stop` fails | Kills the wrong process — the one real hazard |
| `pidFromProfilePidFile` (`:3210`) via `commandLineIsGateway` | Named-profile fallback via `ps -o command=` | same as above |

Not affected: Bot Chat / MCP login / dashboard `pkill` patterns (separate code), GATEWAY card (reads `gateway_state.json`).

## Changes
1. **Matcher** (`ScarfCore/Services/HermesGatewayProcessMatch.swift`): add `-c` launcher forms, each pinned by the launcher's first statement and `hermes_cli.main` entry, then the existing `<profile flag><gateway run><end>` tail; include flag-after-subcommand for named profiles. Allow `-P` among argument-less Python switches. Avoid literal `'` in the pattern (use `.`) for quoting safety. Update the doc comment with v0.23.0 citations.
2. **`ps` width** (`HermesFileService.swift:3214`): `ps -o command=` → `ps -ww -o command=`. The launcher source is several KB; without `-ww`, procps may cut the line before `gateway run`, so the named-profile fallback would still fail. Both BSD and procps accept `-ww`.

Agreed with reporter's proposal, plus: Docker launcher, `-P`, and `ps -ww`. Rejected: nothing.

## Potential issues
- Newlines inside the source: POSIX `.` (no REG_NEWLINE) matches newlines, so pgrep's raw cmdline works. `ps` may print them as `?`; the pattern must use `.*` across them, not literal `\n`.
- Carrier processes (a watcher whose args contain a launcher command line): refused because the match is anchored to the **first** `-c` program's own first statement.
- Same launcher running other entry points (`hermes-acp`, `--run-module X`): refused by pinning `hermes_cli.main` and requiring `gateway run` right after the source.
- The probing shell over SSH (`bash -c "pgrep -f '…'"`): its `-c` text starts with `pgrep`, not a launcher statement → no self-match. Add a test.
- No capability flag (C1): widening only; every pre-existing fixture must keep its result.

## Tasks (Memophant)
- T1 Matcher + unit tests (builder subagent)
- T2 `ps -ww` in the pid-file fallback (same builder; one-line)
- T3 Real test: local v0.23.4 + remote Linux systemd, default + named profile
- T4 Fresh-eyes audit (scope: did the change fix #154 soundly, no regressions)
- T5 Commit, memory note, reply on #154, cleanup

## Out of scope
Reading `argv` from `gateway.pid`, refactoring the matcher, other `pkill` patterns.
