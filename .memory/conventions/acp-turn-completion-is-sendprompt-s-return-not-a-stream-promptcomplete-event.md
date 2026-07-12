---
title: ACP turn completion is sendPrompt's return, not a stream .promptComplete event
type: note
permalink: scarf/conventions/acp-turn-completion-is-sendprompt-s-return-not-a-stream-promptcomplete-event
tags:
- acp
- miniapps
- bug
- fix
- testing
- concurrency
- security
created: 2026-06-16
updated: 2026-07-12
---

Every ACP consumer must derive turn-completion from `sendPrompt`'s return; the event stream does not carry it. Missing this shipped a hung happy-path in the M2 mini-app agent channel. Branch `feat/projects`.

## Observations
- [gotcha] `ACPClient`'s event stream NEVER yields `.promptComplete`. `ACPEventParser.parse` has no case that produces it (session/update types map only to messageChunk/thoughtChunk/toolCall*/availableCommands/sessionInfoUpdate/unknown). The turn-completion signal is `sendPrompt(...)` RETURNING its `ACPPromptResult` — each consumer synthesizes `.promptComplete` from that return itself. #acp #architecture
- [pattern] `ChatViewModel` does it right: awaits `sendPrompt`, then feeds `richChatViewModel.handleACPEvent(.promptComplete(sessionId:response:result))` (scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift ~783). The stream-side `.promptComplete` case in RichChatViewModel only handles that locally-synthesized event. #acp
- [bug-fixed] `MiniAppAgentSession` (the `scarf.prompt` backing actor) originally discarded the result (`_ = try await client.sendPrompt(...)`) and resolved its continuation ONLY on a stream `.promptComplete` that never arrives. Effect: `scarf.prompt(...)` never resolved with the agent reply on a normal turn — it hung until teardown, then rejected with connectionLost, leaving the session wedged at `promptInFlight=true`. M2 was build-verified only, so this shipped unnoticed. #bug #security #miniapps
- [fix] On `sendPrompt`'s successful return, route a synthesized `.promptComplete(sessionId:response:result)` through `handle()` — that BOTH fires the `onEvent` "complete" forward AND resolves the continuation with the accumulated messageChunk buffer. ~2-line change in MiniAppAgentSession.prompt(). #fix
- [testing] `scarf/scarfTests/MiniAppAgentSessionTests.swift` now guards this plus the two 350c3bd concurrency fixes (atomic busy claim before the ensureSession await; no continuation leak on stream end). Harness: a new injected `clientFactory` on MiniAppAgentSession lets tests wire a real `ACPClient` over an in-memory `FakeACPChannel` (auto-answers initialize/session_new, scripts session/prompt replies + session/update notifications). Teeth verified: reverting the completion fix clean-fails 4 of 7. #testing
- [gotcha-tests] A timeout helper that races work against a deadline must POLL a result box, not structurally await the work task — `withCheckedThrowingContinuation` is not cancellation-aware, so awaiting a leaked continuation (e.g. via a throwing task group's cleanup) hangs the helper itself instead of failing fast. #testing

## Relations
- relates_to [[Phase-1 Milestone 2: Mini-apps — implementation decisions]]
- relates_to [[Fast test-iteration commands (swift test vs xcodebuild)]]



## Third occurrence: iOS chat controller (gh#124, fixed 2026-07-12, a6be036)

- [gotcha] The iOS `ChatController._sendImpl` ALSO discarded `sendPrompt`'s result (`_ = try await client.sendPrompt(...)`) — the pre-existing third consumer, reported externally with a near-perfect diagnosis. Symptom: streaming bubble never finalized, `isAgentWorking`/`isPostProcessing` stuck, transcript sits in "Finishing up…" after the reply lands. Fix mirrors Mac exactly: synthesize `.promptComplete` on success AND an error-stopReason completion in the general catch; the `.reconnecting` early-return skips it because `pauseInBackground` already ran `finalizeOnDisconnect()`. #bug #fix
- [convention] When adding ANY new `sendPrompt` caller, wire the completion synthesis in the same change — grep for `_ = try await client.sendPrompt` in review; that pattern is always wrong.
- [testing] Controller-level regression: `Scarf iOSTests/ChatControllerPromptCompleteTests` drives the real `start()`/`send()` over an in-memory `AutoReplyChannel` (chunk → prompt result), asserts finalization + working-state exit. Teeth-verified (reverting the fix fails 3 assertions). Enablement: `ChatController.clientFactory` test seam (mirrors MiniAppAgentSession); the "Scarf iOSTests" target is RUNNABLE for the first time — shared "scarf mobile" scheme now lists it, stale TEST_HOST (pre-rename "Scarf iOS.app") corrected, `@testable import scarf_mobile` (module name after the target rename). Run: `xcodebuild test -scheme "scarf mobile" -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:"Scarf iOSTests"`. #testing
