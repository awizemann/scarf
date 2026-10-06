---
title: Chat transcript ActivityBubble segmentation
type: note
permalink: scarf/architecture/chat-transcript-activitybubble-segmentation
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift, scarf/scarf/Features/Chat/Views/ActivityBubble.swift, scarf/scarf/Features/Chat/Views/RichChatMessageList.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ACPMessages.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesMessage.swift]
source_paths_inferred: false
source_sha: 3b042718fac93b0021f7dccf7f75ed4530b394ef
created: 2026-09-02
updated: 2026-09-27
reviewed: 2026-10-06
reviewed_by: audit:claude-code (background)
---

## Observations
- [architecture] MessageGroup.transcriptItems(coalesceText:) partitions assistant messages into text bubbles and ChatActivitySegment runs; presentation-only, storage untouched #chat-transcript
- [architecture] RichChatViewModel.liveActivityStatus drives the in-turn spinner text; setter is equality-guarded so chunk-rate events never invalidate the transcript #perf
- [fact] Hermes sends `rawInput` ONLY for unknown/plugin tools and never on `tool_call_update` (acp_adapter/tools.py:797-835 @ v2026.9.24; built-ins have had raw_input=None since at least v2026.7.7.2). A live built-in call is stored with arguments "{}"; its label is `HermesToolCall.livePreview` (non-Codable) = first `locations[].path`, else the title preview (`build_tool_title` "<name>: <preview>"). `argumentsSummary` falls back to it; DB-hydrated calls carry real arguments and livePreview nil. The update-side rawInput backfill in handleToolCallComplete stays but no tag feeds it (R09 / S02-F2) #acp
- [decision] ActivityBubble "×N" collapse key = functionName + arguments + livePreview — without livePreview, reads of a.swift/b.swift/c.swift (all "{}") collapsed into one card (R09 / S02-F2) #chat-transcript
- [fact] Streamed replies are segmented by Hermes `messageId` (agent_message_chunk / agent_thought_chunk, shared allocator, events.py:185-236 @ v2026.9.24): RichChatViewModel.startNewReplyIfIdChanged finalizes the streaming bubble when a chunk's id differs from `streamingReplyId`. Slash/absorbed status replies ("⏩ Steer queued…", "Queued for the next turn…") carry NO id, so they become their own bubble. Normal tool rounds are unaffected (the tool completion already finalized); hosts without ids compare nil==nil (C1). Plugin `response_transformed` resends (the whole rewritten text as one chunk under `message_ids.last()`, server.py:971-981) REPLACE since R16b when recognisable: the id belongs to a reply finalized this turn (`finalizedReplyMessageIds`), or the chunk restates the whole still-streaming reply (≥ 24 chars). A rewrite of an open reply that doesn't restate it still appends until reload #acp
- [convention] any new input to MessageGroupView's rendering must be added to its Equatable == or settled groups short-circuit past the change #perf

## Relations
- builds_on [[scarf/architecture/streaming-chat-ui-upserts-are-throttled-to-50ms-acp-chunk]]
- relates_to [[scarf/architecture/chat-session-layer-mechanism-map-and-2026-07-13-diagnosis]]

- [fact] Hermes persists the literal string "(empty)" as assistant content when the model returns an empty response; Scarf detects it render-side (HermesMessage.isEmptyResponseSentinel, exact match) and renders a muted "Empty response from the model" row inside activity segments — stored data never mutated #hermes
- [decision] buildGroups (extracted static RichChatViewModel.buildGroups(from:)) only starts a new user-less group at a VISIBLE-TEXT assistant; activity-only rows (tools/thoughts/blank/"(empty)") accumulate so DB-loaded tool loops aggregate into one ActivityBubble with cross-row xN collapse #chat-transcript

- [gotcha] Models emit whitespace-only chunks (bare "\n") between tool calls; HermesMessage.hasVisibleText and hasVisibleReasoning require a non-whitespace character, otherwise the streaming id-0 row painted a transient empty bubble pill / empty REASONING disclosure mid-turn #streaming
- [fact] ActivityBubble settled state: when a segment is not live and no live status, header shows a muted checkmark + turn duration looked up via ChatActivitySegment.messageIds against the existing turnDurations dict (stopwatch lands on the turn's first finalized message) #chat-transcript

- [decision] "Load earlier" pages render in recall mode (Alan 2026-09-03): prompts + visible-text replies + ONE muted EarlierActivityMarker per turn ("N tools · M reasoning — not loaded"); boundary tracked by RichChatViewModel.earlierHistoryCutoffId (ids > 0 and < cutoff), the session-open window keeps full ActivityBubble rendering #chat-transcript
- [gotcha] Tool-card status must derive from ToolCallRunState.state(hasResult:exitCode:isSettled:) — historical tool results are usually NOT loaded (loadHistoricalToolResults defaults false), so result==nil must never render a spinner on a settled turn #chat-transcript
- [fact] loadEarlier loops up to maxEarlierPageFetches pages until pageHasRenderableContent (user/visible-text/tools/reasoning/"(empty)") or table exhaustion — a junk page can never strand the spinner or produce a no-op click #paging


- [gotcha] Hermes >= v0.21.4 (v2026.9.21) sends a bare tool_call_update with NO prior tool_call start to close the synthetic tool call inside session/request_permission (ids perm-check-N / edit-approval-N, acp_adapter/permissions.py:113). RichChatViewModel.handleToolCallComplete only honours updates for ids in openToolCallIds (inserted at start, removed on first update) — never key this on streamingToolCalls, which every finalize empties while parallel calls are still open. Ungated: <= v0.21.3 every update had a start. R18b (t-486aed3f): the dropped close is not ignored for the permission queue — `PendingPermission.toolCallId` keeps the request's id and `closePermissionHermesSettled` pops a request STILL queued when its close arrives (Hermes timed out and denied; Scarf pops answered requests before sending the reply, Mac and iOS), with a transientHint when status != completed. User answers go through `resolvePermission(requestId:answeredWith:)`, which remembers allow/deny per toolCallId, so a `failed` close for an ALLOW (the answer reached Hermes after it had stopped waiting) also raises a hint. Only reached for ids with no start, so a real tool completion never pops a request #acp
- [fact] RichChatViewModel.workingSince (set/cleared by isAgentWorking's didSet) is the whole-turn clock for the "Working · 0:12" indicator (#145); currentTurnStart is NOT — every per-tool finalize clears it. The 1 Hz tick lives in WorkingElapsedIndicator's own TimelineView (Mac) / AgentThinkingRow (iOS) so the transcript never re-renders on the clock #perf
