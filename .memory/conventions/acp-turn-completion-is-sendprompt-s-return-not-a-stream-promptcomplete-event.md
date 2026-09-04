---
title: ACP turn completion is sendPrompt's return, not a stream .promptComplete event
type: note
permalink: scarf/conventions/acp-turn-completion-is-sendprompt-s-return-not-a-stream-promptcomplete-event
tags: [acp, miniapps, bug, fix, testing, concurrency, security]
created: 2026-06-16
updated: 2026-09-04
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


## The hang-guard deadlines had to be scaled for the parallel suite (t-05a6bb8b)

`MiniAppAgentSessionTests` failed roughly one full-suite run in three at `waitFor`, and was green every time it ran alone. It was never a behaviour failure: every assertion in that suite is about WHETHER a turn resolves, and the only thing that failed was the deadline.

- [gotcha-tests] The suite owns no file, no port and no subprocess — it is a `FakeACPChannel` actor and a real `ACPClient`, entirely in memory. What it contends on is CPU and the scheduler, shared with sibling suites that spawn real `Process`es (the same contention behind the flaky `RemoteSQLiteBackend` subprocess race, t-aud32). Nine tests each spinning a 10-15 ms polling loop against a 2 s deadline is a deadline tuned to an idle machine. Look for the contention before padding: "flaky under parallel load" is not automatically a shared-resource bug. #testing
- [decision] Two fixes for the two halves. `.serialized` removes the contention the suite creates FOR ITSELF (nine concurrent polling loops become one); it cannot touch the sibling suites, because `.serialized` covers a suite and its subgroups, never the rest of the run — the same limit `TestRegistryLock` ran into. The deadlines then moved into a `Deadline` enum scaled by `activeProcessorCount` (1x at 8+ cores, up to 4x on one core), because a timeout in this suite is a HANG GUARD, not an assertion: its only job is to stop a genuinely leaked continuation from hanging CI, so headroom costs nothing on a green run.
- [fact] Verified across four consecutive full `scarfTests` runs (723 tests, 93 suites) — green every time, where the suite previously failed about one run in three.
