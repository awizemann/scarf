## What's New in 2.0.1

Hotfix for [#19](https://github.com/awizemann/scarf/issues/19) and the related reports from the first day of v2.0: users' remote SSH connections would show a green "Connected" pill but every view (Dashboard, Sessions, Activity, Chat) read as empty / "not running" / "not configured". Three distinct environments reported it — Docker Hermes on a LAN, homelab VM over Tailscale, Ubuntu VPS — and every one was a silent file-access failure on the remote that Scarf wasn't surfacing.

### What changed

**Errors no longer disappear.** Every remote read (`config.yaml`, `gateway_state.json`, `state.db`, `pgrep`) used to silently substitute an empty value on *any* failure — permission denied, missing file, `sqlite3` not installed, connection drop — they all looked identical to the UI. Now:

- Each failure logs a specific warning via `os.Logger` (visible in Console.app under subsystem `com.scarf`).
- The Dashboard shows an orange banner above the stats with the exact error (e.g. "Permission denied reading `~/.hermes/state.db`") and a **Run Diagnostics…** button.
- `HermesDataService` exposes a `lastOpenError` so views can explain *why* state.db couldn't be opened, rather than just rendering zeros.

**New Remote Diagnostics sheet.** Accessible from **Manage Servers → 🩺** or directly by clicking the toolbar pill when it's yellow. Runs fourteen checks in a single SSH session and shows pass/fail for each, plus a targeted hint per failure:

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

One **Copy Full Report** button dumps every check as plain text for bug reports.

**Connection pill gains a yellow "degraded" state.** The pill used to be green as long as SSH connected; now after connectivity passes it runs a second-tier check (`test -r ~/.hermes/config.yaml`). If that fails, the pill turns **yellow** with "Connected — can't read Hermes state" and clicking it opens Remote Diagnostics directly. This is the exact symptom mode in issue #19, and it's now one click away from a specific answer.

**Auto-suggest the correct `remoteHome` during Add Server.** When Test Connection can't find `state.db` at the configured (or default) path, it now also probes the common alternate locations — `/var/lib/hermes/.hermes`, `/opt/hermes/.hermes`, `/home/hermes/.hermes`, `/root/.hermes` — and offers a one-click "Use this" fill if it finds one. Removes the need to know that systemd-installed Hermes lives at `/var/lib/hermes/.hermes` by convention.

**Clearer copy for the `remoteHome` field.** The Add Server sheet field is now labeled "Hermes data directory" with a description explaining when you'd override it (systemd service installs, Docker sidecars) and noting that Test Connection auto-suggests.

**README has a new "Remote setup requirements" section** with the four concrete prerequisites (SSH, `sqlite3`, `pgrep`, read access to `~/.hermes`) and a troubleshooting paragraph pointing at Remote Diagnostics.

### Migrating from 2.0.0

Sparkle will offer the update automatically. Settings and server list are preserved verbatim — this is purely additive (new diagnostics surface, new error banners, auto-suggest in Test Connection). If you were affected by #19, run Remote Diagnostics after updating; the sheet should pinpoint the specific file access issue and suggest a fix.

### Under the hood

- New types: `RemoteDiagnosticsViewModel`, `RemoteDiagnosticsView`. Both are local to Scarf; no new transport protocol.
- `HermesFileService` gains `loadConfigResult()`, `loadGatewayStateResult()`, `hermesPIDResult()`, `readFileResult()`, `readFileDataResult()` — Result-returning variants that preserve the error. Legacy `loadConfig()` etc. still exist as thin forwarders for callers that don't need diagnostics.
- `HermesDataService.open()` records `lastOpenError` with humanized hints for "sqlite3 not installed", "permission denied", and "file not found" — the three failure modes that produce 90% of issue #19 symptoms.
- `ConnectionStatusViewModel` status enum gains `.degraded(reason:)` between `.connected` and `.error`.
- `TestConnectionProbe` result enum gains `suggestedRemoteHome: String?` carrying any alternate-location hit.
