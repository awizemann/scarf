---
title: Chained voice engine (P7): on-device STT, a normal Hermes turn, host TTS out
type: note
permalink: scarf/architecture/chained-voice-engine-p7-on-device-stt-a-normal-hermes-turn
tags: [voice, chained, stt, tts, architecture]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/VoiceLive/VoiceLiveReadiness.swift]
source_paths_inferred: false
source_sha: 0bc62f678de391d5e1d9fb625443204fb692c5bc
created: 2026-09-19
updated: 2026-09-22
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] `VoiceEngineKind` (Sendable, Equatable) is a new enum modeling which voice engine a window's server resolves to: `.gptLive` (GPTLiveEngine—OpenAI full-duplex, $0.05/min, needs API key and Hermes ≥ 0.21.3) or `.chained` (ChainedVoiceEngine—on-device STT, normal Hermes turn, host TTS; free, Hermes's default). The `VoiceLiveAvailability` enum provides an `engineKind` property (returns `VoiceEngineKind?`) to allow callers to branch on which engine is active without matching availability cases #voice
- [decision] Hermes's "chained" voice mode (its default) is a client loop, not a server engine: at tag v2026.9.14 only the Hermes desktop renderer implements it, and ACP drops audio blocks. Scarf therefore runs the loop itself: `VoiceListener` (Apple on-device speech) → `VoiceTurnHost.submitVoiceTurn` (a normal ACP turn, `noteStyle: .chained`, persisted row = spoken words) → `VoiceSpeaker` (host TTS through `HermesSpeechService`, `SystemVoiceSpeaker` fallback via `FallbackVoiceSpeaker`, one `.speechFallback` notice) #voice #hermes
- [invariant] `AppleOnDeviceVoiceListener` sets `requiresOnDeviceRecognition = true` and refuses to start when `supportsOnDeviceRecognition` is false: audio never reaches Apple's servers, so chained declares no `VoiceDataRecipient` and needs no consent sheet. The AVAudioEngine tap feeds the request through a lock-guarded box (never `MainActor.assumeIsolated` on the realtime thread). Audio-session policy is a seam (`VoiceAudioSessionControlling`); the iOS app passes its own owner #voice #privacy
- [decision] `VoiceLiveAvailability` is three-way (per P7 design, documents/plans/2026-09-19-voice-p7-free-voice-path.md §4): `.ready` (gpt-live mode AND hasGPTLiveVoice ≥ 0.21.3) → mounts GPTLiveEngine via `engineKind`; `.chainedReady` (hasHermesSpeechSynthesis ≥ 0.20.1; covers chained default, absent key, or gpt-live asked on a host too old for it, matching the Hermes desktop's fallback) → mounts ChainedVoiceEngine via `engineKind`; `.hidden(.hermesTooOld)` (Hermes below 0.20.1, C1). The `.hidden(.chainedMode)` case no longer exists; the single composer button mounts the verdict's engine. Apps inspect `engineKind` to determine mounted engine #voice #capabilities
- [convention] Loop rules mirror GPTLiveEngine: 200 ms tick polls `voiceTurnReply`, sentences are spoken as they stream, the busy reply is spoken, `VoiceLiveText.isVoiceStopCommand` ends the session before reaching Hermes, barge-in = listener stays open during playback and a speech onset after a 300 ms grace stops the speaker, mute pauses the listener, idle auto-end with the shared warning, cost is 0 #voice
- [gotcha] `ScarfCore` is Swift language mode 5 (Package.swift pins it); the new code is still Sendable-clean with explicit lock-guarded boxes #swift

## Relations
- relates_to [[Live Voice core (ScarfCore/VoiceLive): the engine-agnostic surface both apps bind to]]
- relates_to [[Hermes Voice playback runs text_to_speech_tool on the message's own server, gated v0.20.1]]
- relates_to [[Push-to-talk dictation (ScarfIOS): on-device-only privacy contract + lifecycle teardown pattern]]



## Landed on main 2026-09-19 (merge 3619f216), with two audit rounds

- [gotcha] Apple's recognition callback for a cancelled request lands AFTER the next request is installed, so a "request != nil" guard let the cancel error kill the session after every utterance. Every request carries a monotonic `requestGeneration` and stale callbacks (errors AND results) are dropped. Mute gates the tap inside the request box and restarts recognition on unmute; before that, words heard while muted were transcribed and submitted on unmute #voice #gotcha
- [convention] Speak tasks carry a `speakGeneration` (barge-in, a new utterance and completion bump it) so a stale completion never starts an overlapping chunk; a second `VoiceIdleMonitor` caps a wedged turn at 600 s (`.turnStalled`), mirroring GPTLiveEngine; dropped or refused utterances never enter the model-context note #voice
- [convention] Mac: `VoiceLiveController.start(context:host:engineKind:)` drops a finished engine/bridge once its guards pass (a permission denial on "Start Again" was hidden behind the ended panel); the chained speaker follows the Playback Engine preference (system voice unless the user picked Hermes Voice), and the panel privacy line and Settings TTS row derive from the same `chainedPlaybackEngine(preference:)`. `VoiceLiveController.chainedProduction` is the shipped wiring the tests run on #voice #macos
- [convention] ScarfGo: `blocksDictation` includes `isBeginning` (dictation could start while the two permission prompts were up) and `begin` re-checks dictation-idle after the authorize await; `VoiceLiveSessionModel.productionRecipient(for:)` decides consent; `SettingsView.showsVoiceConversationSection(capabilities:)` is the C1 gate; the audio session is released only because `ChainedVoiceEngine.complete()` stops listener and speaker synchronously first (pinned by test) #voice #ios
- [fact] Mac Info.plist has `NSSpeechRecognitionUsageDescription` in seven locales ("Nothing you say is sent to Apple") #voice #privacy


## Field test 2026-09-22 (Mac, defaults, laptop speaker): the mic hears the TTS

- [gotcha] The Mac listener has NO echo cancellation: `AVAudioEngineTap` taps the raw input node and never calls `setVoiceProcessingEnabled(true)`; `DefaultVoiceAudioSession` only sets `.voiceChat` on iOS. On a laptop speaker the microphone hears Hermes's own reply, so (1) the 0.3 s barge-in grace passes and the level meter fires `.speechStarted` → `bargeIn` → `cancelSpeech`, cutting every reply after its first second; (2) the recognizer transcribes the first spoken word, the 1.2 s stillness rule emits it as an utterance, and it is SUBMITTED to Hermes as a user turn ("Here's", "Hermie", "I" = the first words of "Here's what I found", the busy line "Hermes is still working…", "I already gave you…"); (3) each such phantom turn hits the busy guard and speaks the busy line, which the mic hears again — a self-feeding loop. Hermes's desktop client avoids this with `echoCancellation: true` on getUserMedia plus a playback-phase trigger clamp (PLAYBACK_MIN_TRIGGER_LEVEL 0.14, 500 ms grace, 300 ms sustained majority — apps/desktop/src/lib/voice-barge-in.ts) #voice #gotcha
- [gotcha] Feels like "sent at a pause": end-of-utterance is 1.2 s of unchanged hypothesis with no level check; Apple's on-device recognizer often stops revising during a thinking pause, and its own `isFinal` (which force-`take()`s) also fires on a pause. Hermes desktop uses 1,250 ms too but gated on audio level (silenceLevel 0.075) #voice


## Fix (branch fix/voice-chained-echo-bargein, 2026-09-22): the listener owns every echo rule

- [decision] `VoiceListener.setPlaybackActive(_:)` is the engine's only contribution: `ChainedVoiceEngine.setAssistantSpeaking` flips the reducer flag AND tells the listener; the engine keeps no grace of its own (`Configuration.bargeInGrace` removed) and treats an arriving `.speechStarted` as already qualified #voice
- [decision] Voice processing IS required and IS on (`AVAudioEngineTap`): measured 2026-09-22 with `say` through the MacBook speaker, the reply reads 0.45–0.61 at the mic without it (identical to a person — no threshold can separate them) and 0.06–0.16 with it (channel 0), so echo cancellation works system-wide, even for audio from another process. Two side effects handled in the tap: the input format becomes 10 channels deinterleaved (the speech request silently transcribes nothing from it — the first attempt "heard nothing"), so channel 0 is copied into a mono buffer before the request and the level box; and the OS ducks other audio by default (would duck the reply), so `voiceProcessingOtherAudioDuckingConfiguration` is set to `.min`. Its gain control lifts a silent room to 0.10–0.13, so thresholds were re-based: quiet gate 0.2, idle onset 0.25, playback onset 0.35 (task t-44c4e2ff). `VoiceUtteranceDetector.maxAudioHold` (2× silence) caps how long the quiet gate can delay an utterance so a noisy room can never make the session deaf #voice #gotcha
- [convention] `AppleOnDeviceVoiceListener` rules (no voice processing, see above); onset is `VoiceSpeechOnsetDetector` (3 consecutive 100 ms ticks at/above trigger, released under half the trigger); trigger 0.18 idle / 0.35 during playback (`VoiceAudioLevel.bargeInOnsetLevel`), 0.5 s grace after playback starts; transcripts while playback is active with no confirmed onset never reach the detector or captions; every un-barged playback end restarts recognition (recognition lags audio, so the reply's last word can arrive after playback ends); a confirmed onset during playback restarts once (drops the reply's words) then keeps everything; `VoiceUtteranceDetector.settled` also needs the mic under `silenceLevel` 0.075 for the window #voice
- [gotcha] AEC efficacy of macOS voice processing against AVSpeechSynthesizer / AVAudioPlayer output (a different audio path than the engine's own output node) is unverified in the field; the raised trigger + bleed discard are the guards that hold even if AEC does nothing #voice
