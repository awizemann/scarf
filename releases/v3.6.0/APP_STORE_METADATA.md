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

**Live Voice: keep "Data Not Collected" (decided by Alan, 2026-10-05).** ScarfGo sends nothing by default. Live Voice is off until the user starts it, it asks for consent first, and the data goes to OpenAI under the API key configured on the user's own Hermes host. The developer receives none of it. The label stays **Data Not Collected**, and the iOS privacy manifest declares no collected data types. The policy and the consent screen describe Live Voice as a user-started feature that talks to a service the user configured.

Update the **App Review notes** to explain this, so the reviewer sees why the label and the consent screen don't conflict: "Live Voice is off by default. When the user starts it and accepts the consent sheet, the device streams microphone audio and Hermes's replies and status lines to OpenAI, and the user's own Hermes host passes up to 24 recent messages to OpenAI when it creates the session, using the user's own OpenAI key on that host. The developer operates no server in this path and receives none of this data. The consent sheet appears again in this version because its wording now lists the replies and status lines."

**File Timestamp manifest gap: fixed in this release** (commit 3a89bdfd). The iOS manifest now declares `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1`, for MetricKit reports and the TTS cache in the app's own container.

## Version

Marketing version **3.6.0**, in lockstep with the macOS Scarf release (project convention; `release.sh` writes it to every target). Build number = `CURRENT_PROJECT_VERSION` after the bump (75), as long as that's higher than the last build uploaded to App Store Connect.

## Screenshots

No new screens need capturing. If you refresh the set, the System › Server host-key card and the light/dark button colours are the visible changes.
