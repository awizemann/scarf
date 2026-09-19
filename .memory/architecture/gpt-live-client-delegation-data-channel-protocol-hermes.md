---
title: GPT-Live client-delegation data-channel protocol (Hermes desktop reference)
type: note
permalink: scarf/architecture/gpt-live-client-delegation-data-channel-protocol-hermes
tags: [voice, gpt-live, protocol, hermes-desktop]
created: 2026-09-18
updated: 2026-09-18
---

Source of truth: Hermes tag v2026.9.14 apps/desktop/src/lib/voice-live.ts and apps/desktop/src/app/chat/composer/hooks/use-voice-live-conversation.ts. Scarf's GPT-Live engine ports this loop; full event list in documents/plans/2026-09-18-live-voice-spike.md section 3.

## Observations
- [fact] Data channel oai-events must be created before createOffer; server events handled: session.started, session.input_transcript.delta / session.output_transcript.delta (delta,start_ms,end_ms), session.delegation.created {delegation:{id}}, error (ignore code context_injection_incomplete), session.closed {reason, usage.seconds} #voice #protocol
- [gotcha] session.delegation.created carries NO text: the client builds the Hermes prompt from the transcript window (last merged user utterance = persisted prompt; User:/Voice assistant: lines = model-only context), per delegationPrompt in use-voice-live-conversation.ts:46-68 #voice
- [fact] Client sends session.commentary.append {delegation_id, content} for what the voice speaks (sentence-chunked, max 1400 chars each), session.thinking.append for quiet tool progress, session.instructions.append, session.input_audio.mute/unmute, and session.close then waits 15 s for session.closed #voice #protocol
- [gotcha] There is no delegation-done event: the desktop treats a turn as settled once seen busy (or replied) and idle again, sends a thinking note if nothing was spoken, and interrupts a still-busy turn when a new delegation arrives (Hermes-level barge-in) #voice
- [fact] GPT-Live bills $0.05/min of open session on the host's OpenAI key (tools/voice_live.py:18-20); every exit path must send session.close #voice #cost

## Relations
- relates_to [[GPT-Live session exchange runs as a host script, not via the Hermes dashboard]]
