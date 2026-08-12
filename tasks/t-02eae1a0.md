---
id: t-02eae1a0
title: P3c: Settings — STT/TTS knob expansion
status: done
added: 2026-08-12
---

## Description

Phase 3 item 1 from t-1cc0a505. stt.language (global, default en), stt.openai.language, stt.groq.{model,language}, stt.local.* VAD knobs; tts.speed (global), tts.xai.{language,speed,text_normalization,optimize_streaming_latency,sample_rate,bit_rate}, tts.deepinfra.{model,voice}. Extend the existing STT tab + tts.xai groups. Gate on isV020OrLater; verify each key against ~/.hermes/hermes-agent (v2026.8.3) config_defaults.py. Tests required. Plan: documents/hermes-leftovers-2026-08-12-plan.md.

## Plan



## Artifacts



