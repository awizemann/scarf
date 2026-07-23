---
title: Transport-Layer
type: note
permalink: scarf-wiki/transport-layer
created: 2026-05-29
updated: 2026-05-29
---

# Transport Layer

The `ServerTransport` protocol unifies local and SSH I/O. Services consume `transport.readFile(path)`, `transport.runProcess(...)`, `transport.snapshotSQLite(path)`, etc., without caring whether the bytes come from disk or the wire. Three implementations exist as of v2.5:

- **`LocalTransport`** — direct `FileManager` + `Process` against the local disk (`scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/LocalTransport.swift`).
- **`SSHTransport`** — OpenSSH-driven, multiplexed via ControlMaster. **Mac only**; iOS doesn't ship the `/usr/bin/ssh` binary (`scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift`).
- **`CitadelServerTransport`** — pure-Swift SSH via Citadel + NIO. **iOS only**, used by ScarfGo for every remote primitive (`scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift`).

All three implement the same protocol, so services in [ScarfCore](ScarfCore-Package) can consume any of them without `#if os(...)` shims.

## Protocol surface

[`ServerTransport.swift`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/ServerTransport.swift) exposes:

**Identity**
- `contextID: ServerID` — UUID; namespaces caches under `~/Library/Caches/scarf/snapshots/<id>/`.
- `isRemote: Bool` — true for `SSHTransport`.

**File I/O**
- `readFile(_ path) -> Data`
- `writeFile(_ path, data:)` — atomic via temp + swap; preserves `0600` mode for `.env`/`auth.json`/`*-tokens.json`.
- `fileExists(_ path) -> Bool`
- `stat(_ path) -> FileStat?` — size, mtime, isDirectory.
- `listDirectory(_ path) -> [String]`
- `createDirectory(_ path)` — idempotent, creates intermediates.
- `removeFile(_ path)` — idempotent.

**Processes**
- `runProcess(executable, args, stdin, timeout) -> ProcessResult` — blocking; captures stdout/stderr; SIGTERM on timeout.
- `makeProcess(executable, args) -> Process` — pre-configured but not yet started; caller owns lifecycle (used by `ACPClient`).

**SQLite snapshots**
- `snapshotSQLite(remotePath) -> URL` — local: returns the path unchanged. Remote: `sqlite3 .backup` on the remote, scp the result down, return a local URL into the snapshot cache.

**Watching**
- `watchPaths(_ paths) -> AsyncStream<WatchEvent>` — yields `.anyChanged` on any change. Local: FSEvents (`DispatchSourceFileSystemObject`). Remote: 3-second mtime polling.

## Errors

[`TransportErrors.swift`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/TransportErrors.swift) defines `TransportError`:

| Case | Cause |
|---|---|
| `hostUnreachable(host, stderr)` | DNS, connection refused, no route. |
| `authenticationFailed(host, stderr)` | SSH key not loaded or rejected. |
| `hostKeyMismatch(host, stderr)` | `~/.ssh/known_hosts` mismatch. |
| `commandFailed(exitCode, stderr)` | Remote command exited non-zero. |
| `fileIO(path, underlying)` | Local FS error. |
| `timeout(seconds, partialStdout)` | Hit `timeout` parameter. |
| `other(message)` | Catch-all. |

Stderr-pattern classification turns raw `ssh` errors into the right case so the UI can render actionable text.

## LocalTransport

[`LocalTransport.swift`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/LocalTransport.swift) — a thin wrapper around `FileManager`, `Process`, and `DispatchSourceFileSystemObject`.

- **Atomic writes:** writes to `<path>.scarf.tmp`, sets `0600` if the filename suggests a secret, then `replaceItemAt` (existing) or `moveItem` (new).
- **Process timeout:** polls every 100ms until deadline; `terminate()` if exceeded.
- **Watching:** opens each path with `O_EVTONLY`, creates a dispatch source for `.write/.extend/.rename`, yields `.anyChanged` on event.
- **Snapshot:** no-op — returns the path unchanged.

## SSHTransport

[`SSHTransport.swift`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift) — every primitive becomes an `ssh`/`scp`/`sftp` invocation, multiplexed over a single ControlMaster connection.

### ControlMaster pooling

Without ControlMaster, every remote call re-authenticates (500ms-2s each). With it, the first call sets up the master socket; subsequent calls reuse the same TCP+crypto session at ~5ms each.

The SSH option set is constructed by `sshArgs(extra:)`:

```
-o ControlMaster=auto
-o ControlPath=/tmp/scarf-ssh-<uid>/%C
-o ControlPersist=600          # keep alive 600s after last use
-o ServerAliveInterval=30      # keepalive every 30s
-o ServerAliveCountMax=3       # disconnect after 3 missed
-o ConnectTimeout=10
-o StrictHostKeyChecking=accept-new
-o LogLevel=QUIET              # binary-clean stdin/stdout for JSON-RPC
-o BatchMode=yes               # ssh-agent only; never prompt
```

`%C` hashes `(local user, host, port, remote user)` — multiple Scarf windows for the same host share one socket. `closeControlMaster()` issues `ssh -O exit` for clean shutdown.

The socket dir lives under `/tmp` (not `~/Library/Caches/`) because macOS' Unix domain socket path limit (`sun_path` in `<sys/un.h>`) is 104 bytes including NUL, and the Caches path plus `%C`'s 64-char hash exceeds that for users with longer `$HOME` strings (issue [#19](https://github.com/awizemann/scarf/issues/19), fixed in v2.0.2). The per-uid suffix isolates sockets between local users in the shared `/tmp`, and `ensureControlDir` enforces 0700 perms via POSIX `mkdir(0700)` plus an `lstat` ownership check (refuses to use a pre-existing dir owned by someone else). Stale sockets older than 30 minutes are swept on app launch via `SSHTransport.sweepStaleControlSockets` so crashed-master orphans don't accumulate until reboot.

### Path handling

Two helpers prevent shell-expansion breakage:

- `shellQuote(_:)` — wraps unsafe strings in single quotes, escaping embedded singles as `'\''`. Safe characters (alphanumerics + `@%+=:,./-_`) pass through unquoted.
- `remotePathArg(_:)` — converts `~/...` to `$HOME/...` (because shells don't expand `~` inside quotes) and double-quotes so `$HOME` expands but spaces don't break.

### File I/O over SSH

- `readFile`: `ssh host -- sh -c 'cat <path>'`; classifies "No such file" into typed `fileIO`.
- `writeFile`: scp to `<path>.scarf.tmp`, then remote `mv` — atomic; cleans the orphan on failure.
- `stat`: tries GNU `stat -c "%s %Y %F"`, falls back to BSD `stat -f "%z %m %HT"`.
- `listDirectory`: `ls -A <path>`. `createDirectory`: `mkdir -p`. `removeFile`: `rm -f`.

### Process execution

- `runProcess`: wraps `<exe> <args>` in `sh -c` so paths can use `$HOME`. Inherits `SSH_AUTH_SOCK` from the user's GUI environment so 1Password / Secretive agents work.
- `makeProcess`: returns `/usr/bin/ssh -T <opts> host -- sh -c '<exe> <args>'`. The `-T` disables PTY allocation so stdin/stdout stay binary-clean for JSON-RPC.

### SQLite snapshot

The trickiest operation. The remote runs:

```
sqlite3 "$HOME/.hermes/state.db" ".backup '/tmp/scarf-snapshot-XYZ.db'" && \
sqlite3 '/tmp/scarf-snapshot-XYZ.db' "PRAGMA journal_mode=DELETE;"
```

`.backup` is WAL-safe — it captures a consistent snapshot without blocking writers. The `PRAGMA journal_mode=DELETE` strips WAL mode so the snapshot is self-contained (no `-wal`/`-shm` sidecars). `scp` pulls it to `~/Library/Caches/scarf/snapshots/<id>/state.db`. The remote temp is removed.

#### Snapshot fallback _(v2.5.2+)_

`ServerTransport.cachedSnapshotPath` exposes that local cache path even when the remote is unreachable. `HermesDataService.open()` uses it as a fallback when a fresh `snapshotSQLite` call throws — the data layer surfaces `isUsingStaleSnapshot = true` + `lastSnapshotMtime` so views can render a "Last updated X ago" affordance instead of blanking. The chat-history reload path explicitly opts out via `refresh(forceFresh: true)` because falling back there would silently hide messages the agent streamed during the outage. `LocalTransport.cachedSnapshotPath` returns `nil` (the live DB has no separate cache).

### Remote watching

3-second polling: the remote runs a one-liner concatenating mtimes for the watched paths, hashed into a signature. When the signature changes, the stream yields `.anyChanged`. Transient connection drops are tolerated.

### Required tools on the remote

- `sqlite3` for the snapshot operation.
- `pgrep` for the Dashboard's "is Hermes running" check.
- `~/.hermes/` readable by the SSH user.

See [Servers & Remote](Servers-and-Remote) for setup and troubleshooting.

## CitadelServerTransport (iOS, v2.5+)

The iOS app can't shell out to `/usr/bin/ssh` — there's no such binary in the iOS sandbox. Instead, ScarfGo drives [Citadel](https://github.com/orlandos-nl/Citadel), a pure-Swift SSH/SFTP/exec implementation built on SwiftNIO. `CitadelServerTransport` wraps it behind the same `ServerTransport` protocol so all of ScarfCore consumes one shape.

### What's shared with the Mac transports

- Same `readFile` / `writeFile` / `stat` / `listDirectory` / `runProcess` / `snapshotSQLite` / `watchPaths` API.
- Same `TransportError` classification (host unreachable, auth failed, command failed, etc.).
- Same atomic-write convention (`<path>.scarf.tmp` → SFTP `rename`).
- Same SQLite snapshot mechanics — `sqlite3 .backup` on the remote, SFTP-pull the snapshot, `PRAGMA journal_mode=DELETE` to strip WAL.

### What's iOS-specific

- **Pure-Swift exec channel.** Citadel's exec channel does the SSH wire protocol (RFC 4254) directly; there is no shelled-out `ssh -T host -- cmd`. One long-lived `SSHClient` per host, kept warm by `CitadelConnectionHolder`.
- **Pure-Swift SFTP.** All `readFile` / `writeFile` / `stat` / `listDirectory` go over SFTP via Citadel's `SFTPClient`. Path resolution rewrites `~/...` to the probed `$HOME` (SFTP doesn't expand tildes per RFC 4254).
- **Inline PATH prefix on every `runProcess`.** Citadel's raw exec channel doesn't source the user's shell rc files, so non-interactive sessions land with `PATH=/usr/bin:/bin`. v2.5 inlines `PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"` on every command so pipx-installed `hermes` resolves and any subprocess hermes spawns can find git/curl/python. Mac's OpenSSH sshd handles this transparently via login-shell init; Citadel does not.
- **Output preservation on non-zero exit.** Citadel's high-level `executeCommand` API throws `CommandFailed` and discards captured stdout when the remote exits non-zero. v2.5 drives `executeCommandStream` directly — drains stdout + stderr regardless of outcome, recovers the actual exit code from the `CommandFailed` catch. This was the bug behind "Skills Browse failed" on iOS while Mac worked.
- **Keychain-backed SSH key.** Each configured server holds its own Ed25519 keypair in the iOS Keychain (`com.scarf.ssh-key` service, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, account `server-key:<UUID>`). Mac uses the system ssh-agent + `~/.ssh/config`; iOS keys never leave the device.
- **Watch via mtime polling.** Same 3-second cadence as `SSHTransport` — Citadel doesn't have an equivalent of inotify-over-SSH.
- **No streamed exec yet.** `streamLines` is a stub on iOS; log tailing in ScarfGo uses periodic refreshes instead. Future work — Citadel exposes the raw exec channel, just hasn't been wired up.

### Connection holder + reuse

Citadel's `SSHClient.connect(...)` handshake costs ~500ms on a warm network. ScarfGo keeps a long-lived per-server `CitadelConnectionHolder` so subsequent calls reuse the same TCP+crypto session — same idea as Mac ControlMaster, different mechanism. The holder is cached per-`ServerID` so two configured remotes don't contend on a single channel pool.

See [ScarfGo Onboarding](ScarfGo-Onboarding) for user-side setup and [ScarfCore Package](ScarfCore-Package) for why `KeychainSSHKeyStore` lives in `ScarfIOS` and not `ScarfCore`.

---
_Last updated: 2026-04-29 — Scarf v2.5.2 (snapshot fallback via `cachedSnapshotPath`)_