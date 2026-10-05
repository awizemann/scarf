---
title: Servers-and-Remote
type: note
permalink: scarf-wiki/servers-and-remote
created: 2026-05-29
updated: 2026-05-29
---

# Servers & Remote

> **Adding a server on iOS?** ScarfGo's Servers list works the same idea but with on-device key generation. See [ScarfGo Onboarding](ScarfGo-Onboarding) for the iPhone walkthrough. The rest of this page is the macOS Mac-app flow.

Scarf 2.0 is multi-server. Each Mac window binds to one Hermes install — your local `~/.hermes/` (synthesized automatically) or any number of remote SSH hosts. Server state lives in `~/Library/Preferences/com.scarf.app.plist` via the `ServerRegistry`. ScarfGo (iOS) uses a single-window TabView; switching servers from its Servers list rebuilds the tab root against the new context.

## Adding a remote server

**File → Open Server → Manage Servers… → Add.** Fill in:

| Field | Required? | Notes |
|---|---|---|
| Hostname or alias | yes | Resolved via your `~/.ssh/config`. Use whatever you'd type after `ssh`. |
| User | optional | Defaults to your local username if absent. |
| Port | optional | Defaults to 22 (or whatever `~/.ssh/config` provides). |
| Identity file | optional | Specific private key. Otherwise, ssh-agent's loaded keys are tried in order. |
| Remote home | optional | Override `$HOME` if Hermes lives outside the SSH user's home. |
| Hermes binary hint | optional | E.g. `/usr/local/bin/hermes` if not on the SSH user's `PATH`. Usually unnecessary: every remote command also looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.hermes/bin` (after the shell's own `PATH`). A wrapper such as `docker compose exec hermes hermes` runs as typed; quote a single path that contains spaces. Leave it blank and **Test Connection** fills in the path it finds, which is always used as one path, spaces and all. |

**Test Connection** runs a fast probe before saving. If `state.db` isn't found at `~/.hermes/`, it tries `/var/lib/hermes/.hermes`, `/opt/hermes/.hermes`, `/home/hermes/.hermes`, and `/root/.hermes` (common systemd / Docker layouts) and offers a one-click fill if it finds any.

## Remote prerequisites

The remote host must have:

1. **SSH access** — key-based auth via your local ssh-agent. Scarf never prompts for passphrases; run `ssh-add` once in Terminal before connecting.
2. **`sqlite3`** on the remote `$PATH` — needed for the atomic DB snapshots. Install with `apt install sqlite3` (Ubuntu/Debian), `yum install sqlite` (RHEL/Fedora), or `apk add sqlite` (Alpine).
3. **`pgrep`** on the remote `$PATH` — used by the Dashboard's "is Hermes running" check. Standard on every distro; install `procps` if missing.
4. **`~/.hermes/` readable by the SSH user.** When Hermes runs as a separate user (systemd service, Docker container), the SSH user needs read access to `config.yaml` and `state.db`. Either (a) SSH as the Hermes user, (b) `chmod` Hermes's home to be group-readable and add your SSH user to that group, or (c) set the **Hermes data directory** field when adding the server to point at the right location (e.g. `/var/lib/hermes/.hermes`).

## How remote works under the hood

- Every remote primitive goes through [`SSHTransport`](Transport-Layer), which multiplexes ssh / scp / sftp through one ControlMaster connection.
- `state.db` is read from atomic `sqlite3 .backup` snapshots cached at `~/Library/Caches/scarf/snapshots/<server-id>/state.db`.
- File watching uses 3-second mtime polling.
- Chat uses `ssh -T host -- hermes acp` with JSON-RPC over the tunnel; see [ACP Subprocess](ACP-Subprocess).

## Server backup and restore

**Manage Servers → Back Up…** writes a `.scarfbackup` (a zip) holding the server's Hermes home, every registered project, and a manifest with SHA-256s. No SQLite database is copied live and none is checkpointed (Scarf does not write Hermes's databases): every `*.db` in the home — `state.db`, each profile's `state.db`, `kanban.db`, `response_store.db`, `cron/executions.db`, … — is captured as a consistent snapshot by `sqlite3 -readonly` (`VACUUM INTO`, then `.backup`), a `query_only` connection that has proven it won't checkpoint on close, or `python3` (Linux), and stored in `hermes-databases.tar.gz`. If the root `state.db` can't be snapshotted the backup refuses; any other database that can't be is listed as not included when the backup finishes, as `hermes backup` reports it. Hermes's retired-WAL capture folders are left out, as `hermes backup` does. Archives are manifest schema 2; older Scarf builds refuse them rather than restoring without sessions. With **Include `auth.json`** off, every Hermes home in the archive — the root and each named profile under `profiles/<name>/` — leaves out `auth.json` and `auth.json.corrupt`; MCP OAuth tokens (`mcp-tokens/`) and `gateway_state.json` are always left out, root and profiles alike, and with logs off each profile's `logs/` is too. Everything `hermes backup` itself leaves out is left out too: the Hermes code checkout (`hermes-agent/`, with its venv), downloaded models, runtimes and Node, prior backups and state snapshots, checkpoints, dependency folders and caches (a home's `cache/` keeps only delivered media and citations), pid files, and both browser profile folders — which hold copies of browser cookies and logins, so they never ship. A backup of a Linux server with the gateway running no longer fails on GNU tar's "file changed as we read it".

**Restore from Backup…** writes into the server's configured Hermes data directory (not `$HOME/.hermes`). It refuses, before changing anything, while any process has one of the databases it would replace (or their `-wal`/`-shm`) open — Linux `/proc`, `lsof` elsewhere: stop the gateway and close Hermes chats, including Scarf chat windows for that server, first. The databases are published last, by rename, after a second check and after each old database's `-wal`/`-shm`/`-journal` is removed, mirroring `hermes import`. Cron jobs are paused as soon as the home is extracted — the root home's and every profile's own `cron/jobs.json` (Hermes keeps one store per profile), and the count shown is the total. A jobs file that can't be read or parsed doesn't stop the others being paused; the restore then fails naming it. Schema 1 archives still restore. An archive made by an older Scarf that still carries `hermes-agent/`, runtimes or browser profiles restores without them, so the target keeps its own installed Hermes. Scarf-named staging folders left by an interrupted backup or restore are cleaned up by the next run once they are a day old.

## Diagnostics

If the connection pill is green but the Dashboard shows "Stopped", "unknown", or empty values, the SSH user can't read the Hermes state files.

**The pill itself diagnoses common cases inline** _(v2.5.1+)._ Clicking the yellow "Can't read Hermes state" pill opens a popover with:

- The specific reason (`Hermes hasn't been run yet`, `permission denied on state.db`, `~/.hermes` doesn't exist, `Hermes profile <name> is active`, etc.)
- An actionable hint paragraph (`run any hermes session on the remote to create state.db`, `chmod a+r ~/.hermes/state.db`, etc.)
- A Run Diagnostics button (opens the heavy 14-check sheet) and a Retry button

For the "profile is active" case the popover includes a copy-paste `hermes profile use default` command. See [Projects & Profiles](Projects-and-Profiles) for the full Hermes v0.11 profile model.

**Pill probes `state.db`, not `config.yaml`** _(v2.5.2+)._ The tier-2 readability check now targets `~/.hermes/state.db` because that's the file Scarf actively reads on every Dashboard / Sessions / Chat tick. Hermes v0.11+ doesn't materialize `config.yaml` until the user explicitly changes a setting — a freshly-installed working Hermes would otherwise be marked "degraded — config missing" indefinitely. `state.db` is created on the first agent run and is the actual surface Scarf depends on. The Manage Servers → Run Diagnostics sheet treats `config.yaml` checks the same way: present-and-readable PASS, exists-but-unreadable FAIL, and missing-entirely SKIP (informational, doesn't drag the score).

## Project `.hermes/` folders are not a second Hermes home

Earlier Scarf versions (v2.5.2 – 3.4) showed a yellow Dashboard banner, "Project-local Hermes home shadowing global setup", for any registered project containing a `.hermes/` folder, with a **Copy fix command** that renamed the folder aside. That premise was wrong and the banner is gone. Hermes resolves its home as a context override, then `$HERMES_HOME`, then `~/.hermes` — it never picks up a `.hermes/` from the working directory (`hermes_constants.py` in Hermes 0.21.5). A project's `.hermes/` folder holds legitimate project features: project skills (`.hermes/skills/`, loaded when trusted), project plugins, and the verify manifest (`.hermes/environment.json`). If you ran the old fix command, move `<project>/.hermes.scarf-bak.<timestamp>/` back to `<project>/.hermes/` to restore them.

**Manage Servers → 🩺 Run Diagnostics** runs **fourteen** checks in one SSH session: connectivity, `sqlite3` presence, read access to `config.yaml` and `state.db`, the effective non-login `$PATH`, etc. Each failure explains itself with a remediation hint. **Copy Full Report** dumps the whole output for bug reports.

**Tri-state probes (v2.5.2+).** Hermes v0.11+ doesn't materialize `config.yaml` until the user changes a setting from defaults — so the diagnostics view was reporting *"12/14 passing"* on healthy fresh installs and confusing users into thinking something was wrong. Probes now distinguish `.pass` / `.fail` / `.skipped`; a missing `config.yaml` emits `SKIP` (Hermes lazy-creates it; only "exists but unreadable" still fails). The summary reads *"12/12 passing (2 optional skipped)"* and the probe titles say *"config.yaml readable (optional)"* so the file's optional nature is obvious at a glance. The pill's tier-2 probe checks `state.db` instead of `config.yaml` for the same reason.

**Login PATH without sourcing rc files, and the saved Hermes binary** _(v3.4.x, audit T6-F2/F4)._ Diagnostics used to source `~/.zshenv`, `.zprofile`, `.bash_profile` and `.profile` into `/bin/sh`; on Debian/Ubuntu (dash) one zsh-only line in them ended the script and the remaining checks showed as FAILED. It now borrows the login shell's PATH the way Test Connection does (`$SHELL -lc` prints it; nothing is sourced into sh). The two "hermes binary" checks look for the server's saved **Hermes binary** when there is one — a path Test Connection found is checked as one word, a typed command line such as `docker compose exec hermes hermes` by its first word — instead of always looking for `hermes`.

**File permission errors are not SSH errors** _(v3.4.x, audit T6-F3)._ A remote `cat`/`mv` that fails with `Permission denied` (for example a `0600` file owned by the Hermes user) is reported as the command's own error, not as "SSH authentication failed". Only ssh's own messages (exit 255, or its `Permission denied (publickey,…)` form) count as authentication failures.

**Pill probe and diagnostics now use the same plumbing** _(v2.5.1+)._ Both go through the shared [`SSHScriptRunner`](Core-Services) (raw `/usr/bin/ssh ... -- /bin/sh -s`, script piped via stdin) instead of the prior split where the pill went through `runProcess`'s argument quoting and the diagnostics view used a local workaround. They no longer disagree about what the remote sees — issue [#44](https://github.com/awizemann/scarf/issues/44).

## Adding a project on a remote server _(v2.5.1+)_

The Add Project sheet is now context-aware. On a local server it works as before — click **Browse...** to pick a directory with `NSOpenPanel`. On a remote server the Browse button is hidden (a Mac-local Finder dialog can't see the remote filesystem) and replaced with a **Verify** button that runs `transport.stat(path)` over SSH and renders a green ✓ if the path exists and is a directory, or a yellow ⚠ if it's missing / a file / unreadable. Edit the path field and the verification resets to idle so you don't see a stale ✓ for a path you've since changed.

A full SFTP-backed remote directory picker is on the roadmap (issue [#54](https://github.com/awizemann/scarf/issues/54)). Until then, type the absolute remote path (or paste from a remote shell), Verify, then Add.

## Switching the active window

- **⌘1** — local server window.
- **⌘2 … ⌘9** — your saved remote servers in order.
- **⌘⇧S** — open the Manage Servers sheet to add / remove / test connections.

See [Keyboard Shortcuts](Keyboard-Shortcuts).

## Related pages

- [Transport Layer](Transport-Layer) for the SSH internals (ControlMaster, snapshot mechanics).
- [ACP Subprocess](ACP-Subprocess) for chat over SSH.
- [Hermes Paths](Hermes-Paths) for what each remote file is.

---
_Last updated: 2026-04-29 — Scarf v2.5.2 (tri-state diagnostics; project-shadow banner removed in R12)_