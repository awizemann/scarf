# Request: an official ACP surface for voice-live turns

Draft for the Hermes maintainers. From: Scarf (a native macOS/iOS ACP client for Hermes). Date: 2026-09-18. Every reference is to tag `v2026.9.14` (Hermes 0.21.3).

## Summary

Hermes 0.21.3 added GPT-Live voice chat. When the Hermes desktop app and the TUI gateway submit a turn delegated from a live spoken conversation, they tag it with the `voice-live` surface. Hermes then prepends `voice_live_turn_note(context)` to the model input only, and the persisted user row stays the words the user spoke.

ACP clients have no equivalent. We'd like to ask for a supported way for an ACP client to say "this prompt is a voice-live delegation, and here is the recent spoken context" so that it gets the same treatment.

## What happens today

- **tui_gateway.** `prompt.submit` accepts `surface: "voice-live"` and `voice_context` (`tui_gateway/contracts/prompt_voice.py:36-37`). `voice-live` is one of the `_CLIENT_SURFACES` (`tui_gateway/methods_prompt.py:541`), and the voice context is capped at 6,000 characters (`:586-588`). The note is built by `voice_live_turn_note(context)` (`tools/voice_live.py:84-90`), chosen by `_hud_surface_note` (`tui_gateway/session_notifications.py:683-705`) and prepended to the model input only (`tui_gateway/prompt_turn.py:513`). The prompt stays the persisted row (`prompt_turn.py:544-545`).
- **ACP.** `HermesACPAgent.prompt()` (`acp_adapter/server.py:781`) takes the content blocks and `**kwargs`, but doesn't read `_meta` or any surface hint. The persisted row is `_extract_text(prompt)` (`server.py:788`, `:773-776`).

## What Scarf does in the meantime

Scarf sends the note as an ACP `EmbeddedResource` text block, placed before the text block:

```json
[{"type":"resource","resource":{"uri":"scarf://voice-live/voice-live-turn-note","mimeType":"text/plain","text":"<voice_live_turn_note(context)>"}},
 {"type":"text","text":"the dentist one, thursday not friday"}]
```

This works for two reasons:
- `_extract_text` joins only blocks that have `.text` (`acp_adapter/content.py:224-226`), so the persisted row is the spoken words alone.
- `_content_blocks_to_openai_user_content` inlines embedded-resource text into the model input (`content.py:249-275`, via `_embedded_resource_to_parts`, `:185-194`).

The result matches tui_gateway's persistence, with a clean `content` and the note in the `api_content` sidecar (`agent/session_persistence.py:78-87`, `:157-162`). We check this in a contract test that runs Scarf's exact blocks through `acp.schema.PromptRequest` and those two functions.

There's one exception. When a new spoken request supersedes a turn that is still running, Scarf cancels that turn, waits for it to return, and then sends the new request as plain text with no note. `cancel()` stores the cancelled prompt as `interrupted_prompt_text` (`server.py:617-619`), and only a text-only prompt consumes it (`_rewrite_prompt_for_interrupt`, `:680-693`). A text-only superseding turn is therefore framed as a correction of the cancelled request (`_attach_interrupted_prompt`, `:201-202`). A note-bearing one would leave the cancelled prompt behind, to be attached to the chat's next typed message. The cost is that this one turn loses the voice note.

The approach has four weaknesses:
1. **Undocumented tolerance.** Hermes doesn't advertise `promptCapabilities.embeddedContext` (`server.py:517` sets only `image=True`), so we depend on lenient parsing that could change without notice.
2. **The note is lost while a turn is busy.** A prompt that isn't text-only and arrives during a running turn is queued as `user_text` only (`_claim_turn_or_queue`, `server.py:696-715`), which drops the note. Scarf avoids this by cancelling the running turn and waiting for it to finish before it submits.
3. **Interrupt handling ignores prompts with resources.** Because `_rewrite_prompt_for_interrupt` returns early for any prompt that isn't text-only (`:680-681`), a superseding voice turn has to give up the note. And if the user cancels a typed turn with Stop and the next turn is a note-bearing voice turn, the cancelled prompt still survives to the next typed message.
4. **A vendored copy.** Scarf has to keep its own copy of `VOICE_LIVE_TURN_NOTE` (`tools/voice_live.py:73-81`) and refresh it at every release. The model also sees an `[Attached file: voice-live-turn-note]` header that tui_gateway turns don't have.

## What we're asking for

Any of the following would work for us, in order of preference:

1. **A `_meta` surface on `session/prompt`**, for example `_meta: {"hermes": {"surface": "voice-live", "voiceContext": "<User:/Voice assistant: lines>"}}`. `prompt()` would then apply the same surface-note path that tui_gateway uses, keep the persisted row as the text blocks, and advertise support somewhere a client can detect, such as `agentCapabilities._meta.hermes.voiceLive: true` in `initialize`. Clients would stop vendoring the note, and the busy-queue and interrupt paths could carry the surface along. A superseding voice turn could then keep its note.
2. **Make the current approach official.** Advertise `promptCapabilities.embeddedContext: true` and keep the resource-text inlining stable. Ideally the queued-prompt path would also keep `user_content` when the queued prompt isn't text-only, and a prompt carrying resources would consume (or explicitly clear) `interrupted_prompt_text` the way a text-only one does.
3. **Expose the note.** For example, `voice_live_turn_note` through an ACP extension method or the session info, so that clients don't have to copy it.

We're glad to test a branch against Scarf's contract tests, or to send a PR for option 1 if you'd accept one.

## Also useful (lower priority)

- **Session exchange over ACP.** Clients without the dashboard currently run `tools.voice_live.create_webrtc_session` in the Hermes venv from a host script to keep the OpenAI key on the host. An ACP extension method for the SDP exchange (and `resolve_gpt_live_status`) would give ACP clients a supported path.
- **A delegation-done signal.** The desktop infers the end of a delegated turn from busy-then-idle and a 15 s grace period (`use-voice-live-conversation.ts:412-425`). For ACP, the return of `session/prompt` already marks it, so we don't need anything more here.
- **A question on billing, if you know the answer.** If a client abandons a session after `create_webrtc_session` has POSTed to `/live/sessions` but before any media connects (the user ends during connecting, or a client-side timeout), the vendor session exists but is never used. We haven't verified whether OpenAI bills that session from creation until its own timeout. Knowing would help every client decide how hard to try to close it.

Thank you. GPT-Live delegating to Hermes is a great design, and we'd like ACP clients to be first-class citizens of it.
