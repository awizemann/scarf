---
title: Chat turn duration pill is turn-scoped and history-derived (#148)
type: note
permalink: scarf/architecture/chat-turn-duration-pill-is-turn-scoped-and-history-derived
tags: [chat, turn-duration]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift]
source_paths_inferred: false
source_sha: 81d1d901c47ee48398443c99b9f457d69ebaa49a
created: 2026-09-29
updated: 2026-09-29
reviewed: 2026-10-05
reviewed_by: audit:claude-code (background)
---

## Observations
- [invariant] RichChatViewModel's currentTurnStart is closed only by closeTurnStopwatch on turn end (promptComplete incl. cancel/error, connection lost, finalizeOnDisconnect), never by per-segment finalizeStreamingMessage, which runs once per tool call #chat
- [decision] One duration per turn, keyed by the turn's LAST finalized assistant message id (turnLastAssistantId); a turn with no assistant output records nothing #chat
- [decision] Loaded-history durations are derived from the already-fetched state.db rows' timestamps (user row -> last assistant row before the next user row) in refreshTurnDurations inside buildMessageGroups; no extra query, no store; gaps missing, negative or over 6h are hidden #chat
- [gotcha] Public turnDurations = derived history merged with liveTurnDurations (live wins); only DB rows (id > 0) get derived values and a local pending user echo still closes the previous turn #chat

## Relations
- relates_to [[Chat transcript ActivityBubble segmentation]]
