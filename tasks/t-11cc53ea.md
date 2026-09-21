---
id: t-11cc53ea
title: ScarfGo: decide App Privacy + privacy manifest for Live Voice audio
status: todo
added: 2026-09-18
priority: high
---

## Description

From P5b (t-50cf07c5), corrected by F4 (t-ba3ccc85). Facts for the decision (verified in code on feat/voice-f4):
- Live Voice AUDIO does NOT go through the Hermes host. The host only runs the session exchange (mints the vendor session with the user's own OpenAI key). The device's WKWebView then streams microphone audio DIRECTLY to OpenAI over WebRTC, so OpenAI also receives the device's IP address.
- Each session also sends OpenAI up to 24 recent chat messages (up to 6,000 chars) as seed context (`VoiceLiveText.liveHistory`).
- Billing is on the host's OpenAI key (about $0.05/min). Nothing reaches Alan or any Scarf server.
- Scarf never picks the model/provider: it only runs when the user set Hermes's `voice.voice_chat_mode` to gpt-live, which is profile-wide (also switches Hermes's own apps).
- F4 adds a one-time in-app consent before the first session (per device, per recipient; Cancel starts nothing; review/reset in Settings), which covers guideline 5.1.2(i) disclosure. NSMicrophoneUsageDescription now says Live Voice streams directly to OpenAI.
- Dictation (P1) stays on-device.
Because the audio leaves the device straight to a third party (not the user's own server), option (a) ("like chat text to the user's own server") is weaker than it looked. Options: (a) not "collected" by the developer (the app sends it to a service the user configured, with the user's own key) — no label change; (b) conservative: declare "Audio Data — App Functionality, not linked, not used for tracking" (and consider "Other User Content" for the seed chat) in App Store Connect App Privacy AND in `Scarf iOS/PrivacyInfo.xcprivacy` NSPrivacyCollectedDataTypes. Either way, describe the direct device-to-OpenAI flow and the consent sheet in the App Review notes, and add a Live Voice section to scarf/docs/PRIVACY_POLICY.md (it has none today) → wiki Privacy-Policy mirror → hand re-render of gh-pages privacy/index.html (memory "privacy policy page on gh-pages is hand-generated"). Alan decides; must be settled before the ScarfGo release that ships Live Voice.

## Plan



## Artifacts

2026-09-19 recommendation for Alan: documents/appstore-review/2026-09-19-scarfgo-app-privacy-live-voice.md — option (b): declare Audio Data + Other User Content (App Functionality, not linked, not tracked) in App Store Connect and PrivacyInfo.xcprivacy; xcprivacy XML and App Review notes are in the brief. Also found: File Timestamp Required Reason (C617.1) is missing (MetricKitSubscriber + HermesTTSCache read contentModificationDate) = t-aa7be288. Waiting on Alan's decision.

