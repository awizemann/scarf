---
title: Hermes Voice playback runs text_to_speech_tool on the message's own server, gated v0.20.1
type: note
permalink: scarf/architecture/hermes-voice-playback-runs-text-to-speech-tool-on-the
tags: [voice, tts, capabilities, security, multi-server]
source_paths: [scarf/scarf/Core/Services/MessageSpeechService.swift, scarf/scarf/Features/Chat/Views/RichMessageBubble.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-09-18
updated: 2026-09-19
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

Settings > Voice > Playback Engine "Hermes Voice" (P2 hardening, branch feat/voice-p2, task t-e267092a). HermesSpeechService runs one opaque script over ServerTransport.streamScript that imports tools.tts_tool.text_to_speech_tool in the hermes binary's interpreter and calls it with output_path only.

## Observations
- [invariant] No app-wide current server: SpeakMessageButton passes its environment \.serverContext (window profile scope, or the bot's context in BotConversationView) in a PlaybackID(server, messageId) on every toggle, so message text only ever goes to the server it came from; playback state keys on the PlaybackID because message ids are per-state.db #voice #multi-server
- [decision] hasHermesSpeechSynthesis = v0.20.1 (v2026.8.13): first tag with the file_path+file_paths envelope and .chunkNNN/.partNN naming (tools/tts_tool.py:3669-3670, :3612-3613); provider kwarg is 0.19.1 but Scarf never passes it because an explicit provider bypasses Hermes's nous->openai mapping (_get_provider, tts_tool.py:140-144 @ v2026.9.14). Below the floor the picker is hidden and the system voice plays #capabilities #voice
- [invariant] Path safety: the script writes into a private 0700 $TMPDIR/scarf-tts-<uid>/ (refused if symlink or foreign-owned), prints SCARF_TTS_BASE before Hermes runs (first line wins), and only paths Hermes derives from that base (suffix swap, .chunkNNN, .partNN, same dir) are read or deleted; any other envelope path aborts with nothing touched #security #voice
- [gotcha] Hermes's default provider edge writes MP3 into a .wav output_path (_generate_edge_tts, tools/tts_tool_providers.py:196-204), so playback accepts WAV/MP3/FLAC/AIFF by magic bytes; WAV-only silently fell back to the system voice for most users #voice
- [convention] Config paths in the script use HermesProfileScope.shellQuotePath (leading ~ is the only live $HOME); the interpreter is the hermes binary's shebang python, then python beside readlink -f; audio cache lives in ~/Library/Caches/scarf/tts keyed by server id + profile home #voice #security

## Relations
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[GPT-Live session exchange runs as a host script, not via the Hermes dashboard]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]



## F6 fix (t-30cee401, 2026-09-19)

- [gotcha] `HermesTTSCache.evictOverflow` groups files through the pure, order-independent `groupForEviction(files:)`: `contentsOfDirectory` returns files in unspecified order, and the old code replaced the stem's entry when the `.json` manifest was seen after its `-NN` chunks, so those chunks were never counted toward the 256 MB cap nor deleted. The cap is now injectable (`init(directory:maxBytes:)`) and `HermesTTSCacheTests` drives a real eviction pass on disk #tts #cache
- [gotcha] `ProjectConfigKeychain.setIfAbsent` against the real Keychain is `SecItemAdd` only; `errSecDuplicateItem` returns the stored value via `get`. It used to be a plain `set` (SecItemUpdate first), which would have overwritten the mini-app grant signing key and invalidated every issued grant #keychain
