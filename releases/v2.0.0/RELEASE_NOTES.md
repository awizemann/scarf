## What's New in 2.0

Scarf now manages **multiple Hermes installations** — your local `~/.hermes/` plus any number of remote Hermes instances reached over SSH. Every feature that worked on your Mac now works against a Linux server, a Mac mini on the network, or whatever other host has Hermes installed.

This is a major version bump because the entire service layer was rewritten around a `ServerContext` + `ServerTransport` abstraction, and because the window model changed from single-window-single-server to multi-window-one-server-per-window.

### Multi-server

- **Manage Servers** sheet lets you add, rename, and remove remote servers. Each entry is an SSH target (`user@host`, port, optional identity file, optional `remoteHome` override if your install isn't at `~/.hermes/`).
- Each window is bound to exactly one server. Open a second window via **File → Open Server** → pick a different server, and the two run side-by-side with independent state — chat, dashboards, activity, sessions, the lot.
- The menu bar status icon shows a summary across all registered servers (green hare = any Hermes running anywhere).
- Window-state restoration: quit + relaunch re-opens every window you had open, each reconnected to its bound server.

### Remote over SSH

- **ControlMaster connection pooling** — after the first auth, each remote primitive is a ~5ms tunnel call. Uses the system `ssh`, `scp`, `sftp` so your `~/.ssh/config`, ssh-agent, 1Password/Secretive SSH agents, and ProxyJump all work unchanged.
- **DB access via atomic snapshots** — Scarf runs `sqlite3 .backup` on the remote (WAL-safe, won't corrupt), flips the snapshot out of WAL mode, and pulls it down with `scp`. Snapshots are cached under `~/Library/Caches/scarf/snapshots/<server-id>/` and re-pulled when the file watcher sees a change on the remote's `state.db`.
- **ACP chat over SSH** — the Agent Client Protocol tunnel runs `ssh -T host -- hermes acp`. JSON-RPC over stdio travels end-to-end unmodified, so Rich Chat, streaming, tool calls, permission dialogs, and compression all work against the remote agent identically to local.
- **File watcher** — local uses FSEvents (instant); remote polls `stat` mtime every 3s with ControlMaster keeping the cost bounded. Views auto-refresh on any tick.
- **Cleanup on server-remove** — deleting a remote closes its ControlMaster socket (`ssh -O exit`), prunes its snapshot cache, and invalidates any process-wide caches keyed to its ID. App launch also sweeps orphaned snapshot dirs whose UUIDs are no longer in the registry.

### Chat UX overhaul

All of these were visible bugs during remote dogfooding and are now fixed on both local and remote:

- **No more white-screen flash** on the first message of a session. `RichChatView` used to swap `ContentUnavailableView` out for the message list, which tore down and recreated the entire ScrollView hierarchy. The empty state now lives inside the ScrollView itself.
- **No more scroll-jumping to whitespace** at stream start/finish. Replaced six racing `onChange`-driven scroll calls with SwiftUI's built-in `.defaultScrollAnchor(.bottom)`, which is implemented inside the layout pass and doesn't overshoot LazyVStack content.
- **Resuming a session on a remote now shows its full history.** The DB snapshot is refreshed on session-load — previously it was pulled once on first open and never again, so any messages the remote wrote since launch were invisible.
- **"Continue from last session" surfaces errors** instead of silently doing nothing when SSH is down.
- **Typing into a blank Chat always creates a new session.** Previously it auto-resumed the most recently active session in the DB, which often picked up a cron-spawned session that Hermes had already garbage-collected — producing a silent prompt failure.
- **Failed prompts now explain themselves.** When the agent returns `stopReason: "refusal"`, `"error"`, or `"max_tokens"` with no assistant output, a system message appears under your prompt explaining what happened. No more spinning "Agent working…" forever.

### Correctness — remote SQLite

- The WAL-error spam (`cannot open file at line 51044 of [f0ca7bba1c] — os_unix.c:51044: (2) open(/Users/…/state.db-wal) - No such file or directory`) is gone. `sqlite3 .backup` preserves the source DB's journal mode; the scp'd copy used to try to open a WAL sidecar that doesn't exist. The snapshot script now runs `PRAGMA journal_mode=DELETE` after `.backup` on the remote, and Scarf opens remote snapshots with `file:…?immutable=1` as defense-in-depth.
- **Concurrent snapshot dedupe** — a new `SnapshotCoordinator` actor makes sure that when Dashboard + Sessions + Activity all ask for a fresh snapshot at the same moment (e.g. on a file-watcher tick), only one SSH backup runs; the other callers await the in-flight pull and share the result.

### Under the hood

- New `ServerContext` value type flows through `.environment()` to every view and ViewModel. Every file and process operation routes through `context.makeTransport()` — `LocalTransport` (`FileManager`, `Process`, FSEvents) or `SSHTransport` (ssh, scp, sftp, mtime polling). The protocol is small enough that each transport is ~400 lines.
- Swift 6 complete-concurrency sweep: ~230 warnings reduced to 1. `ServerContext`, `HermesPathSet`, `ServerTransport`, all service inits, and every value-type accessor are explicitly `nonisolated`. Hand-written `Codable` conformances for the nine types whose synthesized conformances were inferred `@MainActor` by Swift 6's default-isolation rule (`ACPRequest`, `ACPRawMessage`, `GatewayState`, `PlatformState`, `HermesCronJob`, `CronSchedule`, `CronJobsFile`, `AuthFile`, `AuthEntry`).
- ACP cwd now comes from the *remote* `$HOME`, probed once on first connect and cached per server. Previously it passed your local Mac's home path to the ACP adapter, which only worked by coincidence when the remote username matched.

### Compatibility

Hermes v0.10.0 is now verified alongside v0.6–v0.9. Scarf builds its session/message `SELECT` columns based on an additive schema detection (`hasV07Schema`), so newer Hermes versions with extra columns don't break queries.

### Migration from 1.6.x

- Sparkle will offer the update automatically. Trigger manually via **Scarf → Check for Updates…** or the menu bar.
- Your local server is synthesized automatically — existing 1.6.x users see "Local" in the server list with no setup needed.
- `servers.json` is created on first add-remote. Location: `~/Library/Application Support/scarf/servers.json`.
- Nothing you configured in 1.6.x (OAuth tokens, credential pools, cron jobs, MCP servers, platform setup) is touched. Those live in `~/.hermes/` and remain the source of truth.

### Known limitations

- Remote file watching is 3s mtime polling (vs. FSEvents on local). If you need sub-second updates on a remote, that's a followup.
- The `session/load` ACP call against an already-deleted session returns success-with-no-body from the Hermes adapter — Scarf now detects the resulting `stopReason: "refusal"` and surfaces it, but the underlying Hermes behavior is an upstream-adapter bug that should also get a proper error response.
