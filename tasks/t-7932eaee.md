---
id: t-7932eaee
title: Voice P7b: Mac binds the chained engine (three-way button, Settings › Voice)
status: done
added: 2026-09-19
priority: high
---

## Description

After P7a. VoiceLiveController mounts `ChainedVoiceEngine` when availability is `.chainedReady` and `GPTLiveEngine` when `.ready`; the composer button shows for both (C1: hidden below 0.20.1). Panel copy for a free session (no cost line, "on this Mac" privacy line). Mac Info.plist NSSpeechRecognitionUsageDescription + InfoPlist.xcstrings (done by Claude 2026-09-19). Settings › Voice becomes one section: mode picker (chained/gpt-live), Live row status, chained rows showing resolved STT (on this Mac) and TTS provider from tts.provider with free/paid badge, playback engine picker reuse. Mute MessageSpeechService while a session runs. Tests in VoiceLiveMacTests.

## Plan



## Artifacts



