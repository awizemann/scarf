## What's New in 2.0.2

The actual root cause of [#19](https://github.com/awizemann/scarf/issues/19), found and patched by Scarf's first external contributor. v2.0.1 added the diagnostics UI assuming file-perm root cause; v2.0.2 fixes the underlying bug for everyone, regardless of perms.

### macOS Unix domain socket path limit (the real #19)

OpenSSH's ControlMaster multiplexes our bursty stat/cat/cp traffic over one TCP session per host. The socket path is bound by `bind(2)` to a Unix domain socket — and macOS' `sun_path` is **104 bytes including the NUL terminator**.

Scarf's old socket path was `~/Library/Caches/scarf/ssh/<%C>` where `%C` is OpenSSH's 64-char SHA1 hash of `(local user, host, port, remote user)`. For a username like `alex.maksimchuk`, the full path landed at **105 bytes** — one byte over the limit. ssh exited 255 with `unix_listener: path "..." too long for Unix domain socket`. Our `LogLevel=QUIET` flag (set so ACP's line-delimited JSON stays binary-clean) suppressed the diagnostic, and the user just saw "Remote command exited 255" — which the UI rendered as the silent empty-data state every reporter in #19 described.

The fix is to use a much shorter path:

```swift
"/tmp/scarf-ssh-\(getuid())"   //  ~17 bytes + 64 hash + sep + NUL = ~83 bytes
```

Per-user uid suffix keeps two local users' sockets from colliding in the shared `/tmp`, and 0700 perms on the dir keep them inaccessible to other users.

**Massive thanks to Alex Maksimchuk ([@aliatx2017](https://github.com/aliatx2017)) — Scarf's first external PR contributor — for diagnosing and patching this in [#20](https://github.com/awizemann/scarf/pull/20).** That diagnosis only happened because Alex bothered to read the codebase, reproduce against multiple usernames including a Termux/Android instance, and walk back from the cryptic exit code to the actual `bind()` failure. This release wouldn't exist without that work.

### Hardening on top of the fix

Three additions on top of Alex's patch, layered in via separate commits to keep the original change reviewable:

- **Defensive ownership check on the socket dir.** `/tmp` is world-writable, so a malicious local user could pre-create `/tmp/scarf-ssh-<uid>` and trick Scarf into using a hostile directory (we'd silently fail to chmod it back to 0700, since we wouldn't own it). `ensureControlDir` now uses POSIX `mkdir(0700)` (atomic, sets perms at create time) and on `EEXIST` runs `lstat` to verify the entry is a directory we own with mode 0700 — symlink → refuse, wrong owner → refuse + log to `os.Logger`, wrong mode → repair. Closes the `/tmp` pre-creation hole that's the standard concern for any per-user `/tmp` path.
- **Launch-time sweep of stale sockets.** `ServerRegistry.sweepOrphanCaches` already prunes orphaned snapshot directories on launch; it now also removes ControlMaster socket files older than 30 minutes. Socket basenames are `%C` hashes (not ServerIDs), so we can't keep "still registered" sockets the way the snapshot sweep does — but `ControlPersist` is 600s, so anything older than 30 minutes is guaranteed to be a dead orphan from a crashed master, an unclean app exit, or a server removed while another Scarf instance was holding the dir. Keeps `/tmp/scarf-ssh-<uid>/` from accumulating indefinitely until reboot, while leaving any concurrent Scarf instance's live sockets untouched.
- **Regression test for the path-length invariant.** `scarfTests` was a stub — it now has two tests: one asserting `controlDirPath().utf8.count + 1 + 64 + 1 ≤ 104` (would have caught the original #19 bug in CI), one asserting the path includes the current uid (pins the per-user-isolation invariant against a future "simplification" that drops it).

### v2.0.1 diagnostics work is still useful

The diagnostics sheet, orange "degraded" pill, dashboard error banner, and `remoteHome` auto-suggest from v2.0.1 all still ship — they just turn out not to have been the right diagnosis for the original three reporters. They remain valuable for the *other* connection-failure modes they were designed to surface (missing `sqlite3` on the remote, real permission errors, container/host visibility gaps, custom Hermes data directories). If you upgrade to v2.0.2 and *still* see incomplete data, run Remote Diagnostics from **Manage Servers → 🩺** and the sheet will tell you why.

### Migrating from 2.0.0 / 2.0.1 / draft 2.0.1

Sparkle will offer the update automatically. Settings and server list are preserved verbatim. The first time v2.0.2 connects to a remote, it'll create `/tmp/scarf-ssh-<uid>/` with mode 0700; the old `~/Library/Caches/scarf/ssh/` directory becomes unused (you can delete it manually, or leave it — macOS will sweep it eventually).

The previous v2.0.1 draft download remains available for anyone who already grabbed it — it's still a valid build with the diagnostics work. v2.0.2 is the recommended upgrade path.

### Reporters of #19

@cmalpass, @flyespresso, @maikokan — please grab v2.0.2 and confirm the dashboard populates without needing to run Remote Diagnostics first. If it still doesn't, the diagnostics sheet should now have a much better chance of pinpointing what's left.
