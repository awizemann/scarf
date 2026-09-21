---
title: Privacy-Policy
type: note
permalink: scarf-wiki/privacy-policy
created: 2026-04-25
updated: 2026-09-19
---

# Privacy Policy

> **Canonical version:** [awizemann.github.io/scarf/privacy/](https://awizemann.github.io/scarf/privacy/)
>
> This wiki page mirrors the canonical policy at [`scarf/docs/PRIVACY_POLICY.md`](https://github.com/awizemann/scarf/blob/main/scarf/docs/PRIVACY_POLICY.md). The repo file is the source of truth; the wiki copy is updated alongside major releases.

_Last updated: 2026-08-20._

## Plain summary

Scarf and ScarfGo are companion clients for the open-source [Hermes AI agent](https://github.com/hermes-ai/hermes-agent). Both apps connect from your device to a Hermes host you (or your team) operate. **Your content — chats, sessions, files, credentials — never leaves your device or your Hermes hosts.** The macOS app additionally sends **anonymous usage statistics** to the developer to guide development; this is described below and can be switched off in Settings. **ScarfGo on iOS sends nothing to the developer.** One optional feature, **Live Voice**, sends your voice and recent chat messages directly from your device to OpenAI, and only after you start a session and agree once; see "Voice features" below.

## Apps covered

- **Scarf** — macOS desktop client. Distributed via direct download (Sparkle) and built-in auto-update.
- **ScarfGo** — iOS companion. Distributed via TestFlight (and, in future, the App Store).

## What data the apps access

### On your device

- **SSH credentials.** ScarfGo generates and stores an SSH private key in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never iCloud-synced). Used solely to authenticate with Hermes hosts you configure. Scarf reads SSH keys from `~/.ssh/` like any other SSH client.
- **Server configuration.** Host, user, port, nickname, and an optional remote `~/.hermes` path. Stored in `UserDefaults` (ScarfGo) or the standard app container (Scarf). Never transmitted off-device except as the destination address of your own SSH connections.
- **Hermes state cache.** When you tap a session or open the Dashboard, the app downloads a snapshot of `~/.hermes/state.db` from your Hermes host over SFTP and reads it locally. Cached on-device temporarily for performance; cleared when the app is force-quit or the OS reclaims storage.
- **Project registry + session attribution sidecar.** Scarf and ScarfGo read (and write, when you opt in) two JSON sidecar files on the Hermes host: `~/.hermes/scarf/projects.json` and `~/.hermes/scarf/session_project_map.json`. These describe the projects you've registered and which Hermes sessions belong to which project. Owned by you on your Hermes host.

### Voice features

Voice is off until you use it. Hermes Voice and Live Voice also appear only when your Hermes host's version supports them. Each feature keeps to a different boundary:

- **Dictation (ScarfGo).** Holding the composer's microphone button transcribes speech to text **on your iPhone only**, with Apple's on-device speech recognizer. Audio never leaves the phone and is never sent to a server. The transcript is inserted into the composer like typed text; nothing is sent until you tap send.
- **Hermes Voice playback (Scarf for macOS).** When you choose the Hermes playback engine (Settings → Voice), the app asks **your Hermes host** to turn an assistant reply into speech using the text-to-speech provider configured in that host's own `tts` settings, then downloads the audio and plays it. The reply text goes to whichever provider your host is configured to use (a local engine, or a third-party service such as OpenAI or ElevenLabs if you set one up in Hermes); Scarf does not choose the provider and never contacts it directly. Audio is cached on your Mac under `~/Library/Caches/scarf/tts` (capped, oldest first) and can be deleted at any time. Off by default; the alternative engine is the built-in macOS system voice, which stays on-device.
- **Voice conversation, chained mode (Scarf and ScarfGo).** With Hermes's default voice mode, a spoken conversation runs entirely between your device and your own Hermes host: your speech is turned into text **on your Mac or iPhone** by Apple's on-device recognizer (on-device only; the apps refuse to run if that isn't available rather than use Apple's servers), the words go to Hermes exactly like a typed message, and the reply is read aloud either by the host's text-to-speech provider (the same path as Hermes Voice playback above) or by the system voice on your device. No audio leaves the device, no third party is contacted by the apps, and nothing is billed. Available with Hermes 0.20.1 or later; the apps ask for Speech Recognition and Microphone permission the first time.
- **Live Voice (Scarf and ScarfGo).** A two-way spoken conversation built on Hermes's GPT-Live voice mode, which uses an OpenAI voice model. It runs only when your Hermes host is version 0.21.3 or later **and** you have set `voice.voice_chat_mode: gpt-live` on that host. When you start a session:
  - Your Hermes host creates the session with **your own OpenAI API key** (the one configured on the host). The key never leaves the host and is never shown to, stored by, or sent through the apps.
  - **Your microphone audio streams directly from your device to OpenAI** over an encrypted WebRTC connection, and OpenAI's spoken replies stream back the same way. Because the connection is direct, OpenAI also sees your device's network address. The audio does not pass through your Hermes host or any server operated by the developer.
  - Each session shares **recent messages from the current chat** with OpenAI as context: up to 24 messages, about 6,000 characters. Every request you make by voice is still answered by Hermes, with your usual model and tools; the voice model only relays it. The spoken request is saved in the Hermes session transcript like a typed message; the live audio and captions are not stored by the apps.
  - OpenAI bills the host's key while a session is open (roughly $0.05 per minute at the time of writing). Sessions end when you stop them, close the chat, switch servers or profiles, leave the app (ScarfGo), lose the Hermes connection, or after a period of silence.
  - **Consent.** Before the first session on a device, the app shows what is shared and with whom; nothing starts until you agree, and Cancel sends nothing. Your choice is stored on that device only (never on the host or in iCloud) and can be reviewed or reset in Settings → Voice (Scarf) or Settings → Live Voice Privacy (ScarfGo). If what is shared ever changes, the app asks again.
  - OpenAI's handling of the audio and context is governed by [OpenAI's privacy policy](https://openai.com/policies/privacy-policy) and the terms of the API account whose key the host uses.

Both apps request microphone permission the first time a voice feature needs it, and the permission text states which feature is asking. Microphone access is never used outside a dictation hold or a Live Voice session you started.

### On Hermes hosts you configure

Same as the [Hermes agent privacy policy](https://hermes-agent.nousresearch.com/) (or whoever operates your Hermes deployment). The apps do not introduce any new server-side data collection.

## Usage analytics (Scarf for macOS only)

Starting with v2.20, Scarf for macOS records anonymous product-usage events — for example "a chat session was started", "a settings field was changed", "the app reconnected after wake" — and sends them to the developer's analytics service (ScarfMon, at `api.swiftstats.co`, built on the open-source [swift-stats](https://github.com/awizemann/swift-stats) package).

**What an event contains.** An event name plus a small set of fixed-vocabulary properties (e.g. `mode: resume`, `source: menu_bar`) and bucketed counts or durations. Properties are drawn from closed lists in the app's source — they can never contain chat content, prompts, file paths, hostnames, server names, profile names, SSH keys, or any other free-form text from your environment.

**What identifies an event.** A random install identifier that the analytics library generates on your Mac and keeps in its own preferences. It is never sent as-is: each event carries only a salted SHA-256 hash of it, which lets the developer count active installs and see how many sessions an install has, but not who or which machine it is. There is no user ID, no hardware identifier, no account, and nothing that ties the identifier to your Hermes hosts or content. Turning analytics off stops sending it; deleting the app's preferences removes it.

**Opting out.** Settings → Advanced → Usage Analytics. Turning it off stops all collection immediately and persists across updates. Analytics is enabled by default; the toggle is one click.

**What it is not.** No third-party ad or analytics SDKs, no ad identifiers, no crash-content upload (crash logs stay on-device unless you share them with Apple through the standard macOS flow), no reading of any Hermes data for analytics purposes.

**ScarfGo (iOS) sends nothing to the developer.** The iOS app contains no analytics recorder and makes no analytics network calls. Live Voice (above) is the one iOS feature that sends data to a third party, and only to OpenAI, only while a session you started is open.

## What data the apps DO NOT collect

- **No content collection.** Nothing you type, say, read, or store in Hermes — chats, files, prompts, configs, credentials — is ever transmitted to the developer. The macOS usage analytics described above carry event names and fixed-vocabulary properties only. Live Voice audio and context go from your device to OpenAI, never to the developer.
- **No analytics on iOS.** ScarfGo sends no events of any kind. On macOS, analytics is anonymous, content-free, and can be disabled in Settings → Advanced.
- **No voice data at rest beyond your device.** Dictation audio is processed on-device and discarded. Live Voice audio is streamed, not recorded, by the apps. Hermes Voice audio is cached only on your Mac.
- **No crash-content upload.** Crash logs stay on-device unless you choose to share them with Apple via the standard iOS / macOS reporting flows.
- **No ads or ad identifiers.** The `IDFA` / `IDFV` are not read or transmitted.
- **No cloud accounts.** There's no "Sign in with Scarf" — the apps only know about Hermes hosts you give them SSH access to.
- **No iCloud Keychain sync.** SSH keys are explicitly marked `ThisDeviceOnly` so they don't propagate.

## Network connections the apps make

- **SSH connections** to Hermes hosts you configured (port 22 by default; user-configurable). All Hermes data flows over these.
- **HTTPS to GitHub** for Sparkle's update check (Scarf only) and to fetch the public template catalog (`https://awizemann.github.io/scarf/templates/`). No personally identifying headers; cacheable.
- **HTTPS to models.dev** when Hermes refreshes its model catalog cache. Initiated by Hermes, not the apps directly.
- **HTTPS to `api.swiftstats.co`** (Scarf for macOS only, when usage analytics is enabled) carrying the anonymous usage events described above.
- **WebRTC to OpenAI** (both apps, only while a Live Voice session you started is open): microphone audio out, spoken replies in, plus the recent-chat context described above. The session is created by your Hermes host over its own HTTPS connection to OpenAI, with the host's key.

That's the complete list. Neither app makes any other network request.

## Push notifications

ScarfGo includes a push-notification skeleton for future use — pending permissions on a remote agent run. **The Push Notifications capability is disabled in shipping builds** (gated by an internal `apnsEnabled = false` flag) until Apple Developer Program enrollment + a Hermes-side push sender land. No device tokens are registered with Apple's APNs servers in current builds.

When push lands, only the device token will be transmitted, and only to the Hermes host you authorize (so it can address pushes back to your phone). Apple's APNs infrastructure will route the actual push payload, but the developer never sees it.

## TestFlight beta program

If you join the ScarfGo beta via TestFlight, Apple shares anonymized crash reports + the email you used to redeem the invite with the developer. Apple's standard [TestFlight terms](https://www.apple.com/legal/internet-services/itunes/testflight/) apply to that data — out of scope for this policy.

## Security

- iOS Keychain storage uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so credentials are unreachable while the device is locked and never synced to iCloud.
- SSH connections use the same protocol stack as `ssh(1)` — strict host-key verification on first connect, key-based auth (no passwords are sent over the wire), and Citadel's pure-Swift implementation on iOS.
- The macOS app is notarized via Apple's standard Developer ID flow (signed + stapled by `xcrun notarytool` on every release). It is not App-Sandboxed — Scarf needs direct read access to `~/.hermes/` and the ability to spawn the `hermes` CLI, both of which the App Sandbox forbids. That's why Scarf is distributed via GitHub Releases + Sparkle rather than the Mac App Store.
- ScarfGo on iOS runs inside the standard iOS app sandbox — no special entitlements beyond Keychain access for the SSH key and microphone access for the voice features you invoke.
- Live Voice runs its media connection inside an isolated, non-persistent web view that only ever loads the app's own bundled page and only grants the microphone to that page; no cookies or site data persist between sessions.

## Children's privacy

Neither app is directed at children under 13 and we do not knowingly collect any data from them.

## Your rights

The only data that reaches a developer-controlled server is the anonymous macOS usage events described above. You can stop them at any time (Settings → Advanced → Usage Analytics). Because events carry no persistent identifier, the developer cannot isolate "your" events afterward — there is nothing linkable to request deletion of or export. To remove all app-stored data from your device:

- **ScarfGo**: delete the app. iOS purges the Keychain group + app container.
- **Scarf**: delete `Scarf.app` from `/Applications`, then optionally remove `~/Library/Caches/scarf/` (remote SQLite snapshots and cached Hermes Voice audio), `~/Library/Preferences/com.scarf.app.plist` (server registry + preferences), and `~/Library/Application Support/com.scarf/` (skill snapshots).

Your Hermes host's data (`~/.hermes/`) stays untouched — that's yours to manage.

## Contact

Questions, concerns, or notice of a security issue: [alan@wizemann.com](mailto:alan@wizemann.com).

## Changes

Material changes to this policy will be announced on the [Scarf wiki](https://github.com/awizemann/scarf/wiki) and recorded here with a new "Last updated" date. Beta testers will see a TestFlight build note when policy changes affect data handling.
