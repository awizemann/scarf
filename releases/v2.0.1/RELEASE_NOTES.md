## What's New in 2.0.1

Hotfix for [#19](https://github.com/awizemann/scarf/issues/19) and the related reports from the first day of v2.0: users' remote SSH connections would show a green "Connected" pill but every view (Dashboard, Sessions, Activity, Chat) read as empty / "not running" / "not configured". Three distinct environments reported it — Docker Hermes on a LAN, homelab VM over Tailscale, Ubuntu VPS — and every one was a silent file-access failure on the remote that Scarf wasn't surfacing.

### Errors no longer disappear

Every remote read (`config.yaml`, `gateway_state.json`, `state.db`, `pgrep`) used to silently substitute an empty value on *any* failure — permission denied, missing file, `sqlite3` not installed, connection drop — they all looked identical to the UI. Now:

- Each failure logs a specific warning via `os.Logger` (visible in Console.app under subsystem `com.scarf`).
- The Dashboard shows an orange banner above the stats with the exact error (e.g. "Permission denied reading `~/.hermes/state.db`") and a **Run Diagnostics…** button.
- `HermesDataService` exposes a `lastOpenError` so views can explain *why* state.db couldn't be opened, rather than just rendering zeros.
- Routine "file doesn't exist" cases (optional `skill.yaml` metadata, `gateway_state.json` before Hermes starts, `memories/USER.md` on fresh installs) are detected and **not** logged as warnings — only real errors (permission denied, connection drops, `sqlite3` missing) hit the log. Prevents Console from filling with false-positive noise when directory walks encounter optional files.

### New Remote Diagnostics sheet

Accessible from **Manage Servers → 🩺** per-server button, or by clicking the orange connection pill when Scarf can see the server but can't read Hermes state. Runs fourteen checks in a single SSH session and shows pass/fail for each, plus a targeted hint per failure:

- SSH connectivity and auth
- Remote user identity and `$HOME` resolution
- `~/.hermes` directory existence and readability
- `config.yaml` readable (existence *and* actual read access — the old probe only checked existence)
- `state.db` readable
- `sqlite3` installed on the remote (required for the atomic snapshot Scarf pulls)
- `sqlite3` can actually open `state.db`
- `hermes` binary on the non-login `$PATH` (what runtime uses)
- `hermes` binary on the login `$PATH` (what the Test Connection probe uses)
- `pgrep` available (for the "is Hermes running" check)

One **Copy Full Report** button dumps every check as plain text for bug reports, and a raw-output disclosure panel shows the exact stdout/stderr the remote returned whenever any probe fails — so transport-level problems are self-diagnosing.

The diagnostics script is piped to `/bin/sh -s` on stdin rather than passed as `sh -c <script>` argv. The latter was getting split line-by-line by the remote's login shell (newlines parsed as command separators), which stranded variables set on line 1 in an ephemeral `sh` subprocess that exited before line 2 could use them. Stdin-piping runs the whole script in one `sh` process with variable scope preserved.

### Connection pill gains a "degraded" state

The pill used to be green as long as SSH connected; now after connectivity passes it runs a second-tier check (`test -r $HOME/.hermes/config.yaml`). If that fails, the pill turns **orange** with "Connected — can't read Hermes state" and clicking it opens Remote Diagnostics directly. This is the exact symptom mode in #19, and it's now one click away from a specific answer.

The pill's visual also got a pass: the colored dot is replaced with a state-specific SF Symbol (`checkmark.circle.fill` / `stethoscope` / `arrow.triangle.2.circlepath` / `exclamationmark.triangle.fill`), which reads more like a clickable toolbar tool and doubles as the status signal. No custom pill background anymore — the toolbar's native `.principal` bezel is the frame.

### Auto-suggest the correct `remoteHome` during Add Server

When Test Connection can't find `state.db` at the configured (or default) path, it now also probes the common alternate locations — `/var/lib/hermes/.hermes`, `/opt/hermes/.hermes`, `/home/hermes/.hermes`, `/root/.hermes` — and offers a one-click "Use this" fill if it finds one. Removes the need to know that systemd-installed Hermes lives at `/var/lib/hermes/.hermes` by convention.

### Clearer copy for the `remoteHome` field

The Add Server sheet field is now labeled "Hermes data directory" with a description explaining when you'd override it (systemd service installs, Docker sidecars) and noting that Test Connection auto-suggests.

### README has a new "Remote setup requirements" section

Four concrete prerequisites (SSH, `sqlite3`, `pgrep`, read access to `~/.hermes`) and a troubleshooting paragraph pointing at Remote Diagnostics.

### Migrating from 2.0.0

Sparkle will offer the update automatically. Settings and server list are preserved verbatim — this is purely additive (new diagnostics surface, new error banners, auto-suggest in Test Connection). If you were affected by #19, run Remote Diagnostics after updating; the sheet should pinpoint the specific file access issue and suggest a fix.

### Under the hood

- New types: `RemoteDiagnosticsViewModel`, `RemoteDiagnosticsView`. Both are local to Scarf; no new transport protocol.
- `HermesFileService` gains `loadConfigResult()`, `loadGatewayStateResult()`, `hermesPIDResult()`, `readFileResult()`, `readFileDataResult()` — Result-returning variants that preserve the error. Legacy `loadConfig()` etc. still exist as thin forwarders for callers that don't need diagnostics.
- `HermesDataService.open()` records `lastOpenError` with humanized hints for "sqlite3 not installed", "permission denied", and "file not found" — the three failure modes that produce 90% of issue #19 symptoms.
- `ConnectionStatusViewModel` status enum gains `.degraded(reason:)` between `.connected` and `.error`.
- `TestConnectionProbe` result enum gains `suggestedRemoteHome: String?` carrying any alternate-location hit.

### Known follow-ups (not in 2.0.1)

- `TestConnectionProbe` uses a direct-argv ssh invocation that's functionally correct but fragile (works by accident when split across the login shell). Should be ported to the stdin-pipe pattern the diagnostics sheet now uses.
- Remaining `try?`-swallowed read paths beyond the four Dashboard-surfacing ones — Cron, Memory, Skills, MCP Servers, Platforms still silently render empty on read errors. Same fix pattern applies, low priority.
- `hermesBinaryHint` is only populated when the user clicks Test Connection; if they skip it, ACP chat and CLI calls fall back to bare `hermes` which requires it on the non-interactive PATH (rarely true for `~/.local/bin` installs). The connection-pill's second-tier probe could auto-populate this.
- Docker-host support: when users SSH to a Docker host, `pgrep` and `~/.hermes/` on the host don't see what's inside the container. Needs a `docker exec` wrapping option per server.
