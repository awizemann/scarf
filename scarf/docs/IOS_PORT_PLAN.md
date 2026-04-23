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

### M0d — shipped

**Scope decision:** ViewModels only; **Views stay in the Mac target** for now. SwiftUI Views have heavy cross-feature coupling (AppCoordinator navigation, sidebar integration), AppKit-dependent widgets (NSOpenPanel, NSWorkspace.open for "reveal in Finder"), and platform-specific layout idioms that iPhone should re-implement rather than inherit. The Mac target will keep its current Views; M3+ builds fresh iOS Views on top of the shared ViewModels.

**Moved (6 ViewModels):**

- `ActivityViewModel.swift` — wraps `HermesDataService.fetchToolCalls`. Gated on `#if canImport(SQLite3)`.
- `ConnectionStatusViewModel.swift` — heartbeat for remote SSH health; `@MainActor @Observable`.
- `InsightsViewModel.swift` — aggregates over sessions via `HermesDataService`. Also exports `InsightsPeriod`, `ModelUsage`, `PlatformUsage`, `ToolUsage`, `NotableSession` and the free functions `formatDuration(_:)` / `formatTokens(_:)`. Gated on `#if canImport(SQLite3)`.
- `LogsViewModel.swift` — log tail + filter state (level, component, search). Uses only `HermesLogService`; no SQLite3 gate needed. Exposes `LogFile` and `LogComponent` nested enums with `#if canImport(Darwin)`-guarded `LocalizedStringResource` display names.
- `ProjectsViewModel.swift` — wraps `ProjectDashboardService`. Fully portable.
- `RichChatViewModel.swift` — ~700 lines of ACP-event + message-group handling. Gated on `#if canImport(SQLite3)` because it pulls message history from `HermesDataService`. Also exports `ChatDisplayMode` and `MessageGroup`.

**Reverted during M0d** (wasn't actually portable):

- `GatewayViewModel.swift` — my initial audit grepped for service-type names but missed that this VM calls `context.runHermes()`, which is a Mac-target-only extension (`ServerContext+Mac.swift`). Moving the extension would require dragging `HermesFileService` too. Left in the Mac target; a later phase can revisit once `HermesFileService` moves or a different CLI-invocation surface lands.

**Discovered while moving:**

- The sed transform needs a `s/^@Observable$/@Observable/` neutralization — earlier I was accidentally producing `@Observable public` which is a Swift syntax error (the stray `public` has no target). Post-fix, the `public` lives on the `public final class X` line as intended.
- Swift's `Observation` framework (for `@Observable`) needs an explicit `import Observation` in ScarfCore files because ScarfCore doesn't pull in SwiftUI. The Mac target gets `Observation` implicitly through SwiftUI, but a pure ScarfCore file doesn't. `Observation` is in the Swift toolchain from 5.9 onwards and compiles fine on Linux too.
- Nested enums inside a public enclosing type do **not** inherit `public` for their `Identifiable.id` requirement — that property has to be `public var id` explicitly when the enum declares `Identifiable` conformance. My sed didn't touch deeper indent levels (nested types at indent 4 inside a class at indent 0) so these had to be fixed by hand.
- `CharacterSet.whitespaces` is present in swift-corelibs-foundation on Linux — no guard needed there. The build error I saw was cascaded from `runHermes` not existing.

**Test coverage (`M0dViewModelsTests`):**

- `ConnectionStatusViewModel`: local context always-connected invariant; remote context idle-start; `Status` `Equatable`.
- `LogsViewModel`: init defaults, `filteredEntries` across level / search / component filters, nested enum `Identifiable` ids and `loggerPrefix` routing.
- `ProjectsViewModel`: init binding to `.local`.
- `ActivityViewModel`, `InsightsViewModel`, `RichChatViewModel`: construction + key initial state. Tests wrapped in `#if canImport(SQLite3)` so they only run on Apple-target CI.
- `MessageGroup.allMessages` / `toolCallCount` (also SQLite3-gated).
- `InsightsPeriod.sinceDate` ordering.
- `ChatDisplayMode` case coverage.

**Rules next phases can rely on:**

- When moving a file with `@Observable`, **remember to add `import Observation`** and to fix the stray `@Observable public` that sed produces.
- ViewModels that call `context.runHermes(...)` or `context.openInLocalEditor(...)` are **not** portable to ScarfCore — those methods live in `ServerContext+Mac.swift`. Either leave the VM in the Mac target, or add the specific extension method to ScarfCore with a platform-neutral implementation path.
- Types used only from the Mac app target (`GatewayInfo`, `PlatformInfo`, etc.) should NOT be marked `public` — keep them internal. My sed sometimes adds `public` to main-target-internal types when I'm reverting a move; strip those back with a second sed pass.
- Views are deliberately **not** in ScarfCore. iOS will build its own Views against the shared ViewModels. M3 is where iOS's ViewRegistry / tab bar / NavigationStack composition happens.

### M0 verification — shipped (commit `f399579`)

Two real regressions caught by a pre-M1 audit, both silent:

1. **`GatewayViewModel.swift` lost its `import ScarfCore`** during the M0d revert. It references `ServerContext` throughout — would not have compiled in Xcode without the import. Added back.
2. **`SSHTransport.sshSubprocessEnvironment()` regressed in M0b.** The original Mac code ran `HermesFileService.enrichedEnvironment()` which probes `zsh -l -i` first (sources `.zshrc` — where 1Password / Secretive / manual `ssh-add` export `SSH_AUTH_SOCK`), falling back to `zsh -l`. My M0b replacement used only `zsh -l`, so users with agents in `.zshrc` would have seen "Permission denied" (exit 255) on every remote SSH attempt. Fixed by **reverting to dependency injection**: `SSHTransport.environmentEnricher` is a `(@Sendable () -> [String: String])?` static wired at app startup to the Mac's full `HermesFileService.enrichedEnvironment()` — same exact code path as pre-M0b. iOS leaves it nil. Test pins the injection-point shape.

### M1 — shipped

**Shipped:**

- New `Packages/ScarfCore/Sources/ScarfCore/ACP/` directory with:
  - **`ACPChannel.swift`** — protocol + error enum. Line-oriented bidirectional transport that `ACPClient` speaks JSON-RPC over. Channel implementations own subprocess / SSH lifecycle; ACPClient never touches `Process`, `Pipe`, file descriptors, or SSH sessions directly.
  - **`ProcessACPChannel.swift`** — Mac/Linux impl, gated on `#if !os(iOS)` (iOS can't spawn subprocesses). Wraps the `Process` + `Pipe` + raw POSIX `write(2)` path that the old ACPClient used inline. Handles SIGPIPE-ignore, partial-write loops, EPIPE → `.writeEndClosed`, graceful SIGINT shutdown with a 2s SIGKILL watchdog. Available on both `Darwin` (macOS) and `Glibc` (Linux CI) via per-platform `#if canImport` on the raw write.
  - **`ACPClient.swift`** — moved from the Mac target and refactored to be channel-agnostic. `Process`/`Pipe`/`stdinFd`/`Darwin.write` state replaced with a single `channel: any ACPChannel` reference. Channel creation goes through a caller-provided `ChannelFactory` closure so Mac can wire `ProcessACPChannel` and iOS can (in M4+) wire a Citadel-backed `SSHExecACPChannel` the same way.
- **`scarf/Core/Services/ACPClient+Mac.swift`** (new Mac-target sibling file) — carries the `ACPClient.forMacApp(context:)` factory that constructs an `ACPClient` pre-wired with the Mac channel factory. The channel factory closure:
  - Local: spawns `hermes acp` with `HermesFileService.enrichedEnvironment()` (full PATH + credentials) minus `TERM`.
  - Remote: uses `SSHTransport.makeProcess` to get `ssh -T host -- hermes acp`, merging just `SSH_AUTH_SOCK` / `SSH_AGENT_PID` into the local ssh subprocess's env.
  - Both paths identical to pre-M1 behavior — no behavior change.
- **`ChatViewModel`** call sites updated from `ACPClient(context:)` to `ACPClient.forMacApp(context:)` (3 sites).
- The old `scarf/Core/Services/ACPClient.swift` (605 lines) deleted.

**Public API changes ACPClient callers need to know about:**

- `respondToPermission(requestId:optionId:)` is now `async`. `ChatViewModel` already awaited it, so the upgrade is a no-op there.

**Test coverage (`M1ACPTests`):** 10 new tests using a `MockACPChannel` actor to script JSON-RPC deterministically — no real subprocess or SSH, so the tests exercise the state machine alone:

- `ACPChannel` protocol — mock basic send/receive, write-after-close fails with `.writeEndClosed`, error-description strings.
- `ACPClient` initial state (disconnected, unhealthy).
- `start()` happy path — sends `initialize`, flips `isConnected` on reply.
- `start()` with an RPC error reply — surfaces as `ACPClientError.rpcError`.
- Mid-flight channel close — pending request resolves with `.processTerminated`, `isConnected` flips false.
- `session/update` notification routes into the `events` stream as `.messageChunk`.
- Stderr lines feed `recentStderr` ring buffer.
- `ACPErrorHint.classify` across credential / missing-binary / rate-limit / unknown cases.

**Rules next phases can rely on:**

- **iOS M2–M4:** The iOS target will provide a sibling `ACPClient+iOS.swift` with its own `ACPClient.forIOS(context:session:)` factory that returns a Citadel-backed `SSHExecACPChannel`. Everything above that layer — session lifecycle, event routing, permission requests, keepalive, recentStderr, token counting — runs unchanged.
- **ProcessACPChannel is test-less on Linux** (spawning real subprocesses in CI is brittle). Every meaningful ACP test uses `MockACPChannel` via protocol dependency injection. If you need to exercise the real subprocess path, do it on the Mac smoke-test side.
- **The `ChannelFactory` closure is `@Sendable` and async.** Any per-context setup (env enrichment, SSH handshake) happens inside the factory — not inside `ACPClient.start()`. That keeps `start()` boring and portable.
- **`ACPClient` does not handle subprocess spontaneous exits via `terminationHandler`** anymore — it notices via channel-stream EOF. Pipe-EOF fires reliably when a Mac subprocess exits (OS closes the pipe). If a future phase sees "session hangs after crash" symptoms, add a `terminationHandler` inside `ProcessACPChannel` that explicitly finishes the `incoming` continuation.

### M2 — shipped (on `claude/ios-m2-skeleton` branch, separate PR from M0+M1)

**Scope note:** M2 delivers all the **code** needed for TestFlight
(onboarding, Keychain, Citadel, Dashboard placeholder, unit tests) but
**not** the `scarf-ios.xcodeproj`. Hand-editing ~600 lines of pbxproj
from scratch is too high-risk without an iOS SDK to build against, so
the Xcode target is created once in Xcode's UI following the written
instructions in `scarf/scarf-ios/SETUP.md`. Total setup time: ~5
minutes.

**Shipped — ScarfCore additions (testable on Linux):**

- `Security/SSHKey.swift` — `SSHKeyBundle` struct, `SSHKeyStore`
  protocol, `InMemorySSHKeyStore` test actor.
- `Security/IOSServerConfig.swift` — `IOSServerConfig` struct
  (single-server v1), `IOSServerConfigStore` protocol,
  `InMemoryIOSServerConfigStore`. `toServerContext(id:)` bridges to
  the existing `ServerContext` type so the rest of ScarfCore's
  services work against an iOS-configured server unchanged.
- `Security/OnboardingState.swift` — `OnboardingStep` enum,
  `OnboardingKeyChoice`, `OnboardingServerDetailsValidation`, pure
  functions `OnboardingLogic.validateServerDetails` /
  `authorizedKeysLine(for:)` / `isLikelyValidOpenSSHPrivateKey` /
  `parseOpenSSHPublicKeyLine`.
- `Security/SSHConnectionTester.swift` — protocol +
  `SSHConnectionTestError` enum + `MockSSHConnectionTester`.
- `Security/OnboardingViewModel.swift` — `@Observable @MainActor`
  state machine. Dependency-injects `SSHKeyStore`,
  `IOSServerConfigStore`, `SSHConnectionTester`, and a `KeyGenerator`
  closure so every transition is testable with mocks.

**Shipped — new `Packages/ScarfIOS` local SPM package:**

- Depends on local ScarfCore + remote Citadel
  (`.upToNextMinor(from: "0.12.0")` — tight pin because Citadel's
  pre-1.0 authentication-method variant names have changed between
  minors; explicit bump → review → smoke-test is the flow).
- `KeychainSSHKeyStore.swift` — real iOS Keychain impl
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync).
- `UserDefaultsIOSServerConfigStore.swift` — JSON in UserDefaults.
- `Ed25519KeyGenerator.swift` — mints fresh Ed25519 keypairs via
  CryptoKit, emits standard OpenSSH public-key lines, stores the
  private half in a compact custom PEM that
  `CitadelSSHService` decodes back into
  `Curve25519.Signing.PrivateKey`.
- `CitadelSSHService.swift` — `SSHConnectionTester` conformance +
  key-generation wrapper. Runs a one-shot SSH exec (`echo scarf-ok`)
  for the onboarding probe. Every Citadel API call in the file was
  cross-checked against the `0.12.1` tag (SSHAuthenticationMethod.
  ed25519, SSHClientSettings init, SSHHostKeyValidator.acceptAnything,
  SSHClient.connect, executeCommand, close) — should build clean on
  first try.

**Shipped — `scarf/scarf-ios/` iOS app source tree:**

- `App/ScarfIOSApp.swift` — `@main` + `RootModel` routing to
  onboarding / dashboard based on stored state.
- `Onboarding/OnboardingRootView.swift` — 8 sub-views, one per
  `OnboardingStep`. Validated server-details form, key-source
  picker, generate / show / import / test / retry / connected.
- `Dashboard/DashboardView.swift` — M2 placeholder: connected
  server details + Disconnect. M3 replaces with real data.

**Shipped — `scarf/scarf-ios/SETUP.md`:**

Step-by-step Xcode project creation + troubleshooting. Alan runs
this once on a Mac (~5 minutes).

**Test coverage:**

- **ScarfCore (Linux):** 26 new tests covering key-bundle memberwise,
  both in-memory stores, config-to-ServerContext bridging, all
  `OnboardingLogic` validators (empty / whitespace / port range /
  legacy-RSA rejection), mock tester, and 10 end-to-end
  `OnboardingViewModel` paths (happy, bad import,
  connection-failure → retry-success, reset).
- **ScarfIOS (Apple-only):** 3 smoke tests for the Ed25519 generator,
  OpenSSH public-key wire format (byte-length pinned at 51), and
  corrupted-PEM rejection on round-trip decode.

Total: **88 passing on Linux** (62 pre-M2 + 26 new). Apple CI adds
the 3 ScarfIOS tests.

**Manual validation needed on Mac:**

1. Xcode project creation per SETUP.md. The `Assets.xcassets/` is
   pre-built (1024×1024 icon copied from the Mac app's set;
   Scarf-teal AccentColor with light + dark variants) so the target
   should ship with a real icon on first archive.
2. Onboarding end-to-end: simulator → physical iPhone via TestFlight
   → real SSH host with the public key added to `authorized_keys`.
   Citadel 0.12.1 APIs were verified in source; no expected Citadel
   drift.

**Rules next phases can rely on:**

- **M3** adds a Citadel-backed `ServerTransport` in ScarfIOS; iOS
  `IOSServerConfig.toServerContext(...).makeTransport()` dispatches to
  it automatically.
- **M4** adds `SSHExecACPChannel` in ScarfIOS; iOS wires the
  `ACPClient.ChannelFactory` hook (from M1) to produce it — sibling
  to Mac's `ACPClient+Mac.swift`.
- iOS is single-server in v1 — don't prematurely generalize the
  onboarding flow.
- Source tree stays **pure SwiftUI + Foundation + ScarfCore + ScarfIOS**;
  `#if canImport(UIKit)` fine for pasteboard but keep it minimal.

### M3 — shipped (on `claude/ios-m3-transport` branch, separate PR, stacked on M2)

**Three things this phase ships:**

1. **Critical iOS-compile fix** — `ServerTransport.makeProcess(...) -> Process` was iOS-unavailable at compile time but my Linux CI didn't catch it (swift-corelibs-foundation has `Process`; Apple iOS does not). Wrapped `makeProcess` in `#if !os(iOS)` on the protocol + both `LocalTransport` / `SSHTransport` impls. Without this fix, Alan's first `⌘B` on the M2 iOS target would have failed with "Cannot find 'Process' in scope".

2. **New platform-neutral `streamLines(...)` on the protocol** — `AsyncThrowingStream<String, Error>` emitting one stdout line per element, newline-framed, stream finishes on EOF and throws `TransportError.commandFailed` on non-zero exit. Mac/Linux use a `Process` + `Pipe` internally; iOS (Citadel) returns an empty stream for M3 and gets a real impl in M4+.

3. **`CitadelServerTransport`** (new, in ScarfIOS) — full `ServerTransport` conformance backed by Citadel SFTP + exec. Every iOS dashboard / file / process primitive now routes through this.

**Shipped — ScarfCore changes:**

- `Transport/ServerTransport.swift`: `makeProcess` guarded with `#if !os(iOS)`; new `streamLines(_:args:)` method on the protocol. Comment updated to call out the platform gate explicitly.
- `Transport/LocalTransport.swift`: matching `#if !os(iOS)` around `makeProcess`; full `streamLines` impl on Mac/Linux (Task.detached → Process + Pipe → line-framing loop → exit-code check); iOS stub returns an empty stream.
- `Transport/SSHTransport.swift`: same pattern for `makeProcess`; `streamLines` impl on Mac/Linux spawns `ssh -T host -- sh -c '<cmd>'` and pumps stdout line-by-line (identical to the old inline code in HermesLogService.openLog).
- `Services/HermesLogService.swift`: refactored remote-tail path to use `transport.streamLines(...)` instead of `transport.makeProcess` + raw `Pipe`. The `remoteTailProcess: Process?` / `fileHandle: FileHandle?` state collapses into a single `remoteTailTask: Task<Void, Never>?`. Parsed-line ring buffer is drained synchronously by `readNewLines()` — semantically identical to the old behaviour on Mac, and now works on iOS (where it'll get real streaming once `CitadelServerTransport.streamLines` is wired in M4+).
- `Models/ServerContext.swift`: new `ServerContext.sshTransportFactory: SSHTransportFactory?` static. When non-nil, `makeTransport()` routes `.ssh` contexts through this factory instead of constructing `SSHTransport` directly. iOS wires it; Mac leaves nil.
- `Services/HermesDataService.swift`: `SessionStats` member fields + `.empty` static promoted to `public` (sed missed them — nested inside the outer type). `lastOpenError` accessor promoted to `public private(set)`.

**Shipped — new in ScarfIOS:**

- `CitadelServerTransport.swift` — full `ServerTransport` impl backed by Citadel. Uses `SSHClient.openSFTP()` for file I/O, `SSHClient.executeCommand(_:)` for `runProcess`, and a remote `sqlite3 .backup` + SFTP-download for `snapshotSQLite`. Maintains a single long-lived SSH + SFTP connection per transport instance (lazy, reconnecting) via a nested `ConnectionHolder` actor. Blocks the caller thread via `DispatchSemaphore` to bridge the async Citadel API to `ServerTransport`'s synchronous protocol — same pattern the Mac `SSHTransport` uses to block on subprocess lifecycle. `streamLines(...)` returns an empty stream for M3 (iOS log tailing is M4+).
- `IOSDashboardViewModel.swift` — minimal iOS Dashboard view model. Unlike Mac's `DashboardViewModel` which uses `HermesFileService` (still Mac-target), iOS's version reads only from `HermesDataService`. Shows session count, token totals, recent sessions. `lastError` is surfaced in a banner with a Retry button.

**Shipped — scarf-ios app changes:**

- `App/ScarfIOSApp.swift`: `init()` now wires `ServerContext.sshTransportFactory = { ... CitadelServerTransport(keyProvider: { KeychainSSHKeyStore().load() }) }`. The key is re-read from the Keychain per connection (honors the Keychain's access-control policy — `AfterFirstUnlockThisDeviceOnly`).
- `Dashboard/DashboardView.swift`: replaces the M2 placeholder with a real list view showing session stats, token usage, and the most recent sessions. Pull-to-refresh triggers `vm.refresh()`. Loading state + error banner.

**Test coverage (M3TransportTests, 8 new tests, `@Suite(.serialized)`):**

- `LocalTransport.streamLines` yields one line per newline from a scripted `printf`.
- `streamLines` finishes on EOF even without a trailing newline (partial tail dropped — documented behaviour).
- Non-zero subprocess exit surfaces as `TransportError.commandFailed` with the correct exit code.
- `ServerContext.sshTransportFactory` override is consulted for `.ssh` contexts + ignored for `.local`.
- Nil factory falls back to default `SSHTransport`.
- `HermesLogService` remote tail pumps scripted `streamLines` output through to `readNewLines()`'s ring buffer.
- `HermesLogService.readLastLines` uses the transport's `runProcess` for the one-shot initial load.

**Real bug caught in development:** first pass of the M3 test suite had two tests that both set `ServerContext.sshTransportFactory` + restored in `defer`. Swift-testing runs tests in parallel by default — they raced, one test's scripted transport bled into the other, producing "entries[2].message is 'z' not 'boom'". Fixed with `@Suite(.serialized)` + a note explaining why.

**Now 96 / 96 passing on Linux** (88 pre-M3 + 8 new).

**Manual validation needed on Mac (after M2 target exists):**

1. **iOS build with the new protocol guards.** Hit ⌘B on the iOS simulator target — should compile cleanly. If `Cannot find 'Process' in scope` still appears, search for any remaining unguarded `Process` reference (grep `Process\(\)` / `.isRunning` / `terminationHandler`).
2. **Dashboard end-to-end against a real Hermes host.** iPhone simulator with the public key in remote `authorized_keys`, connect through onboarding, land on Dashboard — it should fetch + show session stats via Citadel SFTP + exec. Pull-to-refresh should work.
3. **SQLite snapshot pulls.** Dashboard load triggers `HermesDataService.refresh()` → `CitadelServerTransport.snapshotSQLite(...)` → remote `sqlite3 .backup` + SFTP download to `<Caches>/scarf/snapshots/<id>/state.db`. Verify the local file appears and HermesDataService opens it read-only.

**Rules next phases can rely on:**

- **`streamLines` is the portable way to stream subprocess stdout.** Every future feature that needs line-by-line stdout (log tailing, `git` output, `ps`-style probes) should use `streamLines`. `makeProcess` is Mac/Linux-only by design.
- **`ServerContext.sshTransportFactory` is already wired on iOS.** M4 (ACP over Citadel) should reuse the same CitadelServerTransport via `context.makeTransport()` for its exec channel — don't build a parallel Citadel session management path.
- **`CitadelServerTransport.streamLines` is a stub (M3).** When the iOS Chat feature lands in M4+, implement it using Citadel's raw exec channel API (not `executeCommand`, which buffers the entire output). That'll also unlock iOS log tailing.
- **`HermesFileService` still hasn't moved to ScarfCore.** iOS's Dashboard is minimal because of this; no config.yaml / gateway-state / pgrep checks. A future phase can either port HermesFileService (requires iOS-compatible shell-env story) or replicate the narrow subset iOS needs.

### M4 — shipped (on `claude/ios-m4-chat` branch, separate PR, stacked on M3)

**What shipped:** iOS Chat via Citadel's 8-bit-safe SSH exec channel + the Xcode target reconciliation work (pulling Alan's target creation from `template-configuration` into the iOS-port stack, merging pbxproj with M3's ScarfCore wiring, consolidating source layout into `scarf/Scarf iOS/`, wiring ScarfIOS as a local SPM package).

**ScarfIOS additions:**
- `SSHExecACPChannel.swift` — iOS counterpart to `ProcessACPChannel`. Uses `SSHClient.withExec(_:perform:)` for bidirectional exec (RFC 4254), line-frames stdout / stderr, Cancel-driven teardown.
- `ACPClient+iOS.swift` — `ACPClient.forIOSApp(context:keyProvider:)` factory that opens a dedicated `SSHClient` per ACP session (separate from the transport's client so ACP's long channel doesn't multiplex-compete with SFTP). Shared ed25519 auth helper via the key bundle stored in Keychain.

**iOS Chat view:**
- `Scarf iOS/Chat/ChatView.swift` + `ChatController` (`@Observable @MainActor`). Three-state lifecycle (connecting / ready / failed), auto-scroll message list, SwiftUI composer, "+" toolbar for a fresh session. Reuses ScarfCore's `RichChatViewModel` unchanged.
- `DashboardView` gains a NavigationLink into Chat.
- `RichChatViewModel.sessionId` promoted `public private(set)` so `ChatController` can route `sendPrompt`.

**Xcode target reconciliation** (carried in the same PR — they can't easily be separated without breaking the build):
- Merged `b289a83`'s iOS-target pbxproj additions on top of my M3 pbxproj via `git merge-file` (zero conflicts, 658 → 1074 lines). Added ScarfIOS as a new `XCLocalSwiftPackageReference`, wired both ScarfCore + ScarfIOS to the `scarf mobile` target's `packageProductDependencies` + Frameworks build phase.
- Source layout: moved `scarf/scarf-ios/*` into `scarf/Scarf iOS/` (matching Xcode's synced group path). Deleted Xcode's scaffolded `ContentView.swift` / `Item.swift` / `Scarf_iOSApp.swift` defaults (my M2 code supersedes).
- `scarf/docs/iOS-SETUP.md` — rewrote as a project-layout reference + troubleshooting doc, dropping the "how to create the target" walkthrough now that the target exists.

**Tests:** 2 new in `M4ACPIOSTests`:
- Streaming prompt end-to-end: initialize handshake + session/new + two agent_message_chunk notifications + session/prompt response with usage tokens. Verify both chunks arrive as `.messageChunk` events, the prompt resolves with correct stopReason + input/output token counts.
- Permission-request round-trip: remote `session/request_permission` request → `.permissionRequest` event → `respondToPermission` writes a proper JSON response back on the channel.

**96 → 98 tests passing on Linux.**

**Manual validation still needed on Mac:**
1. iOS compile cleanly against the merged pbxproj.
2. Chat end-to-end: Dashboard → Chat → "hello" → streaming response from a real Hermes install.
3. Tool-call events visible (even without fancy cards — M5 polish).
4. No leaked SSH connections across Disconnect / re-onboard cycles.

**Rules next phases can rely on:**
- **Two separate `SSHClient`s per Scarf session** — one in `CitadelServerTransport` (SFTP + one-shot exec), one in `SSHExecACPChannel` (long-running ACP). Don't pool; OpenSSH caps concurrent channels per connection at ~10.
- **`ACPClient.forIOSApp`** is the iOS factory. Any future iOS feature that needs ACP uses it — don't construct `ACPClient` directly.
- **Chat is rich-chat-only on iOS in v1.** Terminal mode (embedded SwiftTerm) deferred.
- **Message markdown / tool-call cards / permission sheets** are M5 polish.

### M5 — shipped (on `claude/ios-m5-polish-writes` branch, separate PR, stacked on M4)

Chat polish + three new iOS feature surfaces — Memory (read + edit), Cron (read-only), Skills (read-only).

**Chat polish:**
- **Tool-call cards** — assistant messages with embedded `HermesToolCall`s now render each call as an expandable card (tapped → shows full JSON arguments). Tool-kind icon in the card header.
- **Tool-result row** — messages with `role == "tool"` render as a compact "Tool output" disclosure beneath the assistant bubble they flowed from. Keeps the transcript scannable while letting users drill in.
- **Permission sheet** — when the remote emits `session/request_permission`, a SwiftUI `.sheet(item:)` modal presents the title + kind + option buttons. Tapping an option dispatches `respondToPermission(requestId:optionId:)` through `ChatController` → `ACPClient`.
- **Markdown rendering** — assistant messages (only) go through `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)`. Bold/italic/code/links render; unknown constructs fall through as plain text.
- **Reasoning disclosure** — `HermesMessage.reasoning` (when present) renders as an "Thinking…" `DisclosureGroup` above the main bubble. Collapsed by default so chain-of-thought-heavy models don't dominate the scroll.

**New feature surfaces** (all in `scarf/Scarf iOS/` + ScarfCore ViewModels):
- **Memory** — `IOSMemoryViewModel` (ScarfCore) + `MemoryListView` / `MemoryEditorView`. Two rows: MEMORY.md and USER.md. TextEditor bound to `vm.text`; toolbar Save + Revert. "Saved" toast confirmation. VM uses `ServerContext.readText` / `writeText` — works through any transport.
- **Cron** — `IOSCronViewModel` + `CronListView` + `CronDetailView`. Read-only. Decodes `jobs.json` via `CronJobsFile` (Codable, from ScarfCore M0a). Sorted enabled-first, then by `nextRunAt`. Missing file = empty list (no error — common on fresh installs).
- **Skills** — `IOSSkillsViewModel` + `SkillsListView` + `SkillDetailView`. Read-only. Scans `~/.hermes/skills/<category>/<name>/` via `transport.listDirectory` + `stat` (no YAML frontmatter parsing — defer). Empty categories filtered. Dotfiles filtered.

**Supporting changes:**
- `RichChatViewModel.PendingPermission` fields promoted `public` — the iOS `PermissionSheet` needs to read `title` / `kind` / `options`.
- `LocalTransport.writeFile` refactored to use `Data.write(options: .atomic)` instead of `FileManager.replaceItemAt`. replaceItemAt is Apple-only (Linux swift-corelibs doesn't implement it fully), which broke the M5 tests on Linux CI. The atomic-write option is cross-platform and has identical semantics. No behavior change on Mac/iOS; auto-creates the parent dir if missing.
- Dashboard's single Chat-only Section became a **Surfaces** section with four `NavigationLink`s: Chat, Memory, Cron, Skills.

**Test coverage (`M5FeatureVMTests`, 10 new tests):**
- Memory: missing-file → empty state, full load+edit+save+reload round-trip, revert restores original, `Kind.path(on:)` routing.
- Cron: missing jobs.json → empty (no error), full-load sorts (enabled-first + next-run ascending + disabled-last), decode-error surfaces via `lastError`.
- Skills: missing skills dir → empty, directory scan extracts category/skill/files + filters dotfiles, empty categories excluded from list.
- `PendingPermission.init` pinned (SQLite3-gated).

Total **98 → 108 tests passing on Linux** via `docker run --rm -v $PWD/Packages/ScarfCore:/work -w /work swift:6.0 swift test`. All M5 tests use a `.serialized` suite + a `withLocalTransportFactory` helper so the shared `ServerContext.sshTransportFactory` static doesn't race.

**Manual validation needed on Mac:**
1. Xcode compile clean against M5 source additions.
2. Chat: trigger a tool call (e.g., ask "list files in ~") → verify the card renders + expands. Trigger a permission request (e.g., ask to write a file) → verify the sheet presents + responding dispatches correctly.
3. Markdown: ask for a bulleted list or bold/italic text → verify rendering.
4. Memory: edit MEMORY.md from phone → save → verify on remote filesystem via `cat ~/.hermes/memories/MEMORY.md`.
5. Cron: if you have existing cron jobs, verify they show up sorted correctly + the detail view is useful.
6. Skills: browse the list, tap a skill, verify the file list matches `ls ~/.hermes/skills/<cat>/<name>/`.

**Rules next phases can rely on:**
- **`IOSMemoryViewModel`, `IOSCronViewModel`, `IOSSkillsViewModel`** live in ScarfCore (not ScarfIOS) because they only use `ServerContext.readText` / `writeText` / `makeTransport` — no iOS-only APIs. Tests on Linux with `LocalTransport` are legitimate coverage.
- **`LocalTransport.writeFile` is atomic cross-platform** — services writing through it get POSIX rename-atomic semantics on every target. Don't reintroduce `replaceItemAt`.
- **Editing Cron, adding Skills** — both are deferred. Cron editing needs atomic JSON rewrites (doable). Skills install needs git-clone + schema validation (larger).
- **Settings tab on iOS is still missing** — requires a YAML parser in ScarfCore or porting `HermesFileService.loadConfig`. Next phase's job.

### M6 — shipped (on `claude/ios-m6-settings-polish` branch, separate PR, stacked on M5)

Ports the Mac app's YAML parser into ScarfCore (unblocking iOS Settings), adds Settings browsing + Cron editing, consolidates the test-serialization story. App Store submission is deferred to a later task after real-device testing.

**Shipped — ScarfCore:**

- `Parsing/HermesYAML.swift` — `HermesYAML.parseNestedYAML(_:)` + `stripYAMLQuotes(_:)`. Lifted verbatim from `HermesFileService.parseNestedYAML` / `stripYAMLQuotes` but hoisted into a standalone enum for reuse. Scope unchanged: indent-based block nesting, scalar values, bullet lists, nested maps. Not full YAML-spec compliance; matches exactly what Hermes's `config.yaml` actually uses.
- `Parsing/HermesConfig+YAML.swift` — `HermesConfig.init(yaml:)`. Lifted from `HermesFileService.parseConfig` one-for-one. Every default, every key, every legacy fallback (e.g., `platforms.slack.*` vs `slack.*`) tracked to the Mac implementation. Forgiving: malformed YAML produces a partial-state `HermesConfig` rather than throwing.
- `ViewModels/IOSSettingsViewModel.swift` — `@Observable @MainActor` VM. Reads `~/.hermes/config.yaml` via transport, parses with the new loader, surfaces both the parsed `HermesConfig` and the raw text (so Settings view can offer a "View source" disclosure). M6 Settings is READ-ONLY — edit-path deferred until a round-trip-preserving YAML writer lands (commits, key order, whitespace would need preservation for a clean edit UX).
- `ViewModels/IOSCronViewModel.swift` — added write paths: `toggleEnabled(id:)`, `delete(id:)`, `upsert(_:)`. All funnel through `saveJobs(_:)` which re-encodes the full `CronJobsFile` (`.prettyPrinted + .sortedKeys`) and writes atomically via the transport (Data.write-atomic semantics from M5). Creates the `cron/` directory on fresh installs.
- Both `HermesCronJob` and `CronJobsFile` gained real memberwise inits (previously only hand-written `init(from:)` — Swift's synthesis was suppressed). Also `HermesCronJob.withEnabled(_:)` — clean field-passthrough instead of the JSON-roundtrip hack my first draft used.

**Shipped — iOS app:**

- `Scarf iOS/Settings/SettingsView.swift` — read-only browser grouped into sections that mirror the Mac app's tabs: Model, Agent, Display, Terminal, Memory, Voice, Security, Compression, Logging, Platforms. `DisclosureGroup` at the bottom reveals the raw YAML source for diagnostics.
- `Scarf iOS/Cron/CronListView.swift` rewritten: toggle-enabled circle (tap to flip), swipe-to-delete, "+" toolbar for new-job, row-tap opens the editor sheet. New `CronEditorView` form handles name / prompt / enabled / schedule (kind + display + expression + run_at) / optional model / comma-separated skills / delivery route. Preserves runtime state fields (nextRunAt, lastRunAt, deliveryFailures, etc.) when editing — no resetting the cron's observed history on a field edit.
- Dashboard's Surfaces section gets a 5th row: Settings.

**Test-suite reorganization:**

Discovered (and fixed) a cross-suite race: swift-testing's `.serialized` trait scopes to one @Suite, not globally. M5's serialized suite installed `ServerContext.sshTransportFactory`, M6's serialized suite did the same, and the M0b non-serialized `serverContextMakeTransportDispatches` test asserted the DEFAULT factory (nil) returned `SSHTransport` — all three raced on the shared static.

Fix: keep the YAML-parse + memberwise tests in a plain (non-serialized) `M6ConfigCronTests` suite since they're pure. **Move every factory-touching test into the single `.serialized` `M5FeatureVMTests`** — including M6's Cron write-path tests, Settings-load tests, AND the M0b default-factory test (with explicit `factory = nil` reset for race-freedom). Single serialization domain eliminates the race.

**Test counts:** 108 → **134 passing on Linux**.

| Suite | New in M6 | Total |
|---|--:|--:|
| `ScarfCoreSmokeTests` | 0 | 1 |
| `M0aPublicInitTests` | 0 | 15 |
| `M0bTransportTests` | 0 (1 split out + moved) | 18 |
| `M0cServicesTests` | 0 | 8 |
| `M0dViewModelsTests` | 0 | 9 |
| `M1ACPTests` | 0 | 10 |
| `M2OnboardingTests` | 0 | 26 |
| `M3TransportTests` | 0 | 5 |
| `M4ACPIOSTests` | 0 | 2 |
| `M5FeatureVMTests` | **+7** (cron write paths + settings load + default-factory guard) | 21 |
| `M6ConfigCronTests` | **+19** (YAML parsing + HermesConfig decode + memberwise inits) | 19 |

**Manual validation needed on Mac:**
1. Xcode compile clean.
2. Settings → confirm every section populates from your real `config.yaml`. Tap the "View source" disclosure to verify the raw text matches what's on the remote.
3. Cron: toggle a job's enabled flag, verify it survives a full refresh + relaunch. Swipe-to-delete a job. Tap "+" to create a new job; verify prompt + schedule + skills round-trip. Tap an existing job to edit; verify runtime fields (lastRunAt, deliveryFailures) aren't reset.
4. Skills: unchanged from M5, still browse-only.

**Rules next phases can rely on:**
- **Any test that touches `ServerContext.sshTransportFactory` or any other global mutable state MUST live in `M5FeatureVMTests`** (the single `.serialized` suite) — or introduce a new cross-suite synchronization primitive. Swift-testing's `.serialized` does NOT serialize across suites.
- **YAML parser in ScarfCore is a hard ceiling** — it handles the Hermes config subset, not arbitrary YAML. If a future Hermes version adds constructs the parser doesn't cover (flow-style `[...]`, anchors, `&` references, multi-line `|` blocks), port them on both sides simultaneously.
- **Settings writes stay deferred** until a round-trip-preserving YAML writer ships. Options: (a) hand-write one, (b) adopt a YAML lib (adds dependency), (c) delegate to `hermes config set` via ACP.
- **Cron editing on iOS is atomic per-save** — full jobs.json rewrites on every change. Fine for current cron sizes (dozens of jobs). If that grows into the thousands, consider partial updates via `hermes cron add/rm/toggle` over ACP.
- **Skills install (git-clone + validation over SSH)** remains deferred — it's its own project. The iOS Skills list is read-only; users install from the Mac app or by cloning directly to the remote.

### M7 — pending (post-testing App Store submission + any polish that surfaces)
