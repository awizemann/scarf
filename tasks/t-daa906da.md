---
id: t-daa906da
title: Voice fix F3: Live Voice engine + page robustness (shared)
status: done
added: 2026-09-18
priority: high
---

## Description

From the final audits (t-f8c66377). ScarfCore VoiceLive + bundled voice-live.html + the iOS VoiceLiveSessionModel audio session.
1. MEDIUM: slow cancel. If the cancelled turn hasn't returned within the bound, do NOT submit the new request. Hermes queues it as text-only ("Queued for the next turn", acp_adapter/server.py:696-715 @ v2026.9.14) and the reply lookup then speaks the old turn's text. Instead, have the voice say Hermes is still finishing and ask the user to try again (or retry once the host goes idle).
2. MEDIUM: idle auto-end must still fire while a delegation is open, e.g. a separate longer cap such as 10 min without user speech while Hermes is stuck, e.g. waiting on a tool permission. Show a notice before ending.
3. LOW: streaming speech. Track spoken progress on the raw reply (or a stable sanitized prefix) so text isn't repeated or skipped as the markdown sanitization changes. Avoid re-running ~15 regexes over the whole reply every 200 ms.
4. LOW: make `session.close` actually reach OpenAI on `endImmediately` (send, briefly await the data-channel buffer or an ack, then close).
5. LOW: `pageLost()` must not drop the bridge's ability to tear down a live session (it nils `secureContext` on any didFail).
6. LOW: map getUserMedia errors properly: NotReadableError → mic busy, NotFoundError → no mic, NotAllowedError → denied.
7. LOW: treat `connectionState === 'disconnected'` as recoverable, with a grace period (e.g. 8 s), before failing with connection_lost.
8. LOW: iOS audio session. Deactivate only after WebKit teardown has completed, so other apps' audio resumes (VoiceLiveSessionModel.swift:247-248); expose a completion from the engine/bridge if needed.
9. LOW: localize vendor errors (show a Scarf sentence, keep the vendor text in logs only). Remove the unused parsed `gptLiveModel/gptLiveVoice/gptLiveInstructions` fields and their misleading doc (HermesConfig.swift:357-364), unless something reads them.
10. NOTE only: a vendor session abandoned during connect can't be closed from the client; keep it documented.
Standards: tests that fail when each fix is removed. Where practical, add an executable test for the page's teardown/mic-release JS (e.g. run it in a WKWebView in a test host). Both builds, a fresh-eyes check.

## Plan



## Artifacts

Branch feat/voice-f3 (worktree scratchpad/voice-f3), not pushed.
- 5d87e0f9 fix(voice): Live Voice engine and page robustness (ScarfCore + tests)
- 0e3f7e4f fix(voice): adopt the F3 API in both apps; iOS audio release

Items: 1 slow cancel (hold, retry on idle, give up aloud after 30 s) · 2 stalledTurnTimeout 10 min + endingSoon notice 60 s ahead (idle too) · 3 raw-offset streaming speech (speakableBoundary/speechSegment) · 4 page teardown flushes the open channel (drain + 300 ms, cap 1.5 s), mic released at once · 5 pageLost only for the page's own pre-ready load failure; teardown never gated · 6 NotReadable→.microphoneBusy, NotFound→.microphoneNotFound, NotAllowed→.microphoneDenied (page + Swift) · 7 'disconnected' 8 s grace · 8 iOS deactivates AVAudioSession after engine.waitForMediaRelease() · 9 notice is structured, vendor text logged only; HermesConfig gptLive* removed · 10 documented in the GPTLiveEngine doc comment · extra: VoiceTextOnlyTurnLedger keyed by VoiceTurnHost.voiceChatID.

Numbers: ScarfCore swift test 3485 tests / 295 suites pass. The VoiceLive suites have 73 tests (44 engine, 11 bridge/page, text). iOS sim (iPhone 17 Pro) VoiceLive suites: 29 pass. Mac VoiceLiveMacTests 15 pass, and HermesP38SourceSweepTests pass. Both builds (scarf; scarf mobile, generic iOS Simulator) succeeded. Mutation check: 15 mutations, one per fix (14 in ScarfCore, 1 iOS), and each made its tests fail.

PUBLIC API CHANGES the apps must adopt (done in 0e3f7e4f, so F2a must merge them):
- VoiceConversationEngine.notice: String? → VoiceSessionNotice? (.vendorError(code:), .endingSoon(reason:secondsLeft:)). Mac: VoiceLivePresentation.notice(_:) + VoiceLivePanel line ~49. iOS: VoiceLiveSessionSheet.noticeText.
- New VoiceSessionFailure cases .microphoneBusy, .microphoneNotFound; new VoiceSessionEndReason.turnStalled (exhaustive switches in VoiceLivePresentation.failure/endedMessage and the iOS sheet).
- VoiceTurnHost.voiceChatID (default nil). Implemented: ChatViewModel → richChatViewModel.sessionId; ChatController → vm.sessionId.
- VoiceMediaBridge.teardown(onReleased:) (teardown() remains as an extension); VoiceConversationEngine.waitForMediaRelease() (default no-op); GPTLiveEngine init gains textOnlyTurns: (default .shared); Configuration adds stalledTurnTimeout / endWarningLead / busyRetryWindow.
- HermesConfig.VoiceSettings loses gptLiveModel / gptLiveVoice / gptLiveInstructions (no reader).
Flags for follow-up: the Mac FailureCopy.detail still shows vendor detail verbatim (F2a presentation). Mac isVoiceTurnBusy counts isAgentWorking for turns Scarf didn't start, and a stale value would hold a voice request for the 30 s window.

