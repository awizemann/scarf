---
created: 2026-09-03
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/Packages/ScarfCore/Sources/ScarfCore/Transport, scarf/Packages/ScarfIOS/Sources/ScarfIOS
source_paths_inferred: false
---

# Transport & Remoting — ServerContext, SSH, and Citadel

Scarf connects to Hermes servers that can be local (`~/.hermes/`) or remote (over SSH). The **transport layer** abstracts this difference so services and ViewModels never care where Hermes lives.

## ServerContext Abstraction

`ServerContext` is the gateway to a Hermes installation. It provides:

- **`kind: LocalOrRemote`** — Distinguishes local from remote.
- **`paths: HermesPaths`** — Resolves config.yaml, state.db, skills dir, memory files, etc. to their actual locations (filesystem for local, SSH paths for remote).
- **`runHermes(args:) async throws -> String`** — Spawns the Hermes CLI (locally or via SSH) and captures output.
- **`readFile(path:) async throws -> String`** — Reads a file (locally or via scp).
- **`writeFile(path:contents:) async throws`** — Writes a file.
- **`isRemote: Bool`** — Convenience to branch on connection type.

## Local vs. Remote

**Local** — Directly accesses `~/.hermes/`. File I/O is synchronous; subprocess spawns are local.

**Remote** — All I/O goes through SSH:
- `runHermes("session list")` becomes `ssh user@host -- hermes session list`.
- `readFile("/path/to/file")` becomes `scp user@host:/path/to/file /tmp/...` and reads the temp copy.
- `writeFile()` scp's the new content back.

**Config reads survive invisible config.yaml** — If remote config.yaml doesn't exist, `HermesConfigReader` has a fallback chain. [[config-reads-must-survive-an-invisible-config-yaml]]

## SSH Circuit Breaker (macOS)

All SSH calls on macOS gate through `SSHConnectionGate.shared` (`ScarfCore/Transport/SSHConnectionGate.swift:29`). After 3 consecutive exit-255 or timeout failures, the gate **opens** (fails-fast on new calls) for 30 seconds, then backs off to 300 seconds.

This prevents spinning on a dead connection when the network is down.

[[ssh-circuit-breaker-gates-all-outbound-connection-attempts]]

## ControlMaster Staleness (macOS)

macOS multiplexes ALL SSH calls through one OpenSSH ControlMaster socket (`/tmp/scarf-<server-hash>.sock`). If the master dies (remote kills the session, network partition), the socket becomes stale and new calls hang indefinitely.

**Nothing self-heals.** Dead masters must be probed and reset manually. The Health view offers one-click diagnostics and remediation.

[[macos-controlmaster-staleness-dead-masters-must-be-probed]]

## iOS Citadel SSH (ScarfGo)

iOS (ScarfGo) uses pure-Swift SSH via the **Citadel** transport. Key differences from macOS:

- **Ed25519 on-device** — The SSH private key is generated on the phone, stored in the iOS Keychain, and never leaves the device.
- **Connection pooling** — `CitadelTransportPool` (`scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelTransportPool.swift:46`) reuses connections per server to avoid connection churn.
  - **Bug:** `ServerContext.makeTransport()` returns a FRESH value per call; pooling was never wired. [[ios-transport-must-be-pooled-per-serverid-sshconfig-un]]
- **SSH key resolution** — Each server entry has its own Keychain-stored key; onboarding saves it per `ServerID`. [[ios-runtime-ssh-keys-must-resolve-per-server-entry]]

## ProcessPipeDrainer (Subprocess Output)

When Scarf spawns `hermes acp` or `hermes session list`, output comes in on pipes. `ProcessPipeDrainer` (`ScarfCore/Transport/ProcessPipeDrainer.swift:11`) captures stdout/stderr without blocking:
- Spawns a thread per pipe.
- Drains the pipe until EOF (the subprocess exits).
- Returns captured output as a single string.

**Never run synchronous I/O on the MainActor from a file watcher or view body.** On remote, these I/O calls do SSH round-trips. [[never-run-synchronous-transport-i-o-on-the-mainactor]]

## Testing Transport

`ServerContext.local(home: tempDir)` injects a temporary Hermes home for tests. Tests read/write to this temp directory, leaving the real `~/.hermes` untouched.

## Key Patterns

**Nonisolated public methods** — All transport methods are `nonisolated`, so blocking I/O doesn't freeze the UI. Callers use `.task` to dispatch.

**Sendable contracts** — Every error and return type is explicitly `Sendable` for strict concurrency.

**Error translation** — SSH errors are wrapped in app-level enums (e.g., `ServerContextError`, `ACPClientError`) for UI-friendly error handling.