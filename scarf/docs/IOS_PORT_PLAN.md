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

### M0a — in progress
**Goal:** Create `Packages/ScarfCore` scaffolding and migrate the 13 leaf
Model files to it. `ServerContext.swift` stays in the Mac target (it
depends on Transport + HermesFileService and is not a leaf).

Expected artifacts when done:
- `Packages/ScarfCore/Package.swift` exists.
- 13 model files moved under `Sources/ScarfCore/Models/`.
- `HermesConstants.swift` split: portable parts (`sqliteTransient`,
  `QueryDefaults`, `FileSizeUnit`) move to ScarfCore; the deprecated
  `HermesPaths` enum stays behind (it references `ServerContext.local`).
- Every moved type annotated `public` with explicit `public init`.
- `scarf.xcodeproj/project.pbxproj` gains one `XCLocalSwiftPackageReference`
  for `Packages/ScarfCore` and one `XCSwiftPackageProductDependency` on the
  `scarf` target (and `scarfTests` + `scarfUITests` inherit via the target).
- 35 main-target files get `import ScarfCore` added.
- Mac app builds and runs identically to before.

(This section will be finalized when M0a is merged.)

### M0b — pending
### M0c — pending
### M0d — pending
### M1 — pending
### M2 — pending
### M3 — pending
### M4 — pending
### M5 — pending
### M6 — pending
