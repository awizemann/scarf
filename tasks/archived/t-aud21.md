---
id: t-aud21
title: **[followup/t-aud01]** Lazy-load `reasoning_content` (v0.11 rich chain-of-thought) on REASONING disclosure open. `fetchReasoningContent(for:)` exists but has zero callers; the bulk fetch excludes reasoning_content (perf, issue #74) so it's never shown on ANY historical load. Wire a per-message lazy fetch from `RichMessageBubble` (macOS) + `Scarf iOS/Chat/ChatView.swift:2464`. Gotchas to resolve: (1) `RichMessageBubble` `==` short-circuit (issue #46) doesn't compare reasoning for settled bubbles, so a spliced result won't redraw — use a view-local `@State` cache instead; (2) need a cheap "reasoning_content available" probe so the disclosure shows even when content isn't loaded; (3) confirm whether v0.11 models populate `reasoning` too or only `reasoning_content`.
status: todo
added: 2026-06-13, source: t-aud01
---

## Description



## Plan



## Artifacts



