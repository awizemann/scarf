# Scarf vX.Y.Z — Voice (draft, version TBD)

*Draft release notes for the voice feature set on `feat/voice`. Version number, date, and final wording are set at release prep — see [`scarf-release-prep`](../../.claude/skills) / `documents/plans/2026-09-18-live-voice-spike.md` for the source design. Style follows `releases/v3.2.0/RELEASE_NOTES.md`.*

This release gives Hermes a voice in three ways: dictate a message instead of typing it, hear replies spoken by Hermes's own text-to-speech provider, and hold a live spoken conversation with Hermes that still runs your full model and toolset.

## Push-to-talk dictation (ScarfGo)

Hold the mic button in the composer, speak, and release — on-device speech recognition fills the draft for you to review and edit before sending. It's strictly on-device: if your phone or language can't transcribe locally, ScarfGo says so and records nothing, rather than quietly falling back to Apple's servers. Contributed by [@danmarauda](https://github.com/danmarauda) ([PR #143](https://github.com/awizemann/scarf/pull/143)).

## Hermes Voice playback (Mac)

Settings → Voice → Playback Engine now offers **Hermes Voice** alongside the existing System Voice. Hermes Voice speaks assistant replies through the connected server's own configured text-to-speech provider (Edge, ElevenLabs, OpenAI, NeuTTS, xAI, DeepInfra — whatever Settings → Voice → Text-to-Speech has set), and falls back to the system voice if the server can't synthesize. Needs Hermes v0.20.1 or later — older hosts see only System Voice, exactly as before. Each message speaks on the server it actually came from, so two windows on two different servers never cross wires. Contributed by [@danmarauda](https://github.com/danmarauda), hardened afterward for multi-server safety and the version gate.

## Live Voice (Mac and ScarfGo)

A full two-way spoken conversation with Hermes, from the chat composer on both platforms. It runs on Hermes's own **GPT-Live** mode: an OpenAI voice model listens and talks in real time, and hands every real request to Hermes as a normal turn — so replies come from your selected model with your full toolset, the same as typing.

Setup, once per Hermes host:

1. Hermes v0.21.3 or later.
2. Settings → Voice → Voice Chat Mode → **GPT-Live** (Hermes's default is Chained). This is a Hermes setting for the whole profile: it also switches voice to GPT-Live in Hermes's own apps.
3. An OpenAI API key on the host (`OPENAI_API_KEY` in its `.env`, or `voice.gpt_live.api_key`). The key stays on the host — Scarf never sees it.

**What leaves your device.** The Hermes host only sets up each session. Your voice then streams directly from your Mac or phone to OpenAI over WebRTC, so OpenAI also sees your device's network address, and each session sends OpenAI recent messages from the chat as context (up to 24 messages, about 6,000 characters). Before the first session on each device, Scarf and ScarfGo show a one-time consent that says so; Cancel starts nothing and bills nothing, and Settings can review or reset it. Scarf never picks a voice model or provider — it uses the voice setup you chose in Hermes and asks only when that setup sends your data to a third party.

The waveform button next to Send appears once the first two conditions are met; if the key is still missing, starting a session reports that plainly instead of connecting — nothing is billed. Cost is about **$0.05 per minute** of session time, billed to that key — the panel shows elapsed time and an approximate running cost, and an idle session (about three minutes without speech) ends itself so a forgotten tab doesn't keep billing. Closing the window, switching sessions or servers, or quitting ends any open session immediately on every exit path.

A free, local alternative — Hermes's "chained" voice mode (speech-to-text → a normal turn → text-to-speech with a free provider) behind the same button — is being evaluated for a future release.

## Thanks

[@danmarauda](https://github.com/danmarauda)'s [PR #143](https://github.com/awizemann/scarf/pull/143) started this: push-to-talk dictation and Hermes Voice playback are built on that contribution, and its phase model, barge-in handling, and testing approach shaped how Live Voice's GPT-Live engine was built.

## Upgrade notes

- Every voice feature is capability-gated: hosts below the version floors above render exactly as before.
- Live Voice needs a Hermes host on v0.21.3+ with an OpenAI key of your own; nothing is spent until you start a session.
- Compatible with the same Hermes range as the rest of this release — see [Hermes Version Compatibility](https://github.com/awizemann/scarf/wiki/Hermes-Version-Compatibility).
