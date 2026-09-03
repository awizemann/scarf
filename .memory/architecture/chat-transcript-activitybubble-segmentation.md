---
title: Chat transcript ActivityBubble segmentation
type: note
permalink: scarf/architecture/chat-transcript-activitybubble-segmentation
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift, scarf/scarf/Features/Chat/Views/ActivityBubble.swift, scarf/scarf/Features/Chat/Views/RichChatMessageList.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ACPMessages.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesMessage.swift]
source_paths_inferred: false
source_sha: f1952fb7c66a4b7afd2576098f7fe9f98643b52e
created: 2026-09-02
updated: 2026-09-03
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

## Observations
- [architecture] MessageGroup.transcriptItems(coalesceText:) partitions assistant messages into text bubbles and ChatActivitySegment runs; presentation-only, storage untouched #chat-transcript
- [architecture] RichChatViewModel.liveActivityStatus drives the in-turn spinner text; setter is equality-guarded so chunk-rate events never invalidate the transcript #perf
- [decision] tool_call_update rawInput backfills "{}" placeholder arguments in handleToolCallComplete; argumentsSummary never renders the raw "{}" token #acp
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
