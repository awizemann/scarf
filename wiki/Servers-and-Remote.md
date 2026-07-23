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

**File → Open Server… → Add Server.** Fill in:

| Field | Required? | Notes |
|---|---|---|
| Hostname or alias | yes | Resolved via your `~/.ssh/config`. Use whatever you'd type after `ssh`. |
| User | optional | Defaults to your local username if absent. |
| Port | optional | Defaults to 22 (or whatever `~/.ssh/config` provides). |
| Identity file | optional | Specific private key. Otherwise, ssh-agent's loaded keys are tried in order. |
| Remote home | optional | Override `$HOME` if Hermes lives outside the SSH user's home. |
| Hermes binary hint | optional | E.g. `/usr/local/bin/hermes` if not on the SSH user's `PATH`. |

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

## Diagnostics

If the connection pill is green but the Dashboard shows "Stopped", "unknown", or empty values, the SSH user can't read the Hermes state files.

**The pill itself diagnoses common cases inline** _(v2.5.1+)._ Clicking the yellow "Can't read Hermes state" pill opens a popover with:

- The specific reason (`Hermes hasn't been run yet`, `permission denied on state.db`, `~/.hermes` doesn't exist, `Hermes profile <name> is active`, etc.)
- An actionable hint paragraph (`run any hermes session on the remote to create state.db`, `chmod a+r ~/.hermes/state.db`, etc.)
- A Run Diagnostics button (opens the heavy 14-check sheet) and a Retry button

For the "profile is active" case the popover includes a copy-paste `hermes profile use default` command. See [Projects & Profiles](Projects-and-Profiles) for the full Hermes v0.11 profile model.

**Pill probes `state.db`, not `config.yaml`** _(v2.5.2+)._ The tier-2 readability check now targets `~/.hermes/state.db` because that's the file Scarf actively reads on every Dashboard / Sessions / Chat tick. Hermes v0.11+ doesn't materialize `config.yaml` until the user explicitly changes a setting — a freshly-installed working Hermes would otherwise be marked "degraded — config missing" indefinitely. `state.db` is created on the first agent run and is the actual surface Scarf depends on. The Manage Servers → Run Diagnostics sheet treats `config.yaml` checks the same way: present-and-readable PASS, exists-but-unreadable FAIL, and missing-entirely SKIP (informational, doesn't drag the score).

## Project-shadowed Hermes home _(v2.5.2+)_

Hermes' CLI uses the closest `.hermes/` directory as `$HERMES_HOME` when invoked from inside a directory that has one. If a registered Scarf project carries its own `<project>/.hermes/` (commonly because it was seeded from another machine, checked into git, or because Hermes' first-run setup happened with that directory as `cwd`), every `hermes` invocation from inside that project silently binds to the project-local home — credentials, config, sessions, skills, and memories all land there instead of `~/.hermes/`.

Symptoms users hit:

- They run `hermes auth add nous` during setup; Scarf's Credential Pools view never sees Nous and the Chat tab keeps showing "No AI provider credentials detected."
- New chats started outside that project don't have access to credentials the user thought they registered.
- Dashboard stats, Sessions, and Activity reflect only the global `state.db` while the agent's actual work is being persisted into the project-local one.

The Mac Dashboard surfaces a yellow banner ("Project-local Hermes home shadowing global setup") listing every affected project with `auth.json present` / `state.db present` chips. Each row has a **Copy fix command** button that emits a one-liner like `cp <project>/.hermes/auth.json ~/.hermes/auth.json && chmod 600 ~/.hermes/auth.json` for the user to run on the remote — Scarf doesn't auto-migrate because picking which project-local files to keep vs. discard requires user judgement (e.g. an in-flight session might be worth importing rather than abandoning). Once auth.json is consolidated, the next probe tick clears the banner and the credential pool / chat surfaces pick up the provider.

**Manage Servers → 🩺 Run Diagnostics** runs **fourteen** checks in one SSH session: connectivity, `sqlite3` presence, read access to `config.yaml` and `state.db`, the effective non-login `$PATH`, etc. Each failure explains itself with a remediation hint. **Copy Full Report** dumps the whole output for bug reports.

**Tri-state probes (v2.5.2+).** Hermes v0.11+ doesn't materialize `config.yaml` until the user changes a setting from defaults — so the diagnostics view was reporting *"12/14 passing"* on healthy fresh installs and confusing users into thinking something was wrong. Probes now distinguish `.pass` / `.fail` / `.skipped`; a missing `config.yaml` emits `SKIP` (Hermes lazy-creates it; only "exists but unreadable" still fails). The summary reads *"12/12 passing (2 optional skipped)"* and the probe titles say *"config.yaml readable (optional)"* so the file's optional nature is obvious at a glance. The pill's tier-2 probe checks `state.db` instead of `config.yaml` for the same reason.

**Pill probe and diagnostics now use the same plumbing** _(v2.5.1+)._ Both go through the shared [`SSHScriptRunner`](Core-Services) (raw `/usr/bin/ssh ... -- /bin/sh -s`, script piped via stdin) instead of the prior split where the pill went through `runProcess`'s argument quoting and the diagnostics view used a local workaround. They no longer disagree about what the remote sees — issue [#44](https://github.com/awizemann/scarf/issues/44).

## Project-shadowed Hermes detection _(v2.5.2+)_

A new `ProjectHermesShadowDetector` in ScarfCore probes each registered project at chat-start for project-local Hermes config (`.hermes/` dir or `hermes.yaml` file) that would shadow the server-level config. When found, the chat surfaces a banner explaining the shadow — a quiet failure mode pre-fix where users didn't realize Hermes prefers project-local config and were debugging server-level changes that weren't actually being used.

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
_Last updated: 2026-04-29 — Scarf v2.5.2 (tri-state diagnostics + project-shadowed Hermes detection)_