# S02-chat-events — verdict: WORKS

No source-proven defect on a primary path. Every `session/update` Hermes 0.21.5 emits is either handled correctly or deliberately ignored without harm. Streaming assembly by `messageId`, tool start/complete pairing, turn-end/stop reasons, usage accounting, and state.db reconciliation (including compaction lineage and Load earlier) all line up with the tagged adapter.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Send a prompt and watch the streamed reply (agent_message_chunk / agent_thought_chunk, messageId grouping, 50 ms throttled upsert, finalize) | WORKS | — |
| 2 | Tool calls during a turn (tool_call → tool_call_update, parallel calls, perm-check/edit-approval closes, turn-end flush, rawOutput vs content fallback) | WORKS | — |
| 3 | Turn end (PromptResponse stopReason end_turn/cancelled/refusal, usage accumulation, error banner, Stop button → session/cancel → "You stopped this turn") | WORKS | — |
| 4 | Mid-turn sends (/steer, /queue, plain prompt queued by Hermes; id-less status line split from the resumed reply; queue chip cleared on completion) | WORKS | — |
| 5 | Resume a session (session/load replay suppressed by gate; history from state.db skeleton + background tool hydration; lineage for rotated chains; pending-echo reinjection) | WORKS | — |
| 6 | Load earlier (render-window extend, then DB paging with `before:` cursor across lineage; recall-mode cutoff) | WORKS | — |
| 7 | Reconnect after crash (finalizeOnDisconnect, session/load-only ladder, reconcileWithDB, held sends drained after replay) | WORKS | — |
| 8 | Session metadata (session_info_update title → sidebar; provenance rotation → lineage extension; available_commands_update → slash menu) | WORKS | — |
| 9 | Cost / token display (SessionCostDisplay from actual/estimated/cost_status; refreshSessionFromDB after each turn incl. continuation rows) | WORKS | — |
| 10 | Image attachments (ImageEncoder JPEG downsample → ChatImageAttachment → ImageContentBlock) | WORKS | — |

## Findings
None.

Checked and dropped (disproved or out of scope):
- **Hermes does not re-advertise commands after `session/load`.** A Scarf comment says so (`RichChatViewModel.swift:840-847`, `:2093-2108`). It is stale: `_session_response_fields` schedules `available_commands_update` for load too (`acp_adapter/server.py:596`). No user impact — the event is always processed (ungated) and the static fallback dedupes by name. Comment-only.
- **`plan` and `usage_update` are dropped.** Both are emitted (`acp_adapter/events.py:52`; `server.py:374`, `:997`) and parse to `.unknown` (`ACPMessages.swift:629`), so they are ignored harmlessly. This is a missing feature (a todo panel, a live context-window meter), not a defect.
- **Load earlier can leave part of a page behind the render window.** `loadEarlier` prepends groups without bumping `renderWindow` (`RichChatViewModel.swift:3814-3816` vs `:371-374`). When the total passes 30 groups, the oldest just-fetched groups stay hidden until the next click, which reveals them with no I/O (`ChatTranscriptPane.swift:95-100`). Nothing is lost and the button stays honest. Cosmetic, below P3.
- **`fetchToolResultsInRange` can take a negative `minId` from a pending local echo.** `RichChatViewModel.swift:3631`. This only happens with the opt-in "load tool results" setting while an echo is pending, so it is a rare edge case and out of scope.

## File coverage (mandatory — one row per manifest line, none skipped)
| File | Hermes touchpoints? (yes/no) | Status |
|------|------------------------------|--------|
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ChatImageAttachment.swift | yes (ACP ImageContentBlock shape: mimeType + bare base64) | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesQueuedPrompt.swift | no (local mirror of /queue) | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/SessionCostDisplay.swift | yes (sessions.actual_cost_usd / estimated_cost_usd / cost_status semantics) | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ImageEncoder.swift | no (local downsample/encode) | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ImageHostConsentStore.swift | no (UserDefaults + Keychain-signed grants) | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift | yes (all session/update kinds, PromptResponse, permission closes, state.db history/reconcile/paging, slash roster) | OK |
| scarf/scarf/Core/Utilities/MarkdownContentView.swift | no (renderer) | NO-TOUCHPOINT |
| scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift | yes (ACP lifecycle: session/new, session/load, session/prompt, session/cancel, permission responses; event loop; `hermes sessions delete/rename` seams; config reads) | OK |
| scarf/scarf/Features/Chat/ViewModels/KanbanChatBadgeViewModel.swift | yes (`hermes kanban list --session <id>` via KanbanService) | OK |
| scarf/scarf/Features/Chat/Views/ActivityBubble.swift | indirect (renders Hermes "(empty)" sentinel, tool kinds) | OK |
| scarf/scarf/Features/Chat/Views/ChatTranscriptPane.swift | indirect (Load earlier wiring) | OK |
| scarf/scarf/Features/Chat/Views/RichChatMessageList.swift | no (layout) | NO-TOUCHPOINT |
| scarf/scarf/Features/Chat/Views/RichMessageBubble.swift | no (renders HermesMessage fields) | NO-TOUCHPOINT |

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| agent_message_chunk (+messageId, rewrite under last id) | ACP notification | RichChatViewModel.swift:2585-2588, 2703-2747 | acp_adapter/events.py:185-252; server.py:971-981 | OK |
| agent_thought_chunk (shared id allocator) | ACP notification | RichChatViewModel.swift:2596-2598, 2766-2775 | events.py:238-244 | OK |
| user_message_chunk (replay / queued-prompt drain) | ACP notification | RichChatViewModel.swift:2589-2595 | server.py:118-120, 1010 | OK (ignored by design; the local echo already shows the prompt) |
| tool_call start (rawInput, title/livePreview) | ACP notification | RichChatViewModel.swift:2807-2824 | events.py:135-160 | OK |
| tool_call_update (completed/failed, rawOutput None for structured/polished → content text) | ACP notification | RichChatViewModel.swift:2826-2894 | tools.py:818-848; events.py:95-114 | OK |
| perm-check-N / edit-approval-N close without a start | ACP notification | RichChatViewModel.swift:524-547, 2848-2852 | permissions.py:54-64,113; edit_approval.py:199-207 | OK |
| session/request_permission queue + cancel on turn end | ACP request | RichChatViewModel.swift:461-583; ChatViewModel.swift:3053-3063 | permissions.py:33-113 | OK |
| available_commands_update | ACP notification | RichChatViewModel.swift:2615-2616, 2632-2654 | commands.py:79-94; server.py:596 | OK |
| session_info_update (title, _meta provenance) | ACP notification | RichChatViewModel.swift:2617-2626; ChatViewModel.swift:2555-2575, 3296-3307 | server.py:396-420, 952-960 | OK |
| plan / usage_update | ACP notification | ACPMessages.swift:629 (→ .unknown), RichChatViewModel.swift:2627 | events.py:52; server.py:374,997 | OK (ignored; feature gap only) |
| session/prompt PromptResponse stopReason + usage | ACP response | ChatViewModel.swift:1809-1865; RichChatViewModel.swift:2958-3080; ACPClient.swift:623-645 | server.py:816-843, 991-999 | OK |
| session/cancel (Stop) | ACP notification | ChatViewModel.swift:4010-4024, 2916-2945 | server.py:636-657, 999 | OK |
| session/load replay suppression + drain before send | ACP | RichChatViewModel.swift:2558-2583; ChatViewModel.swift:1405-1533, 2598-2607 | server.py:572-601 | OK |
| session/load failure → `{}` → new-session fallback | ACP | ChatViewModel.swift:2341-2357 (ACPClient.swift:487+) | server.py:616-624 | OK |
| messages skeleton / tool_calls hydrate / tool results / paging `before:` | state.db SELECT (via HermesDataService) | RichChatViewModel.swift:3422-3696, 3772-3817 | hermes_state_messages.py:866-878,1273-1293 | OK (SQL owned by data-service section) |
| reconcile after reconnect (compaction generation key) | state.db SELECT | RichChatViewModel.swift:3298-3413, 4124-4143 | hermes_state_messages.py:866-878 | OK |
| sessions cost columns (actual/estimated/cost_status) | state.db column semantics | SessionCostDisplay.swift:106-140; RichChatViewModel.swift:2149-2170 | agent/usage_pricing.py:58,632,647; hermes_state_usage.py:29,37 | OK |
| "(empty)" assistant sentinel | state.db content | HermesMessage.swift:90-92; ActivityBubble.swift:197 | agent/turn_finalizer.py:382 | OK |
| ImageContentBlock (image/jpeg, bare base64) | ACP prompt content | ChatImageAttachment.swift; ImageEncoder.swift:64-83 | acp_adapter/content.py:12-19,57-68 | OK |
| `hermes kanban list --session <id> --json` | argv | KanbanChatBadgeViewModel.swift:51; KanbanFilters.swift:66 | `hermes kanban list --help` (LIVE: --session exists) | OK |
| `hermes sessions delete/rename` seams | argv | ChatViewModel.swift:653-664 | (owned by Sessions section) | OK |
| config.yaml reads (approvals.mode, voice.*, model.*) | config | ChatViewModel.swift:730-779 | (owned by config/model sections) | OK |

## Not audited / couldn't verify
- ACPClient wire-level parsing (`ACPMessages.swift` / `ACPClient.swift`) was read only where it feeds this section's handlers. Full ownership sits with the ACP transport section.
- The HermesDataService SQL behind skeleton, hydration, paging and reconcile fetches (`transcriptVisibleClause`, lineage queries) belongs to the data-service section. Only the call contracts were checked here.
- iOS counterparts: the manifest lists none. The shared RichChatViewModel is covered above.
- There is no live ACP session probe; the only allowed probe was `--help`. All ACP claims are SOURCE-confidence against v2026.9.24.
