---
id: t-44c4e2ff
title: Bring echo cancellation back to the chained voice listener (mono down-mix + re-measured quiet gate)
status: done
added: 2026-09-22
---

## Description

`AVAudioEngineTap` (scarf/Packages/ScarfCore/Sources/ScarfCore/VoiceLive/VoiceListener.swift) deliberately does NOT call `inputNode.setVoiceProcessingEnabled(true)`. Tried on 2026-09-22 (branch fix/voice-chained-echo-bargein) and measured on an Apple-silicon MacBook with a 3 s tap script: without VP the input is 1 ch 48 kHz Float32 and a quiet room reads -54.5 dBFS (meter 0.0); with VP the input format becomes 10 ch 48 kHz deinterleaved and the same room reads -43.7 dBFS (meter 0.13). Feeding the 10-channel buffer to SFSpeechAudioBufferRecognitionRequest produced no hypotheses at all (the session "heard nothing"), and 0.13 resting level sits above the 0.075 quiet gate. To bring it back: down-mix/convert to mono (AVAudioConverter in the tap, or tap a mono-format mixer without routing to output) before appending to the request and before the level box; re-measure the resting level and pick the quiet gate from that; verify AEC actually cancels AVSpeechSynthesizer / AVAudioPlayer output (a different path from the engine's own output node) before claiming it. Until then the listener's raised trigger, sustained onset and bleed discard are the echo guards.

## Plan



## Artifacts



