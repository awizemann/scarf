# Scarf Mobile — iOS build & setup

The iOS app target (`scarf mobile`) is already set up inside the
shared `scarf.xcodeproj`. This document records what was done so
future contributors understand the project layout; the step-by-step
target-creation instructions that used to live here are moot now
that the target exists.

## Layout

```
scarf/
  scarf.xcodeproj/             Single project, multiple targets:
                                 - scarf           (macOS app)
                                 - scarf mobile    (iOS app, Bundle com.scarf-mobile.app)
                                 - Mac + iOS test bundles
  Packages/
    ScarfCore/                 Local SPM — shared platform-neutral code
                                 (Models, Transport, Services, ViewModels,
                                 ACP state machine). Consumed by BOTH
                                 Mac and iOS targets.
    ScarfIOS/                  Local SPM — iOS-specific
                                 (CitadelSSHService, CitadelServerTransport,
                                 Keychain, UserDefaults-backed stores).
                                 Consumed by iOS target only.
  scarf/                       PBXFileSystemSynchronizedRootGroup for Mac
                                 target. Every .swift under this tree is
                                 auto-compiled into the Mac app.
  Scarf iOS/                   PBXFileSystemSynchronizedRootGroup for
                                 iOS target. Same auto-compile pattern.
    App/
      ScarfIOSApp.swift        @main entry point
    Onboarding/
      OnboardingRootView.swift
    Dashboard/
      DashboardView.swift
    Assets.xcassets/           App icon + Scarf-teal accent color
    Info.plist
    Scarf_iOS.entitlements
  Scarf iOSTests/              iOS unit tests (XCTest)
  Scarf iOSUITests/            iOS UI tests (XCTest)
```

## Target settings

As configured in `scarf.xcodeproj/project.pbxproj`:

- **Product name**: `scarf mobile`
- **Folder name** (on disk): `Scarf iOS`
- **Bundle ID**: `com.scarf-mobile.app`
- **Deployment target**: iOS 18.0, iPhone-only
- **Team**: `3Q6X2L86C4` (shared with the Mac target)
- **Swift language version**: Swift 5 (matches Mac + both SPM packages)

The product / folder naming mismatch is cosmetic — Xcode's
`PBXFileSystemSynchronizedRootGroup` decouples the two cleanly.

## SPM dependencies

Both local packages are wired into the iOS target in the pbxproj:

- `ScarfCore` (local package at `Packages/ScarfCore`) → shared with Mac.
- `ScarfIOS` (local package at `Packages/ScarfIOS`) → iOS-only; pulls
  `Citadel 0.12.x` transitively.

On first open Xcode will resolve Citadel from GitHub (~30s-1min).
Delete DerivedData + **File → Packages → Reset Package Caches** if
it stalls.

## Build + run

1. Open `scarf/scarf.xcodeproj`.
2. Scheme picker top-left → select **scarf mobile**.
3. Destination → any iPhone simulator on iOS 18+.
4. ⌘R. Expect onboarding → dashboard flow.

Switch back to the Mac target with the scheme picker.

## Smoke test — end-to-end against a real Hermes host

1. Pick a host you own with a Hermes install at `~/.hermes/`.
2. Run the iOS app on a simulator or physical device.
3. Onboarding: enter the host, generate a new Ed25519 key, tap
   **Copy** on the public-key screen, paste that line into
   `~/.ssh/authorized_keys` on the remote, tap **I've added this key**.
4. If auth succeeds → **Connected** → Dashboard.
5. Dashboard should populate session stats + recent sessions within
   a second or two (first load does a Citadel SSH handshake + SFTP
   snapshot of `state.db`; subsequent refreshes reuse the same SSH
   session).

## Info.plist / entitlements

Current iOS target is configured with:

- `UIBackgroundModes: remote-notification` (in Info.plist)
- `aps-environment: development` (in Scarf_iOS.entitlements)
- `com.apple.developer.icloud-services: [CloudKit]` (in entitlements)

These are Xcode's defaults from "Storage: CloudKit" + APNs-capable.
M2–M4 don't use any of them — no APNs in v1 per the plan, no
CloudKit at all. Leaving them in place for now since they're a
no-op; strip during M6 polish if App Store Review flags anything.

## Test targets

`Scarf iOSTests/Scarf_iOSTests.swift` and
`Scarf iOSUITests/Scarf_iOSUITests*.swift` are Xcode-scaffolded
placeholders. Real iOS behavioural coverage lives in:

- `Packages/ScarfCore/Tests/ScarfCoreTests/` — 96+ tests, all
  runnable on Linux CI via `docker run --rm -v
  $PWD/Packages/ScarfCore:/work -w /work swift:6.0 swift test`.
- `Packages/ScarfIOS/Tests/ScarfIOSTests/` — Apple-only smoke tests
  (Ed25519 keygen + OpenSSH wire format).

## TestFlight upload

1. Scheme: **scarf mobile**. Destination: **Any iOS Device (arm64)**
   or a physical iPhone.
2. **Product → Archive**.
3. **Window → Organizer → Distribute App → App Store Connect →
   Upload**.
4. First upload creates the App Store Connect app record with
   Bundle ID `com.scarf-mobile.app` under team `3Q6X2L86C4`.
5. Invite testers.

No network-usage `Info.plist` key needed — Citadel uses SwiftNIO
sockets, not Apple's local-network discovery.

## Milestone coverage

- **M0–M1**: ScarfCore extraction + `ACPChannel` protocol + decoupled
  `ACPClient`. All Mac-only code; iOS target didn't exist yet.
- **M2**: Onboarding + SSH key generate/import + Keychain storage +
  Citadel-backed "Test Connection" + Dashboard placeholder.
- **M3**: Real iOS `CitadelServerTransport` + live Dashboard data.
- **M4** *(in progress)*: iOS Chat via an `SSHExecACPChannel` built
  on Citadel's raw exec channel. Plugs into `ACPClient.ChannelFactory`
  (defined in M1), same JSON-RPC state machine as Mac.
- **M5**: Memory editor, Cron, Skills, Settings on iOS.
- **M6**: Polish, App Store submission.

## Troubleshooting

**Citadel fails to resolve.** Delete DerivedData
(`~/Library/Developer/Xcode/DerivedData/scarf-*`) then **File →
Packages → Reset Package Caches**; rebuild.

**`Cannot find 'Process' in scope` when building scarf mobile.**
`ServerTransport.makeProcess` is guarded with `#if !os(iOS)` as of
M3. If this appears, grep the iOS target's membership for a stray
file referencing `Process()` directly.

**`SSHAuthenticationMethod` has no member `ed25519`.** Shouldn't
happen against Citadel 0.12.x (verified against 0.12.1 source).
If you bump the pin to 0.13+, check the current
`Sources/Citadel/SSHAuthenticationMethod.swift` — one line to update
in `ScarfIOS/CitadelSSHService.buildClientSettings(...)`.

**Dashboard says "Couldn't read the Hermes database".** Expected on
fresh Hermes installs where `~/.hermes/state.db` doesn't exist.
Start a Hermes session on the host first, then pull-to-refresh.

**Slow first-connect (10+ seconds).** Citadel's SSH handshake +
SFTP open is the critical path. If it's consistently that slow,
check that plain `ssh` works to the same host from a terminal with
the same key; sometimes the issue is a restricted login shell that
won't let `sqlite3` run.

**Keychain blank after relaunch.** Verify `kSecAttrAccessible` is
`AfterFirstUnlockThisDeviceOnly` (the default). Biometric-required
accessibility values would block startup reads from background tasks.

**Exported public key doesn't match what `ssh-keygen -y` produces
from the stored private.** Correct — the **public** half is standard
OpenSSH wire format (interop-safe with `authorized_keys`); the
**private** half uses a Scarf-internal compact PEM (see
`Packages/ScarfIOS/Sources/ScarfIOS/Ed25519KeyGenerator.swift`).
Export to `~/.ssh/id_ed25519` format is planned for a future phase.
