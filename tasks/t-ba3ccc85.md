---
id: t-ba3ccc85
title: Voice fix F4: privacy copy, consent and disclosure for Live Voice
status: done
added: 2026-09-18
priority: urgent
---

## Description

From the final audits (t-f8c66377). The copy is wrong: Live Voice AUDIO goes directly from the device to OpenAI over WebRTC. Only the session setup goes through the Hermes host, so OpenAI also sees the device's IP. Each session also sends up to 24 recent chat messages (up to 6,000 chars) to OpenAI as seed history, which nothing discloses. The mode picker changes a HOST-WIDE Hermes setting, which also switches the Hermes desktop app's voice to GPT-Live. Needs Alan's decisions (consent step; seed history). Then fix:
- iOS NSMicrophoneUsageDescription.
- The iOS and Mac Settings footers.
- A one-time consent sheet before the first session, if approved (App Store guideline 5.1.2(i)).
- wiki/Chat.md, wiki/ScarfGo.md, README, the release-notes draft, and the PR reply draft if it mentions it.
- The P1 dictation memory's "nothing leaves the device" framing, and the privacy task t-11cc53ea.

## Plan

Alan's decisions (2026-09-18):
- Scarf never picks a voice model or provider. It uses whatever the user has configured in Hermes.
- Consent rule: when the user's chosen Hermes voice setup sends their data OUTSIDE their own machines/host to a third party, Scarf shows a one-time consent before the first session (per device, per provider/mode, e.g. `gpt-live` → OpenAI). Future modes that stay local need no consent. Make this a small reusable rule (engine/mode declares its external recipient; nil = no consent needed), so P7's chained mode fits it.
- Seed history: keep sending recent chat (up to 24 messages, 6,000 chars) as context, stated plainly in the consent and docs.
Consent content, plain English: your voice streams directly from this device to OpenAI (the Hermes host only sets up the session, and OpenAI sees this device's network address); recent chat messages are shared for context; it bills about $0.05/min on the host's OpenAI key; turning on gpt-live mode changes the voice setting for the whole Hermes profile, including Hermes's own apps. Continue / Cancel. Store the acceptance locally (per device, per recipient), and give Settings a way to review or reset it.
Then correct all copy: iOS NSMicrophoneUsageDescription, the Mac + iOS Settings footers (including host-wide mode), wiki/Chat.md, wiki/ScarfGo.md, README, the release-notes draft, the PR-reply draft if needed, and the P1 dictation memory + task t-11cc53ea. The Mac failure view must not show the vendor's raw detail text (F2a follow-up: FailureCopy.detail).

## Artifacts

Branch feat/voice-f4, commit 1493963a (worktree scratchpad/voice-f4; not pushed).
Code:
- ScarfCore/VoiceLive/VoiceDataConsent.swift (new): VoiceDataRecipient (.openAI, disclosureVersion), VoiceChatMode.externalRecipient (gpt-live → OpenAI, chained → nil), VoiceDataConsent.pendingRecipient(for:store:), VoiceDataConsentStore (UserDefaults, per device/recipient/version, .shared). GPTLiveEngine.externalRecipient = .openAI; finish(remoteReason:) now logs the vendor close reason.
- Mac: VoiceLiveController.pendingConsent/acceptConsent/declineConsent (recipient injected beside the session factory), ChatViewModel.acceptVoiceLiveConsent, VoiceLiveConsentSheet + VoiceLiveConsentCopy (new), sheet in ChatTranscriptPane, Settings › Voice › Live Voice "Privacy Consent" row (Review… / Reset, new LabeledSettingsRow), footer rewritten. FailureCopy.detail removed (panel shows message + guidance only).
- iOS: VoiceLiveSessionModel consent gate before the mic prompt, VoiceLiveConsentSheet (new), ChatView consent sheet (session starts in onDismiss), Settings "Live Voice Privacy" section (outside the managed-host lock), footer rewritten, NSMicrophoneUsageDescription rewritten.
- README Privacy + Voice bullets.
Consent wording (Mac; iOS says "this device"): title "Live Voice sends your voice to OpenAI"; "Your voice streams directly from this Mac to OpenAI. The Hermes host only sets up the session, so OpenAI also sees this Mac's network address." / "Each session shares recent messages from this chat with OpenAI for context: up to 24 messages, about 6,000 characters." / "OpenAI bills the OpenAI key on the Hermes host about $0.05 per minute while a session is open." / "GPT-Live mode is a Hermes setting for the whole profile. It also changes voice in Hermes's own apps." Footnote: asks once, review/reset in Settings. Buttons Cancel / Continue.
Tests: ScarfCore VoiceDataConsentTests (7); VoiceLiveMacTests +7 (35 pass); iOS VoiceLiveSessionModelTests +5 (Scarf iOSTests 57 pass on iPhone 17 Pro sim). Mutation-checked: disabling the gate fails the consent tests on both apps; chained→OpenAI fails the no-recipient rule; showing the vendor reason fails failureCopyNeverCarriesTheRawDetail. Builds: macOS scarf + iOS "scarf mobile" (generic sim) succeed. ScarfIOS swift test 92 pass. Full ScarfCore swift test: only M1ACPTests/M4ACPIOSTests initialize timeouts under CPU contention (known flake, parallel agent); they pass alone.
Docs (main checkout, uncommitted): wiki/Chat.md, wiki/ScarfGo.md, documents/releases/voice-release-notes-draft.md, documents/pr-reviews/pr-143-review-reply.md. Memory: P1 dictation note corrected; Live Voice core / Mac P5a / ScarfGo P5b notes gained F4 sections. t-11cc53ea updated with the audio-leaves-device facts.
Open: scarf/docs/PRIVACY_POLICY.md has no Live Voice section (tracked in t-11cc53ea); Mac NSMicrophoneUsageDescription ("Hermes voice chat", translated in InfoPlist.xcstrings) left unchanged; new strings not yet in Localizable.xcstrings (same as prior voice phases).

