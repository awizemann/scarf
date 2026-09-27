# S02-chat-events — verdict: WORKS-WITH-ISSUES

Scope: how Scarf consumes a turn's `session/update` stream and the `session/prompt` result, and how the live transcript relates to state.db afterwards. Files read in full: `RichChatViewModel.swift` (all 3578 lines), `ChatImageAttachment.swift`, `SessionCostDisplay.swift`. `ChatViewModel.swift` (Mac) was read for the send, event-loop, autostart, reconnect, stop and title paths. `ACPMessages.swift` (the parser, which S01 owns) was read to learn which discriminators reach the view model. Hermes reference: `~/.hermes/hermes-agent-v0215` @ v2026.9.24, plus its bundled `acp` lib 0.9.0 (`.venv/.../site-packages/acp`).

## What Hermes v2026.9.24 emits during a turn (complete inventory)

Serialization uses camelCase aliases with `exclude_none` (`acp/connection.py:209-210`).

| sessionUpdate | Emitter | Fields actually sent |
|---|---|---|
| `agent_message_chunk` | `events.py:220-236,247-252` (streamed); `server.py:972-982` (unstreamed final); `server.py:833,842` (slash-command replies, "Queued…"/"Redirected…" absorb text); `server.py:139` (replay) | `content{type:text,text}`, `messageId` (UUID, streamed/final only; **absent** on slash/absorb text), `_meta.hermes.compactionSummary`/`containsCompactionSummary` (replay only) |
| `agent_thought_chunk` | `events.py:239-244`; replay `server.py:138` | text and `messageId` (the allocator is shared with message chunks) |
| `user_message_chunk` | replay `server.py:133`; queued-prompt drain `server.py:1010` | text, `_meta` (replay) |
| `tool_call` | `tools.py:781-815` via `events.py:175` | `toolCallId` `tc-<12hex>`, `title` `"name: preview"`, `kind`, `content` (text, or `diff` when an edit is auto-approved), `locations[{path,line}]`. **`rawInput` only for unknown/plugin tools** (`tools.py:809-811`). No `status`. |
| `tool_call_update` | `tools.py:818-835` (complete); `tools.py:838-847` (turn-end abandon flush, `events.py:97-116`); `permissions.py:113` (`perm-check-N` / `edit-approval-N`, no start ever sent) | `status` completed/failed, `kind`, `content` (text, or `diff` for skill_manage), `rawOutput` (only non-polished, non-JSON results). Never `rawInput`. |
| `plan` | `events.py:30-52,294` (todo tool) | `entries[{content,priority,status}]` |
| `usage_update` | `server.py:362-378` | `size`, `used` (no `cost`) |
| `session_info_update` | `server.py:393-420` (auto-title, compression rotation) | `title`, `updatedAt`, `_meta.hermes.sessionProvenance` |
| `available_commands_update` | `commands.py:85-94` | `availableCommands[{name,description,input{hint}}]` |
| (`current_mode_update`, `config_option_update`) | never emitted at this tag | — |

`session/prompt` result (`server.py:991-999`): `stopReason` ∈ {`end_turn`, `cancelled`, `refusal` (session not found, `:816`)}. `usage{inputTokens,outputTokens,totalTokens,thoughtTokens?,cachedReadTokens?}` holds **session-cumulative** agent counters (`agent/turn_finalizer.py:31-33,633`). Agent exceptions return `end_turn`, with `"Error: …"` as the message text (`server.py:807-809`).

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Send a text prompt and stream the reply (message and thought chunks, throttled upsert, finalize) | WORKS | — |
| 2 | A turn that runs tools (start/update pairing, parallel ids, status→exit code, abandoned-call flush, synthetic permission-bubble updates dropped) | DEGRADED | F2 |
| 3 | Turn end: `end_turn` / `cancelled` / `refusal`, the no-output failure bubble, error banner, `isAgentWorking` clear, queue-chip drain | WORKS | — |
| 4 | Token and cost display after a turn (`refreshSessionFromDB`, `SessionCostDisplay`) | WORKS | (latent note in inventory) |
| 5 | Image attachments on the wire (`ImageContentBlock` data+mimeType → `_image_block_to_openai_part`) | WORKS | F1 (echo reconciliation) |
| 6 | Mid-turn sends (`/steer`, `/queue`, plain-text redirect) | DEGRADED | F4, F1 |
| 7 | Resume a session: replay dropped by the engagement gate, DB skeleton plus tool hydration | WORKS | — |
| 8 | Reopen a chat in the same app run, or reconcile after an auto-reconnect | DEGRADED | F1 |
| 9 | Type after the connection was lost (autostart with the existing session id → `session/load`) | DEGRADED | F3 |
| 10 | Session auto-title via `session_info_update` → sidebar | WORKS | — |
| 11 | ACP command advertisement via `available_commands_update` → slash menu | WORKS | (S03 owns the menu) |

## Findings

### S02-chat-events-F1 · P2 · SOURCE · NEW
- **Claim:** the optimistic-echo cache (`pendingLocalUserMessages`) and `reconcileWithDB` treat a local user bubble as persisted only when a DB user row has byte-identical content. Many ordinary sends are persisted with different text, or never persisted as a user row, so the local copy is re-injected next to the real row every time the chat is reopened in that app run, and again after a reconnect.
- **Scarf:**
  - `RichChatViewModel.swift:1993-1995` caches every echo.
  - `:3018-3036` clears an entry only when `msg.isUser && msg.id >= 0 && msg.content == local.content`; otherwise it re-appends the entry.
  - `:2873-2876` (`reconcileWithDB`) applies the same equality rule.
  - The echo is the literal typed text, but the wire gets something else: `ChatViewModel.swift:1342` echoes `text`, while `:1384-1385` sends `wireText` (idle `/queue` fallback, or a project/global `/scarf-*` expansion).
- **Hermes @v2026.9.24:**
  - `server.py:805` persists `persist_user_message=user_text`, where `user_text` is the extracted or rewritten text (`:818`, `:824` for idle `/steer`, i.e. `_rewrite_prompt_for_interrupt` `:712-723`).
  - For image prompts the plain-text override is refused (`agent/session_persistence.py:69-77`), and the row becomes `_durable_content` = text parts joined with `"[screenshot]"` (`:108-119`, applied at `:212`).
  - ACP slash commands (`/help`, `/model`, `/compress`, `/version`, a mid-turn `/steer`, `/queue`) return at `server.py:827-837` without running the agent, so they never produce a user row.
- **Failure scenario:** the user runs the bundled `/scarf-help` (or any project slash command), or sends "look at this" with an image, or types `/queue foo` on an idle session. They switch to another chat and come back. The transcript now shows two user bubbles: the literal `/scarf-help` echo and the expanded prompt Hermes stored (or "look at this" beside "look at this\n[screenshot]"; `/queue foo` beside `foo`). Every `/help`, `/model` or `/compress` the user typed also reappears as an orphan bubble with no reply. This repeats on every reopen until the app restarts, and the same duplication happens right after a successful auto-reconnect.
- **Evidence:** `persisted = merged.contains { msg.isUser && msg.id >= 0 && msg.content == local.content }`, with `if !merged.contains(where: { $0.id == local.id }) { merged.append(local) }` as the else-branch. iOS echoes `"[image attached]"` for image-only prompts (`Scarf iOS/Chat/ChatView.swift:2098`), which never equals Hermes' `"[screenshot]"`.
- **Suggested fix:** record the wire text (or a "no user row expected" flag for dispatched ACP slash commands) alongside each cached echo. Match against that value, or retire entries by send time, not by display text.

### S02-chat-events-F2 · P2 · SOURCE · NEW
- **Claim:** live tool cards never get arguments for any built-in Hermes tool. Scarf keeps only the function name from `title` and relies on `rawInput`, but Hermes sends `rawInput` only for unknown/plugin tools and never on `tool_call_update`. As a result, consecutive calls to the same tool on different targets collapse into one "×N" entry.
- **Scarf:**
  - `ACPMessages.swift:290-309`: `functionName` is split off the title and the title's preview is discarded; `argumentsJSON` becomes `"{}"` when `rawInput` is nil.
  - `RichChatViewModel.swift:2359-2365` stores `arguments: call.argumentsJSON`.
  - The backfill at `:2449-2458` relies on `update.argumentsJSON`, which is always nil at this tag.
  - Collapse by `arguments ==` is at `:285-294`, rendered as the `×N` badge (`ActivityBubble.swift:293-294`).
  - The card and inspector show `argumentsSummary` / `arguments` (`ToolCallCard.swift:62,121`; `ChatInspectorPane.swift:244`).
- **Hermes @v2026.9.24:** `tools.py:797-815` sets `raw_input` only in the "unknown tool with arguments" branch. Terminal, read_file, patch, write_file, search_files, web_search, todo, memory and the other built-ins all get `raw_input=None`, and their target lives in `title` (`build_tool_title`, `:193-198`) and `locations`. `build_tool_complete` (`:818-835`) never sets `raw_input`.
- **Failure scenario:** the agent reads `a.swift`, `b.swift` and `c.swift` in a row. The live ActivityBubble shows one "read_file ×3" card with no path, and the inspector's input is `{}`. Three `terminal` calls with different commands collapse the same way, with no command shown. The correct separate cards only appear after the chat is reopened from state.db.
- **Evidence:** the code comment at `ACPMessages.swift:321-325` ("Hermes sometimes omits `rawInput` on the initial `tool_call` event and only populates it here") does not hold at this tag. No update carries `rawInput`.
- **Suggested fix:** keep the title's preview (and `locations[0].path`) on `HermesToolCall` for display, and include it in the collapse key when `arguments == "{}"`.

### S02-chat-events-F3 · P2 · SOURCE · NEW (adjacent to accepted-low #2 in `.memory/architecture/chat-session-layer-mechanism-map-and-2026-07-13-diagnosis.md:37`, which covers only stragglers *after* `markPromptSent`)
- **Claim:** when the user types after the connection was lost, `autoStartACPAndSend` echoes the message first, which opens the replay gate. It then starts the event loop and calls `session/load` for the same session id. Hermes streams the entire history as live updates inside that load call, and Scarf renders it as new streaming content.
- **Scarf:** `ChatViewModel.swift:1160` (`addUserMessage` sets `hasUserSentPromptThisSession = true`, `RichChatViewModel.swift:1964`). Then `:1194` (`startACPEventLoop`), then `:1211` (`loadSession(existing)`). The gate is only reset by `setSessionId` at `:1240`, after the load returns. Replay events pass both the cross-session guard (same id) and the gate (`RichChatViewModel.swift:2112-2156`), and `ACPClient` yields them unfiltered (`ACPClient.swift:1013-1017`).
- **Hermes @v2026.9.24:** `server.py:579-589` awaits `_replay_session_history` before returning the load response. `_history_replay_updates` (`:125-167`) emits agent text, thoughts, and tool_call/tool_call_update pairs for the whole persisted history.
- **Failure scenario:** on an SSH host the process dies and the reconnect ladder is exhausted (showing "Connection lost…"). The user types a new message. The transcript fills with the session's past assistant text, thoughts and tool cards, split at each replayed tool update and placed *after* the new user bubble. The new reply's chunks then append onto the last replayed text in the same streaming buffer, because `setSessionId` does not clear it. This stays until the chat is reopened. The exact amount of leaked replay depends on MainActor interleaving, but the event loop runs throughout the load RPC.
- **Suggested fix:** in `autoStartACPAndSend`, echo after `session/load` returns (or reset the gate and streaming buffers before the load), or start the event loop after the load, as `attemptReconnect` does.

### S02-chat-events-F4 · P3 · SOURCE · NEW
- **Claim:** Scarf ignores `messageId` on message chunks, so Hermes' out-of-band status replies for mid-turn sends get concatenated, with no separator, onto the running turn's next streamed text (and, for a drained queue, the queued turn's reply too).
- **Scarf:** `ACPMessages.swift:419-427` does not parse `messageId`. `RichChatViewModel.swift:2301-2316` appends every chunk to `streamingAssistantText`. A mid-turn send finalizes the bubble first (`:1971-1973`), so the status text opens a new bubble that the resumed turn keeps appending to.
- **Hermes @v2026.9.24:**
  - A plain mid-turn prompt is redirected or queued and answered with "Redirected the active turn with your correction." or "Queued for the next turn. (N queued)" (`server.py:736-745,841-843`).
  - `/steer` and `/queue` answer with "⏩ Steer queued for the active turn: …" or "Queued for the next turn…" (`commands.py:290-310`), sent without `messageId` (`server.py:833`).
  - The resumed turn streams under a fresh `messageId` (`events.py:185-236`).
- **Failure scenario:** during a streaming reply the user sends `/steer be brief`. The next bubble reads `⏩ Steer queued for the active turn: be briefOK, keeping it short…`. The status line is not persisted, so a reopen shows the reply cleanly.
- **Suggested fix:** carry `messageId` on `.messageChunk` and finalize the streaming bubble when it changes, or when a chunk arrives with no id.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `agent_message_chunk` text | ACP notif | ACPMessages.swift:419-427; RichChatViewModel.swift:2158,2301 | events.py:220-252; server.py:833,842,972-982 | OK (F4 for messageId) |
| `agent_message_chunk.messageId` | ACP field | not parsed | events.py:231; server.py:974-980 | FINDING-F4 |
| `_meta.hermes.compactionSummary`/`containsCompactionSummary` | ACP meta | ACPMessages.swift:518-528 | server.py:82-97 | OK (replay-only; gate drops; DB classifies) |
| `agent_thought_chunk` | ACP notif | ACPMessages.swift:439-441; RichChatViewModel.swift:2318 | events.py:239-244; server.py:138 | OK |
| `user_message_chunk` | ACP notif | RichChatViewModel.swift:2160-2166 (ignored) | server.py:133,1010 | OK (local echo owns user rows) |
| `tool_call` id/title/kind/status | ACP notif | ACPMessages.swift:443-452; RichChatViewModel.swift:2359 | tools.py:781-815 | OK |
| `tool_call.rawInput` | ACP field | ACPMessages.swift:450 | tools.py:809-811 | FINDING-F2 |
| `tool_call.content` (text/diff), `locations` | ACP field | ACPMessages.swift:530-538 (text only) | tools.py:752-815,850-854 | OK (unused for display; diff ignored → F2 fix could use locations) |
| `tool_call_update` status/rawOutput/content | ACP notif | ACPMessages.swift:454-463; RichChatViewModel.swift:2377-2444,2500-2506 | tools.py:818-835 | OK (skill_manage completion is diff-only → live output blank; minor, self-heals on reopen) |
| `tool_call_update` abandon flush | ACP notif | RichChatViewModel.swift:2399 | events.py:97-116; tools.py:838-847 | OK |
| `tool_call_update` perm-check-N / edit-approval-N | ACP notif | RichChatViewModel.swift:2399-2402 (dropped by openToolCallIds) | permissions.py:113; edit_approval.py:199-207 | OK |
| `plan` | ACP notif | → `.unknown` | events.py:30-52,294 | TRACKED (hermes-v0.21.1 audit B8) |
| `usage_update` {size,used} | ACP notif | → `.unknown` | server.py:362-378 | TRACKED (B8) |
| `session_info_update` title | ACP notif | ACPMessages.swift:469-472; ChatViewModel.swift:2148-2150,2787-2794 | server.py:393-420,797-801 | OK |
| `session_info_update._meta.sessionProvenance` | ACP meta | not parsed | server.py:414-416,954-962; provenance.py | OK for default config (`compression.in_place: true`, config_defaults.py:663); see Not audited |
| `available_commands_update` | ACP notif | ACPMessages.swift:465-467; RichChatViewModel.swift:2184-2220 | commands.py:78-94 | OK |
| `current_mode_update` | ACP notif | → `.unknown` | not emitted | OK (n/a) |
| `session/request_permission` toolCall.title/kind, options | ACP request | ACPMessages.swift:479-499; RichChatViewModel.swift:2173-2179 | permissions.py:30-64; edit_approval.py:199-236 | OK |
| `session/prompt` params: prompt blocks text+image(data,mimeType), messageId | ACP request | ACPClient.swift:571-635 | content.py:229-275; acp schema PromptRequest.messageId | OK |
| `stopReason` end_turn/cancelled/refusal | ACP result | RichChatViewModel.swift:2508-2622; ChatViewModel.swift:1520-1571 | server.py:816,822,837,843,874,999 | OK |
| `usage.inputTokens/outputTokens/thoughtTokens/cachedReadTokens` | ACP result | ACPClient.swift:605-611; RichChatViewModel.swift:2585-2588 | server.py:991-997; turn_finalizer.py:31-33,633 | OK (latent: values are session-cumulative but Scarf `+=` them. Masked because SessionInfoBar.swift:346-353 prefers the DB value, which is non-zero after the first turn) |
| Prompt-image attachment encoding (base64, no `data:` prefix, JPEG/PNG mime) | ACP payload | ChatImageAttachment.swift:16-51 | content.py:229-239 (`initialize` advertises image=True, server.py:538) | OK |
| state.db `sessions` cost columns via `SessionCostDisplay` | SQL (read) | SessionCostDisplay.swift:94-146 | usage_pricing.py:58,632,647,682; hermes_state_usage.py:29-37 | OK |
| state.db messages skeleton/tool hydration/reconcile/poll (`active = 1`) | SQL (read) | RichChatViewModel.swift:2834-3193,3358-3460 | session_persistence.py:212; conversation_compression.py:3688-3720 | OK (queries owned by S04) / FINDING-F1 (echo matching) |
| Echo-vs-persisted user row matching | reconciliation | RichChatViewModel.swift:1993,2873-2876,3012-3036 | server.py:805,824; session_persistence.py:69-119 | FINDING-F1 |
| Replay gate vs autostart `session/load` | lifecycle | ChatViewModel.swift:1160,1194,1211,1240 | server.py:579-589 | FINDING-F3 |
| `ChatViewModel` promptTurns (mid-turn prompt returns first) | lifecycle | ChatViewModel.swift:1495-1585 | server.py:725-745,1001-1011 | OK |

## Not audited / couldn't verify
- **Non-default `compression.in_place: false`**, where the internal Hermes session id rotates. New rows then land under a child session id while Scarf keeps reading the ACP id, and the `sessionProvenance` meta is ignored. Out of scope as unusual config; worth a check if that setting is ever surfaced.
- **Plugin `response_transformed` replies**: Hermes re-sends the full rewritten text under the streamed bubble's `messageId` to replace it (`server.py:972-981`). Because Scarf ignores `messageId`, it would append instead. This needs a transform plugin, so it is not pursued.
- **Handoffs:**
  - The iOS `ChatController` in `Scarf iOS/Chat/ChatView.swift` (S03): check whether its autostart/resume path has the same echo-before-load ordering as F3, and note its `"[image attached]"` echo (F1).
  - S01 owns the `ACPMessages.swift` parser changes F2 and F4 would need.
  - S03: `/queue`-on-idle notes cite `server.py:793-799`. At v2026.9.24 the slash path also drains queued prompts (`server.py:836`), so an idle `/queue` would now run right away. Scarf's fallback (send as a plain prompt) is still correct.
  - S04 owns the `active = 1` history queries.
- No live ACP session was run: read-only audit, and chat cannot be started.
