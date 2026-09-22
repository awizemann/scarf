---
title: Live Voice core (ScarfCore/VoiceLive): the engine-agnostic surface both apps bind to
type: note
permalink: scarf/architecture/live-voice-core-scarfcore-voicelive-the-engine-agnostic
tags: [voice, gpt-live, architecture, api]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-09-18
updated: 2026-09-19
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---
Built in P4 (task t-a4665c6e, branch feat/voice-p4). The macOS panel (P5a) and the ScarfGo sheet (P5b) bind only to these types, and a free chained engine (P7) can sit behind the same protocol. The design source is documents/plans/2026-09-18-live-voice-spike.md.

Unverified billing: if the host exchange is cancelled after the script has POSTed to /v1/live/sessions (end during connecting, or the connect timeout), the vendor session exists but never connects media. Whether OpenAI bills that session from creation until its own timeout has not been checked. Check it in the first keyed smoke test; it is also noted in the upstream request draft.

## Observations
- [convention] UI binds to VoiceConversationEngine (phase, captions, micLevel, isMuted, elapsedSeconds, approximateCostUSD, notice; start, end(reason:), endImmediately(reason:), toggleMute), and the chat conforms to VoiceTurnHost. submitVoiceTurn appends the bubble before any await and returns once the prompt is handed to ACP, passing request.contextNotes as given. cancelActiveVoiceTurn returns only after sendPrompt returns. Production wiring: GPTLiveEngine(bridge: WebViewVoiceMediaBridge(), exchange: VoiceLiveHostExchange(context:), turnHost:), plus VoiceLiveMediaHostView kept mounted in the panel #voice #api
- [decision] Gate: VoiceLiveReadiness.availability(capabilities:config:) requires hasGPTLiveVoice (Hermes >= 0.21.3) AND VoiceChatMode.parse(voice.voice_chat_mode) == gptLive, accepting Hermes's spellings gpt-live, gpt_live, gptlive and live. There is no host status probe, so a missing OpenAI key surfaces at start as .failed(.host(.noKey)) with setupHint true and nothing billed #voice #capabilities
- [invariant] The bundled page (VoiceLive/Resources/voice-live.html, a ScarfCore SPM resource read via Bundle.module) is a thin media transport. All oai-events decoding and encoding is in Swift (VoiceLiveServerEvent, VoiceLiveClientEvents), and every engine timer runs through GPTLiveEngine.tick() with an injected clock, so the loop is unit-testable without WebKit. First turns carry the voice note. A turn that cancelled a running one goes text-only (VoiceTurnRequest.supersedesCancelledTurn) so that Hermes consumes the cancelled prompt #voice #testing
- [gotcha] Hosts must call endImmediately on window close, session or server switch, iOS background and app quit. The MainActor engine cannot clean up in deinit, and a dropped engine leaves the web view's peer connection (billed at $0.05/min) open while the host view keeps the bridge alive #voice #cost
- [convention] Failures are the structured VoiceSessionFailure rather than strings, because ScarfCore has no string catalog. Apps localize one sentence per case; englishDescription and VoiceLiveHostError.errorDescription are English tokens #voice #i18n

## Robustness fixes (F3, t-daa906da, branch feat/voice-f3)

- [decision] Slow cancel: if the running turn is still busy after the host's bounded `cancelActiveVoiceTurn`, the engine does NOT submit. Hermes would queue the prompt text-only ("Queued for the next turn", `acp_adapter/server.py:696-715` @ v2026.9.14) and `VoiceTurnReply.latest` would speak the old turn's text. The voice says `stillBusyReply`, `tick()` submits once `isVoiceTurnBusy` goes false, and after `busyRetryWindow` (30 s) it says `stillBusyGaveUpReply` and settles. Caveat: the Mac `isVoiceTurnBusy` also counts `isAgentWorking` for turns Scarf didn't start, and a stale value holds requests until the window runs out #voice #acp
- [decision] Cost guards: `idleTimeout` (3 min, no delegation) plus `stalledTurnTimeout` (10 min, delegation open, no user speech and no Hermes progress, meaning no new reply text and no new tool). The second ends with the new `VoiceSessionEndReason.turnStalled`. Both show `VoiceSessionNotice.endingSoon(reason:secondsLeft:)` from `endWarningLead` (60 s) before the end #voice #cost
- [convention] `notice` is the structured `VoiceSessionNotice` (`.vendorError(code:)` / `.endingSoon`), never vendor text. The vendor message goes to `Logger(subsystem: "com.scarf", category: "LiveVoice")`, redacted. Apps localize one sentence per case (Mac `VoiceLivePresentation.notice`, iOS `VoiceLiveSessionSheet.noticeText`) #voice #i18n
- [convention] Streaming speech tracks progress on the RAW reply. `VoiceLiveText.speakableBoundary(in:)` returns the last sentence end that is outside code fences, inline code and link labels and on a line with no `|`. Only the new raw segment is sanitized, via `speechSegment`, and an unchanged reply is not re-scanned. Piecewise speech equals whole-reply speech, which a test pins. The old sanitized-count approach repeated or skipped text when a table's delimiter row or a closing fence arrived #voice
- [decision] The text-only debt belongs to the chat: `VoiceTextOnlyTurnLedger` (`.shared` by default, injectable) is keyed by `VoiceTurnHost.voiceChatID`, which is the ACP session id and defaults to nil. Both app hosts implement it, so the debt survives the per-session engine #voice #acp
- [convention] getUserMedia failures map by DOMException name, in the page (`closed` reason) and in Swift (`GPTLiveEngine.failure(forMediaStartError:)`, whichever arrives first): NotAllowed/Security → `.microphoneDenied`, NotReadable/Abort → `.microphoneBusy`, NotFound/Overconstrained → `.microphoneNotFound`, anything else → `.mediaUnavailable` #voice
- [convention] `VoiceMediaBridge.teardown(onReleased:)` and `VoiceConversationEngine.waitForMediaRelease()` (bounded to 3 s; the protocol extension default returns at once). iOS deactivates `AVAudioSession` only after it, and skips the deactivation if a new session re-activated in the meantime #voice #ios
- [gotcha] Still open (item 10): a vendor session abandoned while the host exchange runs can't be closed by the client. See the GPTLiveEngine doc comment #voice #cost


## Privacy consent (F4, t-ba3ccc85, branch feat/voice-f4)

- [decision] Alan: Scarf never picks a voice model or provider; it uses the user's Hermes voice setup. When that setup sends data OUTSIDE the user's devices and host to a third party, each app asks once, per device and per recipient, before the first session. The rule is `VoiceDataConsent.pendingRecipient(for:store:)` in `VoiceLive/VoiceDataConsent.swift`: an engine declares its `externalRecipient` (`GPTLiveEngine.externalRecipient == .openAI`; `VoiceChatMode.externalRecipient` maps gpt-live to it and chained to nil), and nil means no consent. A future local/chained engine (P7) declares nil or its own recipient and needs nothing else #voice #privacy
- [fact] What GPT-Live actually sends: microphone audio streams DIRECTLY from the device's WKWebView to OpenAI over WebRTC (the host only runs the session exchange, so OpenAI also sees the device's IP), and each session is seeded with up to 24 recent chat messages / 6,000 chars (`VoiceLiveText.liveHistory`). Never write "through the host" in copy #voice #privacy
- [convention] `VoiceDataConsentStore` (MainActor, @Observable, UserDefaults key `scarf.voiceLive.consent.<id>.v<disclosureVersion>`, `.shared` in production) is device-local. Bump `VoiceDataRecipient.disclosureVersion` when what is sent changes, and every device asks again. Tests inject a store over a throwaway defaults suite, never `.standard` #voice #testing
- [convention] The Mac `VoiceLiveController` and iOS `VoiceLiveSessionModel` take the recipient next to their session factory (default GPT-Live's, so a factory without one fails safe to asking). A start without consent only sets `pendingConsent` (sheet): no engine, no registry claim, no mic prompt, no audio session. Continue = `acceptConsent()` then start again (Mac `ChatViewModel.acceptVoiceLiveConsent`; iOS starts in the consent sheet's onDismiss, because iOS can't present the session sheet while the consent sheet is still dismissing). Cancel = `declineConsent()`, not remembered #voice
- [convention] Failure copy never shows vendor or host detail text (`VoiceLivePresentation.FailureCopy` has no detail field). The engine logs it, redacted, under com.scarf / LiveVoice, including the vendor close reason in `finish(remoteReason:)` #voice #i18n



## Relations
- relates_to [[GPT-Live client-delegation data-channel protocol (Hermes desktop reference)]]
- relates_to [[GPT-Live session exchange runs as a host script, not via the Hermes dashboard]]
- relates_to [[GPT-Live voice in WKWebView: origin, permission and hosting requirements]]
- relates_to [[ACP has no voice-live surface: send the turn note as an embedded resource block]]



## F6 fresh-eyes fixes on main (t-30cee401, 2026-09-19)

- [gotcha] `GPTLiveEngine` reports an `applyAnswer` (WebKit `setRemoteDescription`) failure with a FIXED detail, never the exception text: WebKit quotes the offending SDP line, which is where `a=ice-pwd:` / `a=fingerprint:` live, and `finish` logs the description at `.public`. `VoiceLiveHostExchange.redact` also strips `a=ice-ufrag|ice-pwd|fingerprint|crypto:` values (line-anchored and inline) on top of `sk-…`/`Bearer`/`ek_` #voice #security
- [gotcha] The transports surface a cancelled script as a plain transport error ("Script cancelled"), so `createSession` checks `Task.isCancelled` in its catch and rethrows `CancellationError` — otherwise a session the user ended looks like "couldn't reach the Hermes host" #voice #cancellation
- [gotcha] `SSHScriptRunner.ScriptFeeder` records the errno of any short write other than EINTR/EAGAIN/EPIPE; both run loops then terminate the child and return `.connectFailure("failed to feed the script: …")`. Before, the pipe was closed and the shell ran the truncated prefix as a complete script #transport
- [todo] Open: a session created while the user ends during `.connecting` is never closed (t-6a545269); consent is enforced only app-side (t-95b5d1cb) #voice #cost
