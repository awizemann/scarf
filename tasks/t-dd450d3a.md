---
id: t-dd450d3a
title: Voice fix F2a: Mac Live Voice lifecycle and chat-turn fixes
status: done
added: 2026-09-18
priority: high
---

## Description

From the final audits (t-f8c66377). Mac app only (scarf/scarf/Features/VoiceLive, ChatViewModel, RichMessageBubble, VoiceTab, VoiceLivePanel).
1. HIGH: only one Live Voice session app-wide. Starting one in window B must end or refuse window A's (decide which, and match iOS). Today each ChatViewModel owns its own VoiceLiveController, so two sessions can run at once, both billing, with requests possibly going to the wrong server.
2. MEDIUM: end the voice session when the ACP connection dies or reconnect attempts run out (`handleConnectionDied`, about line 2057, and the attempts-exhausted branch around line 2198). Fix the comment at ~2213 that claims this already happens.
3. MEDIUM: turn identity. `launchPromptTask`'s completion must only clear state for its OWN turn (tag it with a token). A superseding submit must not overwrite `acpPromptTask`/`inFlightPromptSessionId` so that stopACP loses the older turn. Covers audit items 12/D and the Mac half of the slow-cancel finding.
4. MEDIUM: a voice request that interrupts a TYPED turn must not do so silently. Either don't cancel typed turns (wait, or queue the voice request) or show it clearly. Recommend: voice cancels only voice turns; while a typed turn runs, the voice says Hermes is busy.
5. LOW: keep the pending "text-only next turn" flag across voice sessions (build it per chat, not per engine, or persist it in the controller), per GPTLiveEngine.swift:97.
6. LOW: disable the message speaker button while Live Voice is active.
7. LOW: `end`/`endImmediately` right after `start` must cancel the pending start task (the engine is still `.idle`).
8. LOW: localize the "System Voice"/"Hermes Voice" picker labels (String(localized:)). Show a loading state and accessibility value while Hermes Voice synthesizes (the `loading` property is unused). Add VoiceOver announcements for Live Voice phase changes and failures. Fix the stale comment at ChatViewModel.swift:1049.
Standards: tests that fail when each fix is removed, the Mac suite run serially (see memory operations/mac-scarftests-run-green-only-serially…), both builds, a fresh-eyes check.

## Plan



## Artifacts

Branch feat/voice-f2a (worktree scratchpad/voice-f2a), not pushed. Commits:
- 517b8586 fix(voice): one Live Voice session app-wide; end-before-start; speaker button and VoiceOver (items 1, 6, 7, 8)
- 2fe27ad9 fix(chat): per-turn prompt tokens; voice never cancels a typed turn; end voice on ACP death (items 2, 3, 4, plus all new tests)
Item 5 skipped (F3 owns ScarfCore VoiceLive). No ScarfCore files changed.

Design choices
- Item 1: REFUSE, don't replace. VoiceLiveSessionRegistry.shared (weak holder) blocks a start in window B while window A's session is starting or running. The composer button and "Start Again" are disabled, with "Live Voice is running in another Scarf window" help and an accessibility hint. Matches ScarfGo, which refuses a start while something else holds the mic. It also never cuts off a conversation, or the Hermes turn it waits on, in a window the user isn't looking at. Window A's panel always shows the session and its End button.
- Item 2: end at handleConnectionDied (voiceLive.endForLostConnection()), not only when attempts run out. The running voice turn dies with the process, and every spoken request during the up-to-~1 min ladder would fail while billing. The panel footer says "Ended because the connection to Hermes was lost". The exhausted branch doesn't need its own call: no session can start with acpClient nil. Its comment and the stopACP comment are fixed.
- Item 3: promptTurns [token: PromptTurn(sessionId, origin, isNonInterruptive, task)] replaces the acpPromptTask slot and the generation counter; inFlightPromptSessionId is now computed. Verified against Hermes acp_adapter/server.py (~/.hermes/hermes-agent, v2026.9.11-938): a prompt sent mid-turn is answered AT ONCE ("Queued for the next turn", :696-715) and run inside the older prompt's _finish_turn (:927-938), so the older sendPrompt returns LAST. Each turn settles only its own entry. acpStatus/promptComplete/notification move only when no other interruptive turn is in flight. stopACP/handleConnectionDied cancel all turns, and a voice cancel waits for every in-flight prompt.
- Item 4: as recommended. isVoiceTurnBusy is true only for voice turns with nothing typed in the run (busyTurnOrigins). While a typed request runs or is queued, cancelActiveVoiceTurn does nothing, and submitVoiceTurn sends nothing, returns normally, and voiceTurnReply answers ChatViewModel.voiceBusyReply ("Hermes is busy with another request in this chat…"), which the voice speaks. A composer hint also shows. No ScarfCore change was needed. Returning instead of throwing avoids the engine's "could not reach Hermes" line. Clearing the engine's cancelledTurnPending flag is still correct, because the typed prompt consumed Hermes's stored interrupted text.
- Item 6: SpeakMessageButtonState. The speaker button is disabled while any Live Voice session holds the speaker (it can still stop something already playing).
- Item 7: controller.isStartPending. end/endImmediately before the start task runs cancel it (the task guards Task.isCancelled) and drop the never-started session. holdsSession counts the pending start for the registry and the composer.
- Item 8: picker labels use String(localized:). The speaker button shows a ProgressView plus the accessibility value "Preparing audio" while Hermes Voice synthesizes (MessageSpeechService.loading). The panel posts VoiceOver announcements from VoiceLivePresentation.announcement (connecting, listening from not-live, thinking, ended with reason, failure message; speaking/listening flips are not announced). The stale "one and only message_sent site" comment is fixed.

Tests (scarf/scarfTests/VoiceLiveMacTests.swift, 27 tests; 13 new). VoiceScriptedChannel now answers a mid-turn prompt immediately, as Hermes does.
Teeth, each fix reverted and the suite rerun:
- M1 registry off → aSecondWindowCantStartWhileOneHoldsTheSession fails
- M7 end-before-start off → endBeforeTheStartTaskRanCancelsTheStart, gracefulEnd…, registryReportsASessionForTheSpeakerButtons fail
- M2 no end on death → aDeadACPConnectionEndsTheVoiceSession fails
- M3a completion ignores other turns → aQueuedTurnsReturnDoesNotEndTheRunningTurn fails
- M3b one-slot semantics → aQueuedTurns… and voiceCancelWaitsForTheRunningTurnNotTheLastLaunched fail
- M3c wait only on the newest in-flight task → passes: an equivalent mutant (the queued turn has already settled, so newest == running); M3b covers the real regression
- M4 old busy semantics → aTypedTurnIsNeverCancelledByVoice, aTypedPromptQueuedBehindAVoiceTurnIsNotCancelled fail
- M6 → speakerButtonStandsDownDuringLiveVoice fails; M8 → phaseChangesAreAnnounced… fails

Runs
- macOS scarf build: succeeded, no new warnings. iOS not built: no shared/ScarfCore code touched.
- Mac suite serially (-only-testing:scarfTests -parallel-testing-enabled NO): the first two runs stalled on the known login-keychain SecurityAgent prompt (sampled: GwF1RefusalOrderingTests and ProjectTemplateUninstallerTests.roundTripsInstallThenUninstall in SecItemCopyMatching through ProjectConfigKeychain.get). 1085 tests had passed with 0 failures before that stall. The final run skipped the 11 keychain-reaching suites and passed 1395/1395 tests in 203 suites (128 s). Those 11 suites were NOT run on this branch; none touch chat or voice.

Audit notes
- Behavior change: a /steer or /queue that returns while an interruptive turn runs no longer triggers promptComplete (it used to finalize the running turn's stream and clear "Agent working…" partway through). No existing test depended on the old behavior.
- A typed prompt sent while a voice turn runs makes the current voice delegation read not-busy, so the engine settles it early. The typed bubble becomes the last user message, so the voice's reply lookup returns nil and it says "finished without a spoken result". This is acceptable (the user chose to type over the voice) but worth knowing.
- ScarfGo's ChatController+VoiceTurnHost still counts any running turn as busy and cancels it (promptsInFlight > 0 || isAgentWorking). If item 4's rule should hold on iOS too, that needs a follow-up.
- Memory: updated Mac Live Voice (P5a) with a new F2a section; ACP turn completion note (a mid-turn prompt returns FIRST); Mac scarfTests serial note (keychain skip list, zsh array gotcha).

