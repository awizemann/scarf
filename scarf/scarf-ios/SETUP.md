# scarf-ios — Xcode target setup

This folder contains the source tree for the iOS app (`scarf-ios`), but
**not** the Xcode project file. Creating the `.xcodeproj` is a one-time
step you do in Xcode's UI — it's about 5 minutes, and doing it by hand
produces a project file that's definitely correct for whichever Xcode
version you're running, rather than a hand-edited pbxproj that might
drift from Xcode's expectations.

Everything the app needs — SSH key generation, Keychain storage,
onboarding state machine, Citadel-backed connection testing — already
lives in the shared SPM packages (`Packages/ScarfCore`,
`Packages/ScarfIOS`) and is exercised by 88 passing unit tests on
Linux CI. The Xcode target is mostly just a wrapper that assembles
those packages behind a `@main` SwiftUI app.

## One-time: create the Xcode target

1. Open **Xcode** → **File → New → Project…**
2. Choose **iOS → App**. Click Next.
3. Fill in:
   - **Product Name**: `scarf-ios`
   - **Team**: `3Q6X2L86C4` (the same team the Mac app uses for notarization)
   - **Organization Identifier**: `com.scarf`
   - **Interface**: **SwiftUI**
   - **Language**: **Swift**
   - **Storage**: **None** (no Core Data, no CloudKit)
   - **Include Tests**: unchecked (SPM covers them)
4. On the save-location sheet, navigate to `<repo>/scarf/` (the same
   level as `scarf.xcodeproj`) and hit **Create**.
5. Xcode produces `<repo>/scarf/scarf-ios/scarf-ios.xcodeproj` and a
   default source tree you'll immediately throw away.

## One-time: set project settings

In the **scarf-ios** project (target of the same name):

1. **General → Minimum Deployments → iPhone**: `iOS 18.0`.
2. **General → Supported Destinations**: keep **iPhone** only. Remove
   iPad + Mac Catalyst + Vision.
3. **Info → Bundle Identifier**: `com.scarf.scarf-ios`.
4. **Signing & Capabilities → Team**: `3Q6X2L86C4` (same as Mac).
5. **Build Settings → Swift Language Version**: `Swift 5` (matches
   the Mac app and both SPM packages).

## One-time: wire the SPM packages

1. **File → Add Package Dependencies…**
2. **Add Local…** button in the lower-left of the dialog.
3. Select `<repo>/scarf/Packages/ScarfCore`. Click **Add Package**.
4. Target to attach it to: **scarf-ios**. Click **Add Package**.
5. Repeat steps 1–4 for `<repo>/scarf/Packages/ScarfIOS`.
   - `ScarfIOS` already declares `Citadel` as a dependency — Xcode
     will resolve it automatically when you add the local package.
   - On first resolution expect a ~30s wait while Citadel +
     SwiftNIO-SSH fetch from GitHub.

## One-time: replace the default source tree

1. In Xcode's Project Navigator, delete the auto-generated files
   Xcode created for you:
   - `scarf_iosApp.swift` (or `scarf-iosApp.swift`)
   - `ContentView.swift`
   - `Assets.xcassets` (keep this one — we'll reuse)
2. In Finder, open `<repo>/scarf/scarf-ios/`. Drag the **App/**,
   **Onboarding/**, and **Dashboard/** folders onto the `scarf-ios`
   target in Xcode's navigator.
   - In the import sheet: **Create groups**, **Add to target:
     scarf-ios**.
3. Build (`⌘B`). It should compile cleanly. If Citadel's
   authentication-method variant has changed since I wrote
   `CitadelSSHService`, adjust `buildClientSettings(...)` — see the
   FIXME comment in that file.

## One-time: app icon + accent color

The `Assets.xcassets` that Xcode scaffolded already has a blank
`AppIcon` and `AccentColor`. Drop your icon asset + pick an accent
color in the Inspector. Nothing else to configure.

## Info.plist additions for M2

None required. Citadel uses SwiftNIO, which doesn't need the
network-usage `Info.plist` key unless you hit local-network
discovery — which onboarding doesn't.

If you want to publish to TestFlight in M2, add these under
**Info → Custom iOS Target Properties**:

- `LSRequiresIPhoneOS = YES` (defaults to YES, usually already set)
- `UIApplicationSceneManifest → UIApplicationSupportsMultipleScenes = NO`
  (single-window for iPhone)
- `UILaunchScreen` — empty dictionary is fine.

## Smoke test the target

1. Pick an iPhone simulator (any iPhone running iOS 18+) and hit ⌘R.
2. You should see the onboarding flow: **Remote host** form → **SSH
   key** choice → **Generate** → **Show public key** → …
3. On **Show public key**, the OpenSSH line is selectable and
   copy-able. The text renders as `ssh-ed25519 AAAA… scarf-iphone-XXXX`.
4. Tap **I've added this key**. Onboarding calls `CitadelSSHService`
   to connect. With no real server, this will fail with
   `.hostUnreachable` — that's expected. You should land on the
   **Connection failed** screen with a "Retry" button.
5. Real end-to-end test: use a host you actually own, copy the shown
   public key into its `~/.ssh/authorized_keys`, tap Retry. You
   should reach the **Connected** state and then the placeholder
   **Dashboard** with a Disconnect button.

## TestFlight (still M2 — optional)

1. **Product → Archive** (select a physical iPhone or "Any iOS
   Device (arm64)" as the target).
2. **Window → Organizer → Archives → Distribute App → App Store
   Connect → Upload**. Uses your existing team signing setup.
3. First upload will trigger App Store Connect to create the app
   record if it doesn't exist. Give it `com.scarf.scarf-ios` and
   the same team.
4. After processing, invite testers from App Store Connect.

## What's *not* in M2

- Dashboard data (sessions, messages, stats) — **M3** adds a
  Citadel-backed `ServerTransport` so `HermesDataService` and friends
  work over SSH from iOS.
- Chat — **M4** adds an `SSHExecACPChannel` (the iOS counterpart to
  `ProcessACPChannel`) so `ACPClient` runs over a Citadel exec
  session.
- Memory editing, Cron, Skills, Settings — **M5**.
- Polish, App Store submission — **M6**.

## Troubleshooting

**Citadel fails to resolve.** Delete derived data (`~/Library/Developer/Xcode/DerivedData/scarf-ios-*`)
and `File → Packages → Reset Package Caches`, then rebuild.

**`SSHAuthenticationMethod` has no member `ed25519`.** Citadel's
private-key auth has changed variant names between 0.7 and 0.9. See
`CitadelSSHService.buildClientSettings(...)` — there's one line to
update. Keep the protocol conformance intact.

**Keychain reads empty after relaunch.** Check that you haven't
accidentally set `kSecAttrAccessible` to a value that requires
biometric unlock — M2 uses `AfterFirstUnlockThisDeviceOnly` which
should always be readable.

**The shown public-key line doesn't match what OpenSSH generates
from the private key.** It won't — `scarf-ios` uses a compact
internal PEM shape for the private key (see `Ed25519KeyGenerator`
for the format). The **public** key is standard OpenSSH wire format
and is interop-safe with `authorized_keys`. If you want to export
the private key for use with `ssh`, that export flow is deferred
to a future phase.
