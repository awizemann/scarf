# ScarfGo & Scarf — Privacy Policy

_Last updated: 2026-04-25._

## Plain summary

Scarf and ScarfGo are companion clients for the open-source [Hermes AI agent](https://github.com/awizemann/hermes-agent). Both apps connect from your device to a Hermes host you (or your team) operate. **Neither app collects, transmits, or stores your data on any server controlled by the developer.** All data the apps work with stays on your device or on Hermes hosts you configured yourself.

## Apps covered

- **Scarf** — macOS desktop client. Distributed via direct download (Sparkle) and built-in auto-update.
- **ScarfGo** — iOS companion. Distributed via TestFlight (and, in future, the App Store).

## What data the apps access

### On your device

- **SSH credentials.** ScarfGo generates and stores an SSH private key in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never iCloud-synced). Used solely to authenticate with Hermes hosts you configure. Scarf reads SSH keys from `~/.ssh/` like any other SSH client.
- **Server configuration.** Host, user, port, nickname, and an optional remote `~/.hermes` path. Stored in `UserDefaults` (ScarfGo) or the standard app container (Scarf). Never transmitted off-device except as the destination address of your own SSH connections.
- **Hermes state cache.** When you tap a session or open the Dashboard, the app downloads a snapshot of `~/.hermes/state.db` from your Hermes host over SFTP and reads it locally. Cached on-device temporarily for performance; cleared when the app is force-quit or the OS reclaims storage.
- **Project registry + session attribution sidecar.** Scarf and ScarfGo read (and write, when you opt in) two JSON sidecar files on the Hermes host: `~/.hermes/scarf/projects.json` and `~/.hermes/scarf/session_project_map.json`. These describe the projects you've registered and which Hermes sessions belong to which project. Owned by you on your Hermes host.

### On Hermes hosts you configure

Same as the [Hermes agent privacy policy](https://hermes-agent.nousresearch.com/) (or whoever operates your Hermes deployment). The apps do not introduce any new server-side data collection.

## What data the apps DO NOT collect

- **No analytics.** No event tracking, no crash analytics, no performance metrics sent to any third party. Crash logs stay on-device unless you choose to share them with Apple via the standard iOS / macOS reporting flows.
- **No telemetry.** No "improve our product" beacons, no version-pinging, no install counters.
- **No ads or ad identifiers.** The `IDFA` / `IDFV` are not read or transmitted.
- **No cloud accounts.** There's no "Sign in with Scarf" — the apps only know about Hermes hosts you give them SSH access to.
- **No iCloud Keychain sync.** SSH keys are explicitly marked `ThisDeviceOnly` so they don't propagate.

## Network connections the apps make

- **SSH connections** to Hermes hosts you configured (port 22 by default; user-configurable). All Hermes data flows over these.
- **HTTPS to GitHub** for Sparkle's update check (Scarf only) and to fetch the public template catalog (`https://awizemann.github.io/scarf/templates/`). No personally identifying headers; cacheable.
- **HTTPS to models.dev** when Hermes refreshes its model catalog cache. Initiated by Hermes, not the apps directly.

That's the complete list. The apps make no other network requests.

## Push notifications

ScarfGo includes a push-notification skeleton for future use — pending permissions on a remote agent run. **The Push Notifications capability is disabled in shipping builds** (gated by an internal `apnsEnabled = false` flag) until Apple Developer Program enrollment + a Hermes-side push sender land. No device tokens are registered with Apple's APNs servers in current builds.

When push lands, only the device token will be transmitted, and only to the Hermes host you authorize (so it can address pushes back to your phone). Apple's APNs infrastructure will route the actual push payload, but the developer never sees it.

## TestFlight beta program

If you join the ScarfGo beta via TestFlight, Apple shares anonymized crash reports + the email you used to redeem the invite with the developer. Apple's standard [TestFlight terms](https://www.apple.com/legal/internet-services/itunes/testflight/) apply to that data — out of scope for this policy.

## Security

- iOS Keychain storage uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so credentials are unreachable while the device is locked and never synced to iCloud.
- SSH connections use the same protocol stack as `ssh(1)` — strict host-key verification on first connect, key-based auth (no passwords are sent over the wire), and Citadel's pure-Swift implementation on iOS.
- The macOS app is sandboxed where possible and notarized via Apple's standard Developer ID flow.

## Children's privacy

Neither app is directed at children under 13 and we do not knowingly collect any data from them.

## Your rights

Because we don't collect any data on developer-controlled servers, there is nothing for you to opt out of, request deletion of, or export. To remove all app-stored data from your device:

- **ScarfGo**: delete the app. iOS purges the Keychain group + app container.
- **Scarf**: delete the app and the `~/Library/Containers/com.scarf` directory (the app is sandboxed; this is the only on-disk data).

Your Hermes host's data (`~/.hermes/`) stays untouched — that's yours to manage.

## Contact

Questions, concerns, or notice of a security issue: [alan@wizemann.com](mailto:alan@wizemann.com).

## Changes

Material changes to this policy will be announced on the [Scarf wiki](https://github.com/awizemann/scarf/wiki) and recorded here with a new "Last updated" date. Beta testers will see a TestFlight build note when policy changes affect data handling.
