# scarf-ios — Xcode target setup

This folder contains the source tree for the iOS app (`scarf-ios`).
The Xcode target itself is added to the **existing `scarf.xcodeproj`**
as a second target alongside the Mac `scarf` target — **not** a
separate `.xcodeproj`. One project, two targets.

Everything the app needs — SSH key generation, Keychain storage,
onboarding state machine, Citadel-backed SSH client, SQLite-backed
Dashboard — already lives in the shared SPM packages
(`Packages/ScarfCore`, `Packages/ScarfIOS`) and is exercised by
96 passing unit tests on Linux CI. The iOS target is mostly just a
wrapper that assembles those packages behind a `@main` SwiftUI app.

Creating the target is a one-time ~5-minute step in Xcode's UI.

## One-time: add the iOS target to the existing project

1. Open `scarf/scarf.xcodeproj` in **Xcode**.
2. Select the project in the Project Navigator.
3. **File → New → Target…** (or use the `+` button at the bottom of
   the targets list).
4. Choose **iOS → App**. Click Next.
5. Fill in:
   - **Product Name**: `scarf-ios`
   - **Team**: `3Q6X2L86C4` (the same team the Mac target uses)
   - **Organization Identifier**: `com.scarf`
   - **Bundle Identifier** will be `com.scarf.scarf-ios`
   - **Interface**: **SwiftUI**
   - **Language**: **Swift**
   - **Storage**: **None**
   - **Include Tests**: unchecked (SPM covers them)
6. Click **Finish**. Xcode creates the target plus a default source
   tree under `scarf/scarf-ios/` (a folder you'll immediately throw
   away, since our real source lives there already).
7. If Xcode asks about "Activate scheme": **yes**.

## One-time: target settings

With the `scarf-ios` target selected in the project editor:

1. **General → Minimum Deployments → iPhone**: `iOS 18.0`.
2. **General → Supported Destinations**: keep **iPhone** only. Remove
   iPad + Mac Catalyst + Vision.
3. **Signing & Capabilities → Team**: `3Q6X2L86C4` (should have
   auto-filled from step 5 above).
4. **Build Settings → Swift Language Version**: `Swift 5` (matches
   the Mac target + both SPM packages).

## One-time: link the SPM packages to the iOS target

`ScarfCore` and `ScarfIOS` are already in the project's package
references (the Mac target already uses ScarfCore). You only need to
add them to the NEW iOS target.

1. Select the project in the navigator → select the `scarf-ios`
   target → **General → Frameworks, Libraries, and Embedded
   Content**.
2. Click the `+` button.
3. Select **ScarfCore** (library from ScarfCore local package). Add.
4. Click `+` again. Select **ScarfIOS**. Add.
5. Citadel is pulled in transitively by ScarfIOS — no need to add it
   explicitly. On first build Xcode resolves it from GitHub
   (~30s-1min).

## One-time: replace the default source tree

1. In Xcode's Project Navigator, find the `scarf-ios` group Xcode
   created. Delete:
   - `scarf_iosApp.swift` (or `scarf-iosApp.swift`)
   - `ContentView.swift`
   - **`Assets.xcassets`** — we ship our own pre-built one.
2. In Finder, open `<repo>/scarf/scarf-ios/`. Drag these four folders
   onto the `scarf-ios` group in Xcode:
   - `App/`
   - `Onboarding/`
   - `Dashboard/`
   - `Assets.xcassets/`
3. In the import sheet:
   - **Destination**: Copy items if needed — **unchecked** (they're
     already in place).
   - **Added folders**: **Create groups**.
   - **Add to targets**: **scarf-ios** only.
4. Build (`⌘B`). Should compile cleanly against Citadel 0.12.1 —
   every API call in `CitadelSSHService` + `CitadelServerTransport`
   was cross-checked against the 0.12.1 tag. If you've bumped the
   pin to 0.13+ and something fails, check
   `Sources/Citadel/SSHAuthenticationMethod.swift` for the current
   `.ed25519(username:privateKey:)` spelling.

## App icon + accent color

Already in `Assets.xcassets/` so you don't configure anything:

- **`AppIcon.appiconset/AppIcon-1024.png`** — the 1024×1024 Scarf
  icon copied from the Mac app's icon set. iOS 14+ renders all
  smaller sizes automatically from the single 1024 image.
- **`AccentColor.colorset`** — custom Scarf teal (sRGB `0.227 /
  0.525 / 0.722` light mode; `0.400 / 0.690 / 0.902` dark). Edit
  `Contents.json` or Xcode's color picker to change.

## Info.plist for TestFlight

Under the scarf-ios target → **Info → Custom iOS Target Properties**:

- `LSRequiresIPhoneOS = YES` (usually defaulted)
- `UIApplicationSceneManifest → UIApplicationSupportsMultipleScenes = NO`
  (iPhone single-window)
- `UILaunchScreen` — empty dictionary is fine

Citadel uses SwiftNIO, not Apple's local-network discovery, so no
network-usage-description key is needed.

## Smoke test

1. Switch the run destination to an iPhone simulator (any iPhone
   running iOS 18+). Xcode's target switcher lets you toggle between
   scarf (macOS) and scarf-ios.
2. ⌘R. Expect the onboarding flow:
   **Remote host** → **SSH key choice** → **Generate** → **Show
   public key** → **I've added this** → **Test connection** → ...
3. On **Show public key**, the OpenSSH line is selectable + copyable
   (`ssh-ed25519 AAAA… scarf-iphone-XXXX`).
4. Without a real SSH server, **Test connection** will fail with
   `.hostUnreachable` — that's expected. Land on the **Connection
   failed** screen with a **Retry** button.
5. Real end-to-end: use a host you own. Copy the shown public key
   into `~/.ssh/authorized_keys` on that host. Tap **Retry**. You
   should reach **Connected** → **Dashboard**, which then does a
   Citadel SFTP snapshot of `~/.hermes/state.db` and renders
   session + token stats.

## TestFlight upload

1. Scheme selector top-left → **scarf-ios**. Destination: **Any iOS
   Device (arm64)** or a physical iPhone.
2. **Product → Archive**.
3. **Window → Organizer → Archives → Distribute App → App Store
   Connect → Upload**.
4. First upload creates the App Store Connect app record with
   `com.scarf.scarf-ios`. Same team as the Mac app.
5. Invite testers from App Store Connect.

## What's in each milestone

- **M2** — Onboarding (SSH key + Keychain), Citadel-based
  "Test Connection", Dashboard placeholder.
- **M3** — Real Dashboard via `CitadelServerTransport` +
  `HermesDataService` (you're running the M3 PR now).
- **M4** — Chat over an iOS `SSHExecACPChannel`.
- **M5** — Memory editing, Cron, Skills, Settings.
- **M6** — Polish + App Store submission.

## Troubleshooting

**Citadel fails to resolve.** Delete DerivedData
(`~/Library/Developer/Xcode/DerivedData/scarf-*`) and **File →
Packages → Reset Package Caches**, then rebuild.

**`Cannot find 'Process' in scope` when building scarf-ios.** Should
not happen post-M3 — the `makeProcess` protocol method is now
`#if !os(iOS)`-guarded. If you see this: grep the scarf-ios target's
source files for `Process()`, `process.isRunning`, or `terminationHandler`
— something Mac-only leaked into the iOS target's membership.

**`SSHAuthenticationMethod` has no member `ed25519`.** Shouldn't happen
against Citadel 0.12.1 (verified), but historically the private-key
variant names have changed between minor versions (0.7 → 0.9 → 0.12).
See `CitadelSSHService.buildClientSettings(...)` in ScarfIOS — one
line to update. Keep the protocol conformance intact.

**Dashboard shows "Couldn't read the Hermes database".** Expected if
the host's `~/.hermes/state.db` doesn't exist yet (fresh Hermes
install). Start a Hermes session on the host first, then pull-to-
refresh.

**Dashboard spins forever on first connect.** Citadel connection
hand-shake + SFTP open can take 5-10s on a cold network. If it's
longer, check that the same SSH key works from a regular `ssh` client
against the same host — sometimes the issue is an authorized_keys
line with a trailing whitespace, or the host uses a restricted shell
that blocks `sqlite3`.

**Keychain reads empty after relaunch.** Check you haven't set
`kSecAttrAccessible` to a biometric-required value. We use
`AfterFirstUnlockThisDeviceOnly`, which is readable any time after
the first post-boot unlock.

**The public-key line doesn't match what `ssh-keygen` would produce
from the same private key.** The **public** key is standard OpenSSH
wire format (interop-safe with `authorized_keys`). The **private**
key uses a compact Scarf-internal PEM (see
`ScarfIOS/Ed25519KeyGenerator.swift`) — it's not directly exportable
to `~/.ssh/id_ed25519`. A future phase adds an export flow that
re-serializes to standard OpenSSH PEM.
