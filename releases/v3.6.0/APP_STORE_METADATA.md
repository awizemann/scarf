# ScarfGo v3.6.0 — App Store Connect per-version copy

The set-once **App information** (name, subtitle, bundle ID, categories, support/privacy URLs, keywords) is unchanged — [`releases/v2.5.0/APP_STORE_METADATA.md`](../v2.5.0/APP_STORE_METADATA.md) remains the source of truth for those fields. This file carries the per-version fields for v3.6.0, plus two corrections to the Description and a check of the App Privacy answers. (Verify character counts against Apple's limits before pasting.)

## Promotional text (max 170 chars, editable without resubmission)

```
Now verifies your server's identity on every connection, with clearer buttons and status colours in light and dark mode. Run your Hermes agent from your iPhone.
```

## What's New text (max 4000 chars)

```
A security fix, easier reading, and privacy text that matches exactly what the app does.

• ScarfGo now verifies your server's identity. Earlier versions didn't check a server's SSH host key, so on a network someone else controlled, a machine pretending to be your Hermes server could have been accepted. ScarfGo now remembers each server's key the first time it connects (servers you already use are remembered on their next connection, with nothing to set up) and refuses to connect if the key ever changes. System > Server shows the key ScarfGo trusts. If a key changes, for example after you reinstall a server, ScarfGo shows the old and new fingerprints side by side, and Trust New Key lets you accept the new one after you've checked it.

• Easier to read. Buttons, status text and warnings now meet accessibility contrast standards in light and dark mode. In dark mode, orange buttons have dark text; status colours are darker and readable; destructive actions are brick red. Button labels grow with Larger Text and keep a comfortable tap area.

• Live Voice will ask once more. The consent screen now also says that Hermes's replies and short status lines go to OpenAI during a session so the voice can speak them, and that your Hermes server passes the recent chat messages on. Because the text changed, ScarfGo asks you to agree again before your next Live Voice session. Nothing else about Live Voice has changed, and you can review your choice in System > Settings > Live Voice Privacy.

• The microphone and speech recognition permission prompts now mention voice conversations with Hermes.

Privacy: ScarfGo itself sends no analytics. The full policy, updated for this release, is at awizemann.github.io/scarf/privacy.
```

> Brand note: the v2.5.0 copy warns that Apple can flag third-party trademarks in metadata. "OpenAI" appears here only to name who receives Live Voice data, which the disclosure requires. If review objects, replace it with "the voice service your Hermes server uses".

## Description — two corrections (if the live copy still has the v2.5.0 text)

The v2.5.0 Description has two statements that are no longer true. Edit them on the 3.6.0 version page:

- **Privacy paragraph.** It says SSH keys use the ThisDeviceOnly attribute and "never sync to iCloud". ScarfGo now has an opt-in **Sync SSH key with iCloud Keychain** toggle, and Live Voice sends data to OpenAI when you start it. Replace the paragraph with:

  ```
  Privacy. ScarfGo sends no analytics, telemetry or ad identifiers, and the developer runs no server it talks to. Your SSH key is generated on the device and stays there unless you turn on iCloud Keychain sync. ScarfGo checks each server's host key on every connection. The optional Live Voice feature streams your voice and recent chat messages to OpenAI, using the key on your own Hermes server, only after you start a session and agree. Full policy at awizemann.github.io/scarf/privacy.
  ```

- **Requirements line.** It says "iOS 18.0 or later". The deployment target is **iOS 18.6** (`IPHONEOS_DEPLOYMENT_TARGET` for `com.scarfgo.app`). Change it to "iOS 18.6 or later." Its Hermes line ("v0.10.0 or later recommended; full v0.11.0 features supported") is also stale; the app supports Hermes v0.6.0 through v0.21.5 with newer features gated.

Other parts of the v2.5.0 Description are also out of date (for example, read-only cron, and project chat writing an AGENTS.md block, which no longer happens on Hermes 0.16+). A full rewrite is optional and not required for this release.

## App Privacy (nutrition label) — what to check in App Store Connect

**ScarfGo analytics:** none. `scarf/Scarf iOS/PrivacyInfo.xcprivacy` declares no collected data types, and the policy says ScarfGo sends nothing to the developer. Nothing to add for analytics. The Mac app's new Device ID and Performance Data entries in this release are Mac-only and don't affect ScarfGo's label.

**Live Voice: still an open decision (task t-11cc53ea).** The 2026-09-19 recommendation ([`documents/appstore-review/2026-09-19-scarfgo-app-privacy-live-voice.md`](../../documents/appstore-review/2026-09-19-scarfgo-app-privacy-live-voice.md)) is still pending. The iOS privacy manifest still declares no collected data. This release makes the case for declaring stronger: the corrected policy and consent screen now say that the device sends **microphone audio, Hermes's reply text and status lines** to OpenAI, and that the host passes up to 24 recent messages to OpenAI.

- **Recommended (option b):** in App Store Connect → App Privacy, declare **Audio Data** and **Other User Content**, each with purpose **App Functionality**, **not linked** to the user, and **not used for tracking**. Add the same two types to `scarf/Scarf iOS/PrivacyInfo.xcprivacy` (XML is in the recommendation doc), so the label, the manifest, the microphone prompt and the policy all agree. Don't declare Coarse Location for the IP address.
- **If you keep "Data Not Collected" (option a):** nothing changes in App Store Connect. The risk is that the policy and the microphone prompt now say plainly that data goes to OpenAI, while the label says nothing is collected (guideline 5.1.1(i) consistency).

Either way, update the **App Review notes** to say that Live Voice audio, recent messages, and Hermes's replies and status lines go directly from the device to OpenAI with the key on the user's own host, after a consent sheet. That makes it clear to the reviewer why consent is asked again.

**Separate manifest gap, still open (task t-aa7be288):** `MetricKitSubscriber.swift:83,91,148,154` and ScarfCore's `HermesTTSCache.swift:157,163` read `contentModificationDate`, and `SSHTransport.swift:126` / `LocalTransport.swift:228` read `.modificationDate`. That is the **File Timestamp** Required Reason API, and the iOS manifest declares only UserDefaults. Adding `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1` avoids an ITMS-91053 warning or rejection. This is a code change for you to decide on. It is not part of this prep.

## Version

Marketing version **3.6.0**, in lockstep with the macOS Scarf release (project convention; `release.sh` writes it to every target). Build number = `CURRENT_PROJECT_VERSION` after the bump (75), as long as that's higher than the last build uploaded to App Store Connect.

## Screenshots

No new screens need capturing. If you refresh the set, the System › Server host-key card and the light/dark button colours are the visible changes.
