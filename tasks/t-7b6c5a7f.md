---
id: t-7b6c5a7f
title: No stt.xai surface, and stt.local_command is unreachable in the UI
status: todo
added: 2026-09-10
priority: low
---

## Description

Found during P20 (`t-6679d648`) while implementing product decision 4 (voice provider rosters).

Hermes's `BUILTIN_STT_PROVIDERS` (`tools/transcription_common.py:45` @ v2026.9.7) is `{local, local_command, groq, openai, mistral, xai, elevenlabs, deepinfra}`. P20 added `elevenlabs` and `deepinfra` to `SettingsViewModel.sttProviders` behind their v0.19.0 floor (first set: tag v2026.7.20; absent at v2026.7.7.2 = v0.18.2), per the binding decision, and deliberately left two out:

- `xai` has been a built-in STT provider since tag v2026.5.28 (v0.15.0) — well inside the supported window — but Scarf has no `stt.xai.*` fields at all in `VoiceSettings` (`scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift`) and no rows in `VoiceTab.swift`. Offering the pin without the settings behind it would be half a feature, so it was skipped rather than added blind. Decide whether to add the surface (mirroring the existing `tts.xai.*` block) or to offer the bare pin.
- `local_command` is the marker for a user-defined command provider configured through `stt.local_command.*`, not a name a user picks from a list. Confirm that reading and no surface is the right answer.

Also worth a look while in there: P20 gated `deepinfra` in the TTS picker behind the existing `hasDeepInfraTTS` (v0.19.0) flag; before P20 that row was offered ungated on every host, which is the same "pre-existing row stays ungated" exception the charter's roster-gating decision (decision 6) carves out for `bluebubbles`. If that exception was meant to apply here too, the gate should come back off.

## Plan



## Artifacts



