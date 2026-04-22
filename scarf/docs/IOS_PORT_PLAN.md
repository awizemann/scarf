# Scarf iOS Port — Plan & Progress Log

> Living document. Updated at the end of each phase. Read this before starting
> any phase so you know what the prior phase did, what shipped, and what the
> next phase is allowed to assume.

## Locked Decisions

- **iOS 18 minimum.** Matches the Mac app's `@Observable` / `NavigationStack`
  APIs so ViewModels can move into `ScarfCore` without `#if os(iOS)` gymnastics
  on the navigation layer.
- **iPhone only for v1.** iPad Universal deferred (+1 week to add later).
- **No APNs push for v1.** Requires a Hermes-side server component. Deferred.
- **Remote-only on iOS.** No local Hermes mode — iOS sandbox can't read
  `~/.hermes/` and can't spawn subprocesses. SSH to a user-owned Hermes
  install (Mac, home server, VPS) is the only connection model. This is by
  design, not a regression.
- **SSH library: Citadel** (pure Swift, SwiftNIO, MIT licensed).
- **Distribution: TestFlight → App Store.** No Sparkle on iOS. Apple
  Developer team `3Q6X2L86C4` is reused.
- **Shared-code strategy: local Swift Package (`ScarfCore`).** Not a
  multiplatform target. `PBXFileSystemSynchronizedRootGroup` makes
  per-file target membership impractical, so the Mac and iOS apps each
  consume a separate SPM package and provide their own platform shells.

## Target Architecture

```
scarf/                                (repo root)
  scarf/                              (Xcode project folder)
    scarf.xcodeproj/
    Packages/
      ScarfCore/                      (local SPM — platform-neutral)
        Package.swift
        Sources/ScarfCore/
          Models/                     (added in M0a)
          Transport/                  (added in M0b)
          Services/                   (added in M0c — portable subset)
          ViewModels/                 (added in M0d — portable subset)
          Views/                      (added in M0d — portable subset)
        Tests/ScarfCoreTests/
    scarf/                            (macOS app — PBXFileSystemSynchronizedRootGroup)
      MacApp/                         (Mac-only glue: Sparkle, SwiftTerm, NSWorkspace shims)
      Core/Services/                  (Mac-only services remain here)
      Features/                       (Mac-only features remain here)
      Navigation/
    scarf-ios/                        (iOS app — added in M2)
      iOSApp/                         (iOS-only glue: CitadelTransport, tab/stack nav)
```

## What We Give Up On iOS (Intentional)

| Dropped | Reason |
|---|---|
| Local Hermes mode | Sandbox + no subprocess on iOS |
| Sparkle auto-updates | App Store handles updates |
| Terminal mode in Chat (SwiftTerm) | Mac-only in v1; SwiftTerm does support iOS, defer to v1.1 |
| Embedded terminal platform-setup (Signal/WhatsApp pairing) | Same SwiftTerm dependency |
| `NSWorkspace.open(_:)` "open in editor" / "reveal" | No equivalent; use `UIApplication.open(_:)` for URLs |
| Multi-window (one window per server) | iPhone-only v1; iPad scenes may come later |
| Menu bar, global shortcuts, drag-and-drop from Finder | Not applicable on iOS |

## What Ships In The v1 iOS App

Dashboard, Sessions Browser, Sessions Detail, Activity Feed, Insights,
Memory viewer/editor, Skills, Cron, Logs, Health, Rich Chat, Settings
(read-mostly). ~70% of the current Mac feature surface.

## The One Real Refactor: Decouple ACP from `Process`

`Core/Services/ACPClient.swift` currently pokes at `Process.isRunning`,
`Process.terminationHandler`, and `Darwin.write()` on raw pipe file
descriptors. Those APIs don't exist on iOS. We introduce:

```swift
protocol ACPChannel: Sendable {
    var isOpen: Bool { get }
    func send(_ line: String) async throws       // JSON line + "\n"
    var incoming: AsyncThrowingStream<String, Error> { get }
    func close() async
}
```

- Mac: `ProcessACPChannel` wraps today's `Process` + `Pipe` code.
- iOS: `SSHExecACPChannel` wraps a Citadel exec session.

This lands in **M1**.

## SSH on iOS: Citadel

[`orlandos-nl/Citadel`](https://github.com/orlandos-nl/Citadel) is pure-Swift
SSH on SwiftNIO. What we use:

- Public-key auth, keys imported from Files.app or generated on-device and
  exported as public key for `authorized_keys`.
- Long-lived exec channel for ACP JSON-RPC over stdio.
- SFTP for `state.db` snapshot pulls (same flow as Mac's `scp`).
- One-shot exec for `stat`/`cat`/`sqlite3 .backup` used by existing services.

What we lose vs. system `ssh`: no `~/.ssh/config`, no `ProxyJump`, no
ControlMaster, no ssh-agent. We run a per-app in-memory session pool (one
session per server, reused across calls) to recover the perf benefit.

## Distribution, Testing, CI

- **TestFlight** primary beta channel.
- **App Store** production distribution.
- **CI** (GitHub Actions, `macos-latest`):
  - `swift test` against `Packages/ScarfCore` — fast, no simulator.
  - `xcodebuild test -scheme scarf-ios -destination 'platform=iOS Simulator,...'`
    for iOS UI tests (added in M2+).
  - `xcodebuild test -scheme scarf` for the Mac target (unchanged).
- **Release script** `scripts/release-ios.sh` added in M6: `xcodebuild archive`
  → `-exportArchive` with App Store profile → `xcrun notarytool`-free path
  (App Store review replaces notarization for iOS). The existing
  `scripts/release.sh` keeps its Mac-specific Sparkle flow.

## Milestones

| ID | Scope | Size |
|---|---|---|
| **M0** | Extract `ScarfCore` package (Mac-only, no iOS yet) | 1–2 weeks |
| **M1** | Decouple ACP from `Process` via `ACPChannel` protocol | 2–3 days |
| **M2** | iOS app skeleton — Citadel, onboarding, Dashboard only | ~1 week |
| **M3** | iOS monitor surface — Sessions, Activity, Insights, Logs, Health | 1–2 weeks |
| **M4** | iOS Rich Chat — `SSHExecACPChannel` + ACPClient wiring | ~1 week |
| **M5** | iOS writes — Memory, Cron, Skills, Settings | 3–5 days |
| **M6** | Polish, TestFlight public beta, App Store submission | ~1 week |

Total: **6–9 weeks.**

### M0 Sub-Phases (each is its own PR)

Because M0 is too large for a single safe PR (no ability to run builds
between commits), it's split into 4 self-contained sub-PRs that each leave
the Mac app in a working state:

- **M0a** — Package scaffolding + move 13 leaf Models to `ScarfCore`
- **M0b** — Move Transport + `ServerContext` to `ScarfCore`
- **M0c** — Move portable Services (`HermesDataService`, `HermesLogService`,
  `ModelCatalogService`, `ProjectDashboardService`) to `ScarfCore`
- **M0d** — Move portable ViewModels + Views to `ScarfCore`

## Rules For Future Phases

1. **Any new feature lands in `ScarfCore` by default.** macOS-only is allowed
   for features that need `Process`, `NSWorkspace`, embedded `SwiftTerm`, or
   menu-bar integration — document why in the feature's header comment.
2. **Every PR leaves the Mac app building and passing tests.** If the PR's
   own changes can't be verified in the sandbox agent environment, the PR
   description must list a manual verification checklist for Alan to run
   before merging.
3. **Wiki updates follow the CLAUDE.md rules** — if the feature was moved,
   the wiki page for that feature should note whether it's available on
   macOS, iOS, or both.
4. **Version numbers stay in lockstep.** Mac and iOS bump to the same
   `MARKETING_VERSION` in one commit.

---

## Progress Log

### M0a — shipped in PR #31

**Shipped:**

- `Packages/ScarfCore/Package.swift` (Swift tools 6.0, targets macOS 14 +
  iOS 18). **Language mode pinned at `.v5`** to match the Mac app's
  `SWIFT_VERSION = 5.0`. Two types (`ACPEvent.availableCommands` and
  `ACPToolCallEvent.rawInput`) claim `Sendable` while carrying
  `[String: Any]` payloads — strict Swift 6 rejects that. A future
  cleanup phase should replace those with typed payloads and bump to
  `.v6`.
- 13 leaf model files moved under `Sources/ScarfCore/Models/`.
- `HermesConstants.swift` split: `sqliteTransient` + `QueryDefaults` +
  `FileSizeUnit` are in ScarfCore; the deprecated `HermesPaths` enum is
  parked in the Mac target at `HermesPaths+Deprecated.swift`. Zero
  callers in-tree — it can be deleted in M0b alongside `ServerContext`.
- Every moved type, member, and (where needed) nested `CodingKeys` is
  `public`. Every struct got an explicit `public init(...)` — Swift's
  synthesized memberwise init is `internal` and would have broken
  cross-module construction. A throwaway Python generator did the
  mechanical work; tests in `ScarfCoreTests` exercise every generated
  init so parameter drift would fail CI, not a reviewer.
- `scarf.xcodeproj/project.pbxproj` gains one
  `XCLocalSwiftPackageReference` for `Packages/ScarfCore` and links the
  product into the `scarf` target.
- 49 main-target files (not 35 as originally estimated — many `View`
  files only `import SwiftUI` without `Foundation`) got
  `import ScarfCore`.

**Linux-CI compatibility additions (for `swift test` in containers):**

- `SQLite3` system module exists on macOS/iOS but not on Linux
  swift-corelibs. `sqliteTransient` in `HermesConstants.swift` is
  wrapped in `#if canImport(SQLite3)`. Apple platforms compile it
  unchanged; Linux just doesn't see it (no one on Linux will execute
  Hermes DB code anyway).
- `LocalizedStringResource` is an Apple-only Foundation type.
  `ToolKind.displayName` (in `HermesMessage.swift`) and
  `MCPTransport.displayName` (in `HermesMCPServer.swift`) are wrapped
  in `#if canImport(Darwin)`. Apple platforms compile them unchanged;
  Linux builds skip them.

**Test coverage (`ScarfCoreTests`):** 16 tests that construct every
moved type via its `public init`, verify computed properties, round-trip
Codable (`HermesCronJob`, `WidgetValue`), exercise nested config
`.empty` chains, and assert `KnownPlatforms` / `MCPServerPreset.gallery`
statics are readable. Run via `docker run --rm -v
$PWD/scarf/Packages/ScarfCore:/work -w /work swift:6.0 swift test`.

**Rules next phases can rely on:**

- The `public init` pattern is now established for ScarfCore structs.
  M0b+ should add explicit `public init(...)` to every new struct moved
  into the package.
- `#if canImport(Darwin)` is the package's "Apple-only API" guard.
  Prefer this over `os(iOS) || os(macOS) || ...` — it's shorter and
  catches the same platforms.
- `#if canImport(SQLite3)` is the pattern for anything that needs
  Apple's built-in SQLite. When HermesDataService moves in M0c, use
  this same guard for the actual Swift-SQLite bindings.
- The Mac app still uses Swift 5 language mode. Do **not** add
  `nonisolated` to new ScarfCore APIs pre-emptively; match the
  surrounding conventions.

### M0b — shipped

**Shipped:**

- 4 Transport files moved to `Packages/ScarfCore/Sources/ScarfCore/Transport/`:
  `ServerTransport.swift`, `LocalTransport.swift`, `SSHTransport.swift`,
  `TransportErrors.swift`.
- `ServerContext.swift` moved to `Packages/ScarfCore/Sources/ScarfCore/Models/`.
  The `runHermes(_:timeout:stdin:)` and `openInLocalEditor(_:)` extension
  methods — the only two that depend on main-target `HermesFileService` or
  on AppKit's `NSWorkspace` — are split out into a new main-target file
  `scarf/Core/Models/ServerContext+Mac.swift`.
- `HermesFileService.enrichedEnvironment()` reference inside
  `SSHTransport.sshSubprocessEnvironment()` replaced with a local
  `#if os(macOS)` helper `macLoginShellSSHAgent()` that does a narrow
  `zsh -l -c` probe for only `SSH_AUTH_SOCK` / `SSH_AGENT_PID` (instead
  of the broader PATH + credentials harvest that still lives in
  `HermesFileService`). This breaks the Mac-target dependency from
  ScarfCore. Behavior-identical on macOS; a no-op on iOS (where the SSH
  agent comes from Citadel in M4, not the user's shell) and on Linux CI.
- `HermesPaths+Deprecated.swift` deleted. Its only justification was that
  `ServerContext` was in the Mac target; with `ServerContext` in ScarfCore
  now, the deprecated forwarders are both unreachable AND unused (zero
  callers). Good riddance.
- Added `import ScarfCore` to 54 more consumer files that reference
  Transport types or `ServerContext` but weren't already importing
  ScarfCore from M0a. `scarfTests/scarfTests.swift` also gets the import
  — its `ControlPathTests` now hits the public `SSHTransport` via
  ScarfCore.

**Platform guards applied in ScarfCore:**

- `#if canImport(os)` — Apple's `os.Logger` (`import os` + every call
  site). Linux gets silent logging. **Exception:** the large block in
  `SSHTransport.ensureControlDir()` uses `Darwin.stat` / `lstat` / `mkdir`
  / `chmod` alongside its Logger calls — the whole method body is wrapped
  in `#if canImport(Darwin)` with a simple `FileManager.createDirectory`
  fallback for Linux (stubbed because SSH isn't exercised at runtime on
  Linux anyway).
- `#if canImport(Darwin)` — `Darwin.open`/`Darwin.close` + FSEvents-based
  `DispatchSourceFileSystemObject` in `LocalTransport.watchPaths`. Linux
  gets a no-op empty stream.
- `#if canImport(SwiftUI)` — `EnvironmentKey` / `EnvironmentValues`
  plumbing in `ServerContext.swift`.
- `#if canImport(AppKit)` — only in the split-out
  `ServerContext+Mac.swift`, where `NSWorkspace.shared.open` lives. iOS
  will provide its own equivalent (`UIApplication.open(_:)`) when the
  target lands in M2.

**Bug fixed while moving:** the sed transform in M0a accidentally promoted
`protocol ServerTransport` requirements to `public nonisolated var contextID ...`.
Protocol requirements inherit the protocol's access level and **must
not** carry an explicit modifier — that's a Swift compile error. Fixed
in this PR's ServerTransport.swift.

**Test coverage (`M0bTransportTests`):** 18 new tests that construct
`SSHConfig` with and without defaults, round-trip it through Codable,
verify `ServerKind` pattern-matching, pin `ServerContext.local`'s
hard-coded UUID, assert local-vs-remote path derivation, verify
`makeTransport()` dispatches to the right impl, exercise `FileStat` /
`ProcessResult` / `WatchEvent` / `TransportError` shapes + error-classifier
stderr patterns, and round-trip an actual local file through
`LocalTransport` (write → read → stat → remove).

**Rules next phases can rely on:**

- `ServerContext` is the canonical multi-server entry point. Any new
  service added in M0c or later takes a `ServerContext` in its init.
- `ServerContext+Mac.swift` is the pattern for Mac-only methods on
  ScarfCore types. iOS will have a sibling `ServerContext+iOS.swift`
  when the iOS target lands. Keep platform-specific methods out of
  ScarfCore itself and in these sibling files.
- Logger pattern: `#if canImport(os) ... #endif` around each call site.
  If there are 3+ sites in one method, consider wrapping the whole method
  body in `#if canImport(Darwin)` with a Linux-safe fallback.
- SSH env enrichment is now self-contained in `SSHTransport.swift`. When
  iOS's Citadel-based transport lands (M4), it will provide its own env
  story — the existing macOS helper stays untouched.

### M0c — shipped

**Shipped:**

- 4 portable Services moved to `Packages/ScarfCore/Sources/ScarfCore/Services/`:
  - `HermesDataService.swift` (658 lines, SQLite3-backed session/message/activity reader + `SnapshotCoordinator` actor)
  - `HermesLogService.swift` (log tailing + parsing, `LogEntry` + `LogLevel`)
  - `ModelCatalogService.swift` (models.dev cache reader, `HermesModelInfo` + `HermesProviderInfo`)
  - `ProjectDashboardService.swift` (per-project dashboard JSON I/O)
- `HermesFileService.swift`, `HermesEnvService.swift`, `HermesFileWatcher.swift`,
  `ACPClient.swift`, and `UpdaterService.swift` stay in the Mac target.
  `HermesFileService` holds the big shell-enrichment logic and is the only
  non-portable heavyweight — a later phase can port it once iOS has a
  clearer story for shell-env-less ACP spawning. `ACPClient` is M1's job
  (the `ACPChannel` refactor). `UpdaterService` wraps Sparkle and stays
  Mac-only forever.
- The one remaining external consumer that wasn't already importing
  ScarfCore (`Features/Settings/Views/Components/ModelPickerSheet.swift`)
  now has `import ScarfCore` added.

**Platform guards:**

- **`HermesDataService.swift` is wrapped in `#if canImport(SQLite3)` /
  `#endif`** — the whole file. SQLite3 isn't a system module on Linux
  swift-corelibs-foundation, and the service is unusable without it.
  Apple platforms (the real runtime targets) compile it unchanged. Linux
  builds just skip it. Nothing in ScarfCore references
  `HermesDataService` from outside that file, so there's no downstream
  fallout.
- `ModelCatalogService.swift` — `import os` / logger definition / logger
  call sites all guarded with `#if canImport(os)`. Linux gets silent
  logging.

**Test coverage (`M0cServicesTests`):** 8 new tests.

- `HermesLogService.parseLine` exercised via `readLastLines` against a
  real local log file with three lines (v0.9.0+ format with session tag,
  older format without, and a garbage fallback line). Verifies the
  optional session tag handling called out in CLAUDE.md.
- `LogEntry.LogLevel` colour strings pinned (SwiftUI views depend on
  them matching colour names).
- `HermesModelInfo.contextDisplay` tested across `1M`, `200K`, `500`,
  and `nil` cases; `costDisplay` tested with and without costs.
- `ModelCatalogService` load path exercised end-to-end against a
  synthetic `models_dev_cache.json` lookalike — providers sorted
  alphabetically, models filtered by provider, `provider(for:)` finds
  models both by full scan AND via `provider/model` slash-prefix
  fallback.
- Malformed + missing file paths return empty results, no crash.
- `ProjectDashboardService` round-trips a `ProjectRegistry` to disk and
  reads back a synthetic `.scarf/dashboard.json`.

**Rules next phases can rely on:**

- The `#if canImport(SQLite3)` gate pattern is established — any future
  ScarfCore code that touches SQLite3 directly should use the same
  whole-file or whole-block guard rather than trying to abstract SQLite
  behind a protocol (overkill; SQLite is reliably available on every
  target that can run Hermes client code).
- Services take `ServerContext` in their init and construct their own
  transport via `context.makeTransport()`. M0d ViewModels should follow
  the same convention when they move to ScarfCore.
- `LocalTransport()` (no-arg init) is the fast path for tests — uses
  `ServerContext.local.id`. Test helpers in ScarfCoreTests lean on this
  heavily.

### M0d — pending
### M1 — pending
### M2 — pending
### M3 — pending
### M4 — pending
### M5 — pending
### M6 — pending
