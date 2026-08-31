---
title: Streaming chat UI upserts are throttled to 50ms — ACP chunk rate must never drive observable mutations
type: note
permalink: scarf/architecture/streaming-chat-ui-upserts-are-throttled-to-50ms-acp-chunk
tags: [performance, chat, streaming, gh-140]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift]
source_paths_inferred: false
source_sha: 4debe39330edf72842312458a1840afd72b944e6
created: 2026-08-31
updated: 2026-08-31
---

## Observations
- [gotcha] ACP message chunks can arrive ~30µs apart (tens of thousands/sec in bursts) — gh#140 perf log; per-chunk upsert of observable messages/messageGroups pegged one core and starved rendering to 2-3 chars/sec #performance #chat
- [decision] RichChatViewModel buffers streaming text per-chunk but throttles upsertStreamingMessage() to a 50ms leading+trailing flush (scheduleStreamingUpsert / flushStreamingUpsertNow / cancelStreamingFlush) #performance
- [constraint] Structural events (tool call start/complete, finalize, promptComplete) bypass the throttle and mutate immediately; finalize reads the raw buffers so no text is lost #chat
- [gotcha] A stale trailing flush after finalize/reset would resurrect an empty id=0 bubble — flushStreamingUpsertNow guards on non-empty streaming buffers and teardown paths call cancelStreamingFlush() #chat
- [fact] Prior layers of the same fight: Equatable MessageGroupView short-circuit (gh#46), streaming markdown parse skip (RichMessageBubble id==0), renderWindow=30 trailing cap #performance


## Phase 2 — incremental streaming markdown (gh#140)

Throttling bounded the flush RATE; phase 2 bounds the cost PER flush. The streaming bubble previously re-parsed and re-laid-out the whole accumulated reply each flush (O(reply length), quadratic per turn — a multi-page reply pegged the core even at 20 flushes/sec). `StreamingMarkdownText` (scarf/scarf/Core/Utilities/MarkdownContentView.swift) keeps a settled prefix — everything up to the last completed `\n\n` paragraph boundary, parsed once into one AttributedString whose `Text` input never changes between flushes so SwiftUI skips its diff/layout — and re-parses only the small live tail. Reset detector: `content.hasPrefix(settledSource)` memcmp; a mismatch rebuilds from scratch. On finalize the bubble id flips off 0 and the full block pipeline takes over, so the incremental view only needs to match the old streaming rendering. Commits 1b6baa5 (phase 1) + 6f3bd68 (phase 2).
