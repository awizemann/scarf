---
title: Privacy-Policy
type: note
permalink: scarf-wiki/privacy-policy
created: 2026-04-25
updated: 2026-05-29
---

# Privacy Policy

> **Canonical version:** [awizemann.github.io/scarf/privacy/](https://awizemann.github.io/scarf/privacy/)
>
> This wiki page mirrors the canonical policy at [`scarf/docs/PRIVACY_POLICY.md`](https://github.com/awizemann/scarf/blob/main/scarf/docs/PRIVACY_POLICY.md). The repo file is the source of truth; the wiki copy is updated alongside major releases.

_Last updated: 2026-08-20._

## Plain summary

Scarf and ScarfGo are companion clients for the open-source [Hermes AI agent](https://github.com/hermes-ai/hermes-agent). Both apps connect from your device to a Hermes host you (or your team) operate. **Your content — chats, sessions, files, credentials — never leaves your device or your Hermes hosts.** The macOS app additionally sends **anonymous usage statistics** to the developer to guide development; this is described below and can be switched off in Settings. **ScarfGo on iOS sends nothing.**

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

## Usage analytics (Scarf for macOS only)

Starting with v2.20, Scarf for macOS records anonymous product-usage events — for example "a chat session was started", "a settings field was changed", "the app reconnected after wake" — and sends them to the developer's analytics service (ScarfMon, at `api.swiftstats.co`, built on the open-source [swift-stats](https://github.com/awizemann/swift-stats) package).

**What an event contains.** An event name plus a small set of fixed-vocabulary properties (e.g. `mode: resume`, `source: menu_bar`) and bucketed counts or durations. Properties are drawn from closed lists in the app's source — they can never contain chat content, prompts, file paths, hostnames, server names, profile names, SSH keys, or any other free-form text from your environment.

**What identifies an event.** A random identifier generated fresh each time the app launches. There is no persistent user ID, no device ID, no account, and no way for the developer to link two launches to the same person or machine.

**Opting out.** Settings → Advanced → Usage Analytics. Turning it off stops all collection immediately and persists across updates. Analytics is enabled by default; the toggle is one click.

**What it is not.** No third-party ad or analytics SDKs, no ad identifiers, no crash-content upload (crash logs stay on-device unless you share them with Apple through the standard macOS flow), no reading of any Hermes data for analytics purposes.

**ScarfGo (iOS) collects nothing.** The iOS app contains no analytics recorder and makes no analytics network calls. Its App Store privacy label ("Data Not Collected") reflects this.

## What data the apps DO NOT collect

- **No content collection.** Nothing you type, read, or store in Hermes — chats, files, prompts, configs, credentials — is ever transmitted to the developer. The macOS usage analytics described above carry event names and fixed-vocabulary properties only.
- **No analytics on iOS.** ScarfGo sends no events of any kind. On macOS, analytics is anonymous, content-free, and can be disabled in Settings → Advanced.
- **No crash-content upload.** Crash logs stay on-device unless you choose to share them with Apple via the standard iOS / macOS reporting flows.
- **No ads or ad identifiers.** The `IDFA` / `IDFV` are not read or transmitted.
- **No cloud accounts.** There's no "Sign in with Scarf" — the apps only know about Hermes hosts you give them SSH access to.
- **No iCloud Keychain sync.** SSH keys are explicitly marked `ThisDeviceOnly` so they don't propagate.

## Network connections the apps make

- **SSH connections** to Hermes hosts you configured (port 22 by default; user-configurable). All Hermes data flows over these.
- **HTTPS to GitHub** for Sparkle's update check (Scarf only) and to fetch the public template catalog (`https://awizemann.github.io/scarf/templates/`). No personally identifying headers; cacheable.
- **HTTPS to models.dev** when Hermes refreshes its model catalog cache. Initiated by Hermes, not the apps directly.
- **HTTPS to `api.swiftstats.co`** (Scarf for macOS only, when usage analytics is enabled) carrying the anonymous usage events described above.

That's the complete list. ScarfGo makes no other network requests; Scarf makes no other network requests beyond the optional analytics endpoint above.

## Push notifications

ScarfGo includes a push-notification skeleton for future use — pending permissions on a remote agent run. **The Push Notifications capability is disabled in shipping builds** (gated by an internal `apnsEnabled = false` flag) until Apple Developer Program enrollment + a Hermes-side push sender land. No device tokens are registered with Apple's APNs servers in current builds.

When push lands, only the device token will be transmitted, and only to the Hermes host you authorize (so it can address pushes back to your phone). Apple's APNs infrastructure will route the actual push payload, but the developer never sees it.

## TestFlight beta program

If you join the ScarfGo beta via TestFlight, Apple shares anonymized crash reports + the email you used to redeem the invite with the developer. Apple's standard [TestFlight terms](https://www.apple.com/legal/internet-services/itunes/testflight/) apply to that data — out of scope for this policy.

## Security

- iOS Keychain storage uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so credentials are unreachable while the device is locked and never synced to iCloud.
- SSH connections use the same protocol stack as `ssh(1)` — strict host-key verification on first connect, key-based auth (no passwords are sent over the wire), and Citadel's pure-Swift implementation on iOS.
- The macOS app is **notarized via Apple's standard Developer ID flow** (signed + stapled by `xcrun notarytool` on every release). It is **not App-Sandboxed** — Scarf needs direct read access to `~/.hermes/` and the ability to spawn the `hermes` CLI, both of which the App Sandbox forbids. This is why Scarf is distributed via GitHub Releases + Sparkle rather than the Mac App Store.
- ScarfGo on iOS runs inside the standard iOS app sandbox — no special entitlements beyond Keychain access for the SSH key.

## Children's privacy

Neither app is directed at children under 13 and we do not knowingly collect any data from them.

## Your rights

The only data that reaches a developer-controlled server is the anonymous macOS usage events described above. You can stop them at any time (Settings → Advanced → Usage Analytics). Because events carry no persistent identifier, the developer cannot isolate "your" events afterward — there is nothing linkable to request deletion of or export. To remove all app-stored data from your device:

- **ScarfGo**: delete the app. iOS purges the Keychain group + app container.
- **Scarf**: delete `Scarf.app` from `/Applications`, then optionally remove `~/Library/Caches/scarf/` (remote SQLite snapshots), `~/Library/Preferences/com.scarf.app.plist` (server registry + preferences), and `~/Library/Application Support/com.scarf/` (skill snapshots). See [Uninstalling](Uninstalling) for the full cleanup.

Your Hermes host's data (`~/.hermes/`) stays untouched — that's yours to manage.

## Contact

Questions, concerns, or notice of a security issue: [alan@wizemann.com](mailto:alan@wizemann.com).

## Changes

Material changes to this policy will be announced on the [Scarf wiki](https://github.com/awizemann/scarf/wiki) and recorded here with a new "Last updated" date. Beta testers will see a TestFlight build note when policy changes affect data handling.

## Related pages

- [Support](Support) — bug reports, feature requests, security disclosures.
- [ScarfGo Onboarding](ScarfGo-Onboarding) — how SSH keys are generated and stored.
- [Architecture Overview](Architecture-Overview) — what the apps actually do at a technical level.

---
_Last updated: 2026-08-20 — Scarf v2.20.0 (wiki mirror — canonical at [awizemann.github.io/scarf/privacy](https://awizemann.github.io/scarf/privacy/))_