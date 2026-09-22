---
title: ScarfGo Live Voice (P5b): gate, mic exclusivity, teardown and the shared prompt path
type: note
permalink: scarf/architecture/scarfgo-live-voice-p5b-gate-mic-exclusivity-teardown-and
tags: [voice, gpt-live, ios, scarfgo]
source_paths: [scarf/Scarf iOS/Chat/ChatView.swift, scarf/Scarf iOS/Settings/SettingsView.swift]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-09-18
updated: 2026-09-19
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

ScarfGo's binding of the P4 Live Voice core (task t-50cf07c5, branch feat/voice-p5b). Composer entry sits beside the P1 dictation mic; the session is a sheet over Chat. The Mac twin (P5a) must follow the same VoiceTurnHost rules.

## Observations
- [convention] ChatController's typed send and Live Voice share startPrompt/runPrompt: startPrompt bumps promptsInFlight synchronously before spawning the Task (so a cancel racing the hand-off still waits), runPrompt synthesizes .promptComplete from sendPrompt's return; cancelActiveVoiceTurn fires ACPClient.cancel un-awaited and polls promptsInFlight to 0, bounded by voiceCancelTimeout (10 s, C10) #voice #ios
- [decision] The composer entry renders only when VoiceLiveReadiness is .ready; ChatController.refreshVoiceChatMode re-reads voice.voice_chat_mode off-main on every Chat appearance, and only on hasGPTLiveVoice hosts, so a mode flipped in Settings shows up on return and pre-0.21.3 hosts do no extra IO (C1) #voice #capabilities
- [invariant] VoiceLiveSessionModel.teardown(trigger) calls endImmediately inside a UIApplication background task (released after a 5 s grace) on background, Chat onDisappear (tab/server/profile switch), vm.sessionId change, sheet dismiss and AVAudioSession interruption; .inactive deliberately keeps the session (Control Center route changes) #voice #cost
- [gotcha] A view can't present a second sheet over its own, so Hermes tool-permission prompts would silently never show during a voice turn; ChatPermissionPresenter is a modifier applied to ChatView (disabled while the voice sheet is up) and inside the voice sheet #voice #ios
- [gotcha] ImageRenderer draws a placeholder for NavigationStack/ScrollView content, so it cannot snapshot the voice sheet in a unit test; visual checks need a connected simulator or device #testing #ios

## F4 consent and copy (t-ba3ccc85)

- [convention] `VoiceLiveSessionModel.begin` checks consent BEFORE the microphone prompt; `pendingConsent` drives `.sheet(item:)` in ChatView, and Continue starts the session in that sheet's onDismiss (`startLiveVoiceAfterConsent`). `teardown(.viewDisappeared)` drops a pending consent; backgrounding keeps it. Settings has a "Live Voice Privacy" section (Review / Reset) placed OUTSIDE the managed-host `.disabled` group, because the consent is device-local, not a Hermes key #voice #privacy
- [fact] NSMicrophoneUsageDescription now says dictation is transcribed on this device and Live Voice streams directly to OpenAI (not "through your Hermes server") #voice #privacy



## Relations
- relates_to [[Live Voice core (ScarfCore/VoiceLive): the engine-agnostic surface both apps bind to]]
- relates_to [[Push-to-talk dictation (ScarfIOS): on-device-only privacy contract + lifecycle teardown pattern]]



## F6 fresh-eyes fixes on main (t-521b5646, 2026-09-19)

- [invariant] ChatView observes `controller.state` via `.onChange`; any state whose `endsLiveVoice` is true (anything but `.ready`: connecting, failed, reconnect) calls `voiceLive.teardown(.hermesConnectionLost)` while a session is active. Before this, a dropped Hermes connection left the GPT-Live session streaming to OpenAI (billed) while every spoken turn threw `.chatNotReady`. The reason travels as `VoiceLiveSessionModel.endNote` (sheet) and a composer notice; the engine itself only reports `.userEnded` #voice #cost
- [convention] `VoiceLiveAVAudioSession` sits behind a `System` seam, captures the app's category/mode/options on activate and restores them on deactivate (before: the app stayed on playAndRecord/voiceChat/speaker for its whole life). The deferred deactivate is generation-keyed so a stale one is skipped, and the composer gates dictation on `blocksDictation` (`isActive || holdsAudioSession`), not `isActive`, because the audio session is handed back a beat after the session ends #voice #ios
- [decision] A single audio-session owner for dictation and Live Voice is still open (t-3b99e040); F6 only closed the observed races #voice



## Typed-turn parity (t-2140ec98, 2026-09-19)

- [decision] ScarfGo now follows the Mac rule: voice cancels only voice turns. `ChatController` tracks `busyTurnOrigins` (.typed/.voice) per in-flight prompt; `isVoiceTurnBusy` is true only for a voice-only run, `isBusyWithNonVoiceTurn` covers a typed prompt running or queued inside a voice turn (or a transcript-visible turn Scarf didn't start). `submitVoiceTurn` then sends nothing, returns normally, remembers the request id, and `voiceTurnReply` answers `voiceBusyReply` (the voice speaks it) while the composer shows the `.busyWithTypedTurn` notice. `cancelActiveVoiceTurn` is a no-op in that state and otherwise waits (bounded) only for voice-started turns #voice #acp
