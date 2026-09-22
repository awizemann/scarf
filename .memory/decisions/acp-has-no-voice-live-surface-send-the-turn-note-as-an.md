---
title: ACP has no voice-live surface: send the turn note as an embedded resource block
type: note
permalink: scarf/decisions/acp-has-no-voice-live-surface-send-the-turn-note-as-an
tags: [acp, voice, gpt-live]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/VoiceLive/VoiceConversationEngine.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/VoiceLive/VoiceLiveTurnNote.swift, scarf/Packages/ScarfCore/Tests/ScarfCoreTests/VoiceLiveTurnNoteContractTests.swift]
source_paths_inferred: false
source_sha: 904c0e60784d0936f39ccbd47242201c12ef23d0
created: 2026-09-18
updated: 2026-09-18
reviewed: 2026-09-22
reviewed_by: audit:claude-code (background)
---

Recommended in the P3 Live Voice spike (documents/plans/2026-09-18-live-voice-spike.md section 4); Alan approved it on 2026-09-18 and P4 shipped it (see the section below). Verified offline against Hermes's own acp.schema + acp_adapter.content in the v2026.9.14-equivalent venv; not yet run as a real turn. Since P4, chained engine support was added with its own parallel note infrastructure.

## Observations
- [fact] The voice-live surface exists only in tui_gateway (methods_prompt.py:541, 582-588): VOICE_LIVE_TURN_NOTE + spoken context go to model input only via _prepend_note; ACP prompt() ignores _meta and persists persist_user_message=user_text (acp_adapter/server.py:773-781 @ v2026.9.14) #acp #voice
- [decision] Send the note as an ACP EmbeddedResource text block BEFORE the text block: acp_adapter/content.py _extract_text (the persisted row) reads only blocks with .text, while _content_blocks_to_openai_user_content inlines resource text into model input — persisted content stays the spoken words, api_content sidecar holds the note, matching tui_gateway parity #acp #voice
- [fact] `VoiceTurnRequest` has a `noteStyle: VoiceTurnNoteStyle` field (default `.voiceLive`) that gates which note (if any) is sent; the enum has three cases: `.voiceLive` (sends `VoiceLiveTurnNote`), `.chained` (sends new `VoiceChainedTurnNote`), and `.none` (no note). The `contextNotes` computed property switches on noteStyle to pick the note implementation #voice
- [fact] `VoiceChainedTurnNote` is a parallel note structure for the chained engine, with its own wording: it tells the model "a text-to-speech voice reads the reply out VERBATIM" (vs. voice-live's "a voice model paraphrases your reply"). Both ride the model input as embedded resources; only the spoken words persist to the transcript #voice #chained
- [gotcha] Hermes does not advertise promptCapabilities.embeddedContext (server.py:517 image=True only) — this relies on tolerant parsing; pin with a tag-cited contract test and recheck each Hermes release audit #acp
- [gotcha] A non-text-only prompt arriving while a turn is busy is queued as user_text only (server.py _claim_turn_or_queue), silently dropping the note — cancel and await sendPrompt's return before submitting a superseding voice turn #acp #voice
- [idea] Rejected alternatives: prefixing the note in the text persists it into state.db transcript/titles/search; sending no note loses spoken context and yields markdown-heavy replies #voice

## Relations
- relates_to [[ACP turn completion is sendPrompt's return, not a stream .promptComplete event]]
- relates_to [[GPT-Live client-delegation data-channel protocol (Hermes desktop reference)]]



## Approved and shipped (P4, 2026-09-18)

- [decision] Alan approved option A. It is implemented as `ACPClient.sendPrompt(sessionId:text:images:contextNotes:)`, where `ACPContextNote` resources go before the text block and a note-free call keeps the payload unchanged. `VoiceLiveTurnNote` vendors the note text, and `VoiceTurnRequest.contextNotes` builds it #acp #voice
- [testing] `VoiceLiveTurnNoteContractTests` pins the note's SHA-256 against the tagged `voice_live.py`, which runs in CI. When `~/.hermes/hermes-agent` has a venv and a `git diff --quiet v2026.9.14` on the relevant files is clean, it also feeds Scarf's exact blocks through Hermes's own `PromptRequest` / `_extract_text` / `_content_blocks_to_openai_user_content` #testing
- [decision] Only first turns carry the note; a SUPERSEDING voice turn is sent TEXT-ONLY (decided 2026-09-18, commit 464c8ca2). Reason: `session/cancel` stores the cancelled turn as `interrupted_prompt_text` (`server.py:617-619` @ v2026.9.14) and only a text-only, non-slash prompt consumes it (`_rewrite_prompt_for_interrupt`, `:680-693`). A note-bearing superseding turn left it to be attached to the chat's NEXT TYPED prompt. The text-only turn consumes it and Hermes frames the new words as "<cancelled>\n\nUser correction/guidance after interrupt: <spoken>" (`_attach_interrupted_prompt`, `:201-202`), which is also the stored row. That one turn loses the voice note. Mechanism: `VoiceTurnRequest.supersedesCancelledTurn` makes `contextNotes` empty (via the noteStyle switch), and `VoiceTurnReply.latest` matches the rewritten row. `GPTLiveEngine.cancelledTurnPending` carries the debt. Any cancel sets it, even when a newer delegation supersedes the cancelling one while the cancel is awaited, and it clears only after a text-only submit reaches Hermes (cce59401) #acp #voice
- [testing] A tag-gated contract test runs Hermes's own `_rewrite_prompt_for_interrupt` on Scarf's blocks: text-only consumes the stored prompt, and note-bearing leaves it behind. Still open: if a TYPED turn was cancelled by the user (Stop button) and the next turn is a first voice turn carrying the note, the stored prompt survives to the next typed message. The upstream request asks Hermes to consume it for resource-bearing prompts too #acp #testing


- [decision] (F3, t-daa906da) The debt `GPTLiveEngine.cancelledTurnPending` described above now lives in `VoiceTextOnlyTurnLedger`, keyed by `VoiceTurnHost.voiceChatID` (the ACP session id). Before this, the Mac and ScarfGo built a new engine per voice session, so the debt was lost when the session ended mid-cancel. A host with no chat id falls back to the engine-local flag #acp #voice
- [decision] (Post-P4) The chained engine sends its own `VoiceChainedTurnNote` by passing `noteStyle: .chained` when building a `VoiceTurnRequest`. The note tells the model text-to-speech will read the reply verbatim (no markdown, no lists), matching the chained engine's behavior. Voice-live continues to send `VoiceLiveTurnNote` (noteStyle defaults to `.voiceLive`); either way, only the first turn carries the note #voice #chained
