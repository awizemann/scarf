---
created: 2026-09-03
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/Packages/ScarfCore
source_paths_inferred: false
---

# ScarfCore — Shared Cross-Platform Logic

ScarfCore is a Swift Package under `scarf/Packages/ScarfCore/` that both macOS and iOS targets import. It contains the data models, services (business logic), transport layer, and shared ViewModels — everything that doesn't depend on platform-specific UI.

## What Goes Here

- **Models** (`Sources/ScarfCore/Models/`) — ACP protocol structures (`ACPRequest`, `ACPRawMessage`, `ACPEvent`), Hermes state records (`HermesMessage`, `HermesSession`, `CatalogEntry`), and domain types.
- **Services** (`Sources/ScarfCore/Services/`) — Business logic: `BotsService`, `BotAgentConfigService`, `CuratorService`, `FleetService`, session/cron backends, config readers.
- **Transport** (`Sources/ScarfCore/Transport/`) — `ServerContext` abstraction, `LocalTransport`, `SSHTransport`, `SSHConnectionGate`, subprocess draining.
- **ACP** (`Sources/ScarfCore/ACP/`) — `ACPClient` (the chat protocol engine), `ProcessACPChannel` (spawns `hermes acp` subprocess).
- **Parsing** (`Sources/ScarfCore/Parsing/`) — Hermes file format readers: bot profiles (YAML), cron doctor output, approvals, browser cloud providers.
- **Security** (`Sources/ScarfCore/Security/`) — Onboarding state machines, SSH key generation, keychain contracts, connection testing.
- **ViewModels** (`Sources/ScarfCore/ViewModels/`) — Cross-platform state: `ActivityViewModel`, `ConnectionStatusViewModel`, `CuratorViewModel` — never platform UI logic.
- **Diagnostics** (`Sources/ScarfCore/Diagnostics/`) — `ScarfAnalytics` (injectable seam; [[analytics-via-swift-stats]]), `ScarfMon` (performance sampling).

## What Doesn't

- Platform UI: SwiftUI views are in `scarf/scarf/` (macOS) or `scarf/Scarf iOS/` (iOS), never ScarfCore.
- Analytics implementations: ScarfCore exposes `ScarfAnalyticsRecording` protocol; only the macOS app provides `CoreBridge` implementation.
- App-specific routing: `AppCoordinator` and multi-window logic live in the macOS target.

## Test Isolation

Tests in `Tests/ScarfCoreTests/` inject a temporary `~/.hermes` via `ServerContext.local(home:)` — production never uses this; it's test-only. [[scarfcore-tests-inject-a-temp-hermes-home]]

## Key Patterns

**ServerContext abstraction** — Every Hermes host (local or remote) is wrapped in `ServerContext`, which provides:
- `kind: LocalOrRemote` — distinguishes local `~/.hermes` from SSH hosts.
- `paths: HermesPaths` — resolves config.yaml, state.db, skills dir, etc. to their actual filesystem or SSH paths.
- `runHermes(args:) -> String` — spawns the Hermes CLI and captures output.
- `readFile(path:) -> String` — reads a file (locally or via scp).

On macOS, all SSH calls gate through `SSHConnectionGate.shared` [[ssh-circuit-breaker-gates]] to fail-fast on dead connections. iOS uses `CitadelTransportPool` for connection reuse.

**Services are nonisolated** — Every public service method is `nonisolated` (not `@MainActor`), so blocking SSH I/O doesn't freeze the UI. Callers use `.task` or `.background` to invoke them.

**Strict concurrency** — All sendable contracts are explicit. Models are structs marked `Sendable`; error enums too. Tasks that capture self store the handle for cancellation.

## Testing ScarfCore

Run via SwiftPM, NOT Xcode:
```bash
swift test --package-path scarf/Packages/ScarfCore 2>&1 | grep -E '^(Test Suite|Executed)'
```

[[fast-test-iteration-commands]]