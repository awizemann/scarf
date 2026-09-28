# S02-chat-events — verdict: WORKS-WITH-ISSUES

Scope: how Scarf consumes a Hermes turn (session/update stream, prompt response, state.db reconciliation).
Ground truth: `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (`acp_adapter/`), acp lib schema read from the installed venv
(`acp/helpers.py`, `acp/schema.py`; wire = `by_alias=True, exclude_none=True`, `acp/connection.py:209-210`).

## Hermes emitter inventory (every `session/update` discriminator at the tag)

| sessionUpdate | Emitted by (Hermes @ tag) | Fields on the wire | Scarf handling |
|---|---|---|---|
| `agent_message_chunk` | `events.py:220-252` (stream deltas, `messageId` UUID per reply, closed by `None` sentinel before tools `agent/turn_tool_round.py:150-152`); `server.py:833,842` (slash / absorbed replies, no id); `server.py:971-982` (unstreamed or plugin-rewritten final, id = `current()`/`last()`); history replay `server.py:115-122` (+`_meta.hermes.compactionSummary`/`containsCompactionSummary`) | `content{type:text,text}`, `messageId?`, `_meta?` | parsed `ACPMessages.swift:521-530`; bubble split by id `RichChatViewModel.swift:2628-2635`; rewrite replace `:2656-2672`; replay gated `:2490-2508` — OK |
| `agent_thought_chunk` | `events.py:239-244` (reasoning_callback only; `thinking_callback=None` `server.py:937`), replay `server.py:138` | same as above, shares reply id | `:2521-2523`, `appendThoughtChunk :2691` — OK |
| `user_message_chunk` | replay `server.py:115-122`; queued-prompt drain `server.py:1009-1010` | `content`, `_meta?` | ignored `:2514-2520` — OK (see F3 for the drain side effect) |
| `tool_call` | `events.py:175` via `tools.py:781-815` (`title="<name>: <preview>"`, `kind`, `content?`, `locations[{path,line}]`, `rawInput` only for unknown tools, no `status`) ; replay `server.py:153` | | `ACPMessages.swift:546-557`; `handleToolCallStart :2732-2749` — OK |
| `tool_call_update` | completion `tools.py:818-835` (`status completed/failed`, `content`, `rawOutput` only for non-polished non-JSON); abandoned flush `tools.py:838-847` + `events.py:97-116`; permission/edit-approval closes `permissions.py:113`, `edit_approval.py:203-207` (ids never started) | | `ACPMessages.swift:559-568`; `handleToolCallComplete :2751-2819` (unknown id → `closePermissionHermesSettled :522-539`) — OK except F2 |
| `plan` | `events.py:294-295` (todo results), replay `server.py:165-167` | `entries[]` | → `.unknown`, ignored (todo still renders as a tool card) — OK/degrade-by-design |
| `usage_update` | `server.py:362-378` (size/used only, no `cost`), after load/turn/slash | `size`, `used` | → `.unknown`, ignored; token/cost UI reads state.db — OK |
| `session_info_update` | `server.py:398-418` (title from auto-title `:844-848`; provenance on compression rotation `:952-962`) | `title?`, `updatedAt`, `_meta.hermes.sessionProvenance?` | `ACPMessages.swift:574-582`; `ChatViewModel.swift:2386-2407`, `noteSessionRotation :1694-1697` — OK |
| `available_commands_update` | `commands.py:85-95`, scheduled on new/load/resume/fork `server.py:596` | `availableCommands[{name,description,input{hint}?}]` | `parseACPCommands :2557-2579` — OK (S03 owns the menu) |
| `current_mode_update` | never emitted at the tag (helper exists only in the acp lib) | — | n/a |

Prompt response: `PromptResponse(stop_reason ∈ {end_turn, cancelled, refusal}, usage?)` (`server.py:816,822,837,843,874,999`);
`usage = {inputTokens, outputTokens, totalTokens, thoughtTokens?, cachedReadTokens?}` built from the agent's
**session-cumulative** counters (`server.py:991-997` ← `agent/turn_finalizer.py:633` ← `agent/turn_usage.py:173-180`).

## Journeys

| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Send a text prompt, watch the reply stream (message + thought chunks, per-reply `messageId` bubbles) | WORKS | — |
| 2 | Turn runs tools: start card with live preview, completion status/duration/exit, parallel same-name calls, abandoned-call flush | WORKS (minor) | F2 |
| 3 | Permission / edit-approval request inside a turn, Hermes closes the synthetic id (answered or timed out) | WORKS | — |
| 4 | Turn end: stopReason end_turn/cancelled/refusal, no-output failure bubble, working-state clear, mid-turn `/steer` `/queue` or plain prompt returning early (`othersStillRunning` guard, Mac `ChatViewModel.swift:1743-1757`, iOS `ChatView.swift:2362-2386`) | WORKS (minor) | F3 |
| 5 | Token / cost display after a turn (`refreshSessionFromDB` → `SessionCostDisplay`) | WORKS on default config; DEGRADED after legacy rotation | F4 |
| 6 | Image attachments (`ImageEncoder` → `{type:image,data,mimeType}` → Hermes `content.py:229-239`) and echo reconciliation (`"[screenshot]"` row, `session_persistence.py:108-119`) | WORKS | — |
| 7 | Plugin-rewritten final reply (`transform_llm_output`, same id) | WORKS | — |
| 8 | Compression: rotation provenance followed (`noteSessionRotation`), history replay on load suppressed by the gate | WORKS | — |
| 9 | Reopen / reconnect a chat that has been compacted (reconcile live transcript with state.db rows) | DEGRADED | F1 |
| 10 | Kanban chip on the chat (`hermes kanban list --session <acp id> --json`) | WORKS (LIVE: `--session` in `hermes kanban list --help`; tasks tagged with the ACP id, `server.py:840-842`) | — |

## Findings

### S02-chat-events-F1 · P2 · SOURCE · TRACKED-decision, premise now contradicted (`.memory/decisions/hermes-v0-18-compatibility-decisions.md:18`)
- Claim: Scarf loads chat history from `active = 1` rows only, but Hermes 0.21.5 compacts IN PLACE by default and its own resume display deliberately includes `compacted = 1` rows — so a reopened compacted chat in Scarf shows only the carried-forward tail; every earlier turn looks deleted.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift:1352-1357` (`transcriptVisibleClause` = `active = 1` + hidden filter), used by the skeleton load `:917-922`, `fetchMessages` `:837-842` (reconnect + "Load earlier") and tool results `:1130-1131`; callers `RichChatViewModel.swift:3369` (`loadSessionHistory`), `:3227` (`reconcileWithDB`), `:3693` (`loadEarlier`).
- Hermes @v2026.9.24: `hermes_cli/config_defaults.py:658-663` (`compression.in_place: True`, "Pre-compaction turns are soft-archived under the same id (active=0, compacted=1)"), `agent/agent_init.py:1971`, `agent/conversation_compression.py:3716-3732` (`archive_and_compact`), `hermes_state_messages.py:63` (`UPDATE messages SET active = 0, compacted = 1`), `hermes_state_messages.py:1273-1293` (`get_resume_conversations`: display = `active = 1 OR compacted = 1` over the lineage — "Without them a compacted conversation resumes showing only its summary plus the carried-forward tail — the user's own turns read as deleted", #92080), used by CLI/TUI resume (`hermes_cli/cli_agent_setup_mixin.py:790`, `tui_gateway/server.py:2699`). Standalone handoff summaries are also `display_kind='hidden'` (`agent/session_persistence.py:93-104`), which Scarf filters too, so not even the summary shows.
- Failure scenario: long chat on a default-config host auto-compacts (or the user taps Scarf's own compress gesture → `/compress`). Close and reopen the chat (or switch sessions and back): Scarf shows only the last few exchanges; "Load earlier" cannot reach the archived rows either (same clause). The TUI/CLI resume of the same session shows the whole conversation. Also plausible: after a reconnect mid-session, `reconcileWithDB` keeps the on-screen pre-compaction rows below the window floor AND installs the re-inserted tail copies, duplicating the tail (PLAUSIBLE, not traced end to end).
- Evidence: decision note says "Hermes reloads only the active set — compacted rows ... must not resurface in the chat view"; at the tag that is true only for the MODEL projection (`get_resume_conversations` model_history), not the display projection.
- Suggested fix: for transcript reads use `(active = 1 OR compacted = 1)` + Hermes's generation dedupe (`_dedupe_display_generations`) when `hasCompactedColumn`, mirroring `get_resume_conversations`; re-open the v0.18 decision. (File is HermesDataService — coordinate with the section that owns it.)

### S02-chat-events-F2 · P3 · SOURCE · NEW
- Claim: a live tool card's output is empty when Hermes' completion content is diff-only or absent, because Scarf extracts only `{type:"content"}` text blocks and falls back to `rawOutput`, which Hermes nulls for polished tools.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Models/ACPMessages.swift:648-656` (`extractContentArrayText` reads `item["content"]["text"]` only; `{type:"diff",path,oldText,newText}` is dropped); `RichChatViewModel.swift:2809` (`content: update.rawOutput ?? update.content`); `loadToolResultIfMissing :3626` then treats the empty row as present and never fetches the DB copy.
- Hermes @v2026.9.24: `acp_adapter/tools.py:676-686` (`skill_manage` completion = diff blocks only when a diff exists), `tools.py:825-827` (`web_extract` success → `content=None`), `tools.py:834` (`raw_output=None` for `_POLISHED_TOOLS`, which include both).
- Failure scenario: agent edits a skill (`skill_manage` patch/edit) or extracts a web page; the live tool card/inspector shows an empty result even though the call succeeded. After reopening the chat the DB row shows the real output.
- Suggested fix: render `diff` blocks (path + new text / a unified summary) in `extractContentArrayText`, and fall back to the title for an empty successful completion.

### S02-chat-events-F3 · P3 · SOURCE · NEW
- Claim: the `/queue` chip drains only ONE entry per turn end, but Hermes runs ALL queued prompts inside the same `session/prompt` call before it answers, so with two or more queued prompts the chip keeps showing stale entries.
- Scarf: `RichChatViewModel.swift:2982-2984` (`popQueuedPrompt()` once per `promptComplete`); mirror filled at `scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:1644-1649`; model `Packages/ScarfCore/Sources/ScarfCore/Models/HermesQueuedPrompt.swift`.
- Hermes @v2026.9.24: `acp_adapter/server.py:985-989` (`_finish_turn` drains in its `finally` before returning) and `:1001-1011` (`while True` loop runs every queued prompt via `await self.prompt(...)`); the `/queue` requests themselves return `end_turn` immediately and are skipped by `othersStillRunning`.
- Failure scenario: during a running turn the user types `/queue A` and `/queue B`. Hermes runs A and B, then answers the original prompt once; Scarf pops one entry, so the header shows "1 queued" (B) although nothing is pending, until the next turn end.
- Suggested fix: clear the whole mirror on the owning turn's `promptComplete` (Hermes has drained everything by then).

### S02-chat-events-F4 · P3 · SOURCE · NEW
- Claim: after a legacy (rotating) compression, the chat header's tokens/cost freeze, because Scarf refreshes only the row of the ACP session id while Hermes writes the new usage onto the continuation row.
- Scarf: `RichChatViewModel.swift:2092-2101` (`refreshSessionFromDB` → `fetchSession(id: sessionId)`, a single row, `HermesDataService.swift:1778-1786`), called after each turn `ChatViewModel.swift:1760`; displayed by `SessionInfoBar.swift:358-365` + `SessionCostDisplay`.
- Hermes @v2026.9.24: `agent/conversation_compression.py:1692` (`agent.session_id = child_session_id` on rotation), `agent/turn_usage.py:249-256` (per-call token/cost deltas go to `agent.session_id`), provenance announced `server.py:952-962` (Scarf already records it in `lineageSessionIds`).
- Failure scenario: host with `compression.in_place: false` (non-default; default is in-place, so the common setup is unaffected); a long chat rotates mid-session; every later turn's tokens and cost land on the new row and the header keeps showing the pre-rotation totals.
- Suggested fix: after a rotation, fetch the lineage tip (or sum the lineage rows) for the header.

## Touchpoint inventory

| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `session/update` `agent_message_chunk` (+`messageId`, `_meta.hermes.*Summary`) | ACP notification | ACPMessages.swift:521-530; RichChatViewModel.swift:2510-2513,2628-2689 | events.py:185-252; server.py:82-122,833,842,971-982 | OK |
| `agent_thought_chunk` | ACP notification | ACPMessages.swift:542-544; RichChatViewModel.swift:2521-2523,2691-2700 | events.py:239-244; server.py:136-138,937 | OK |
| `user_message_chunk` | ACP notification | ACPMessages.swift:532-540; RichChatViewModel.swift:2514-2520 | server.py:115-122,1009-1010 | OK |
| `tool_call` (title/kind/locations/rawInput) | ACP notification | ACPMessages.swift:546-557,285-353; RichChatViewModel.swift:2732-2749 | tools.py:193-198,781-815,850-854 | OK |
| `tool_call_update` (status/content/rawOutput) | ACP notification | ACPMessages.swift:559-568,648-656; RichChatViewModel.swift:2751-2881 | tools.py:676-695,818-847; events.py:78-116 | FINDING-F2 |
| permission/edit-approval `tool_call_update` close (`perm-check-N`, `edit-approval-N`) | ACP notification | RichChatViewModel.swift:522-539,2773-2777 | permissions.py:54-64,94-113; edit_approval.py:199-207 | OK |
| `session/request_permission` (toolCall.toolCallId/title/kind, options) + response | ACP request | ACPMessages.swift:589-610; ChatViewModel.swift:2883-2892; ACPClient.swift:797-825 | permissions.py:33-64 | OK |
| `plan` | ACP notification | ACPMessages.swift:584-585 (`.unknown`) | events.py:30-52,294-295 | OK (ignored by design) |
| `usage_update` | ACP notification | ACPMessages.swift:584-585 (`.unknown`) | server.py:362-378 | OK (ignored) |
| `session_info_update` title + `_meta.hermes.sessionProvenance` | ACP notification | ACPMessages.swift:462-506,574-582; ChatViewModel.swift:2386-2407,3112-3123; RichChatViewModel.swift:2542-2551,1694-1712 | server.py:398-418,844-848,952-962; provenance.py:32-86 | OK |
| `available_commands_update` | ACP notification | ACPMessages.swift:570-572; RichChatViewModel.swift:2557-2579 | commands.py:79-95; server.py:596 | OK (S03) |
| `current_mode_update` | ACP notification | not parsed | not emitted | OK |
| `session/prompt` result `stopReason` | ACP response | ACPClient.swift:629-630; RichChatViewModel.swift:2883-2997,1816-1821,2382-2398 | server.py:816,822,837,843,874,999 | OK |
| `session/prompt` result `usage` (session-cumulative) | ACP response | ACPClient.swift:612-636; RichChatViewModel.swift:2960-2970 | server.py:991-997; turn_finalizer.py:633 | OK (fallback-only, see notes) |
| `session/prompt` image block `{type:image,data,mimeType}` + text block | ACP request | ACPClient.swift:643-660; ChatImageAttachment.swift; ImageEncoder.swift | content.py:229-275; server.py:807-811 (`PromptCapabilities(image=True)` :527) | OK |
| state.db `sessions` row (tokens, cost, cost_status) | SQL read | RichChatViewModel.swift:2092-2101; SessionCostDisplay.swift:94-131 | hermes_state_usage.py:23-40,275-304; usage_pricing.py:58,632,647 | OK / FINDING-F4 (rotation) |
| state.db `messages` transcript read (active filter, lineage) | SQL read | RichChatViewModel.swift:3213-3319,3328-3506,3673-3718; HermesDataService.swift:837-842,917-922,1352-1357 | hermes_state_messages.py:47,63,1273-1293 | FINDING-F1 |
| state.db user-row shape for echo matching (`[screenshot]`, steer/interrupt wrappers) | SQL read semantics | RichChatViewModel.swift:2175-2256 | agent/session_persistence.py:69-119; server.py:193-202,805 | OK |
| state.db polling fingerprint / merge (terminal mode) | SQL read | RichChatViewModel.swift:3767-3886 | — | OK |
| `hermes kanban list --session <id> --json` | CLI argv | KanbanChatBadgeViewModel.swift:79-91 (via KanbanService) | `hermes kanban list --help` (LIVE); server.py:840-842 (HERMES_SESSION_ID = ACP id) | OK |
| `/queue` mirror drain | ACP behaviour | RichChatViewModel.swift:1128-1160,2982-2984; HermesQueuedPrompt.swift | server.py:985-1011 | FINDING-F3 |
| ImageHostConsentStore | none (dashboard image consent, UserDefaults) | ImageHostConsentStore.swift | — | OK (no Hermes touchpoint) |
| MarkdownContentView | none (pure renderer) | MarkdownContentView.swift | — | OK (no Hermes touchpoint) |

## Not audited / couldn't verify / notes
- acp lib source was read from `~/.hermes/hermes-agent/venv` (the only installed copy); the tag pins `agent-client-protocol==0.9.0` per Scarf's own citations — schema fields used (aliases, `messageId`, `Usage`, `UsageUpdate`) assumed identical to that pin.
- Hygiene, not a finding: `acpInputTokens += response.inputTokens` (`RichChatViewModel.swift:2960-2963`) sums Hermes's SESSION-CUMULATIVE counters (`turn_usage.py:173-180`), so the fallback would over-count from turn 2. It only displays when the state.db row reads 0 (`SessionInfoBar.swift:358-365`), which on 0.21.5 is written per API call (`turn_usage.py:249-256`), so no user-visible effect found. Fix = assign instead of add.
- Stale comment (S03 handoff): `RichChatViewModel.swift:832-840,2036-2051` say Hermes does not re-emit `available_commands_update` after `session/load`; at the tag it does (`server.py:596` for load/resume). Behaviour unaffected.
- Transport ordering (S01 handoff): `promptComplete` is synthesized from the RPC return without waiting for the event loop to drain (`ChatViewModel.swift:1747-1758`); on the wire Hermes sends all chunks before the response and the usual trailing event is the harmless `usage_update`, so no reachable bug was traced.
- Did not run a live turn; all verdicts are source traces. iOS shares `RichChatViewModel`; iOS send path (`Scarf iOS/Chat/ChatView.swift:2311-2450`) checked for the early-return guard only.
