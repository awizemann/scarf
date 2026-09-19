---
title: iOS session resume must fall back to newSession for non-ACP-persisted sessions
type: note
permalink: scarf/architecture/ios-session-resume-must-fall-back-to-newsession-for-non-acp
source_paths: [scarf/Scarf iOS/Chat/ChatView.swift, scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-08-19
updated: 2026-08-19
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [gotcha] Cron- and CLI-created Hermes sessions are NOT ACP-persisted, so ACP `session/load` returns null/empty by design (Hermes `load_session`→None→`{}` on the wire); ACPClient.loadSession throws `invalidResponse(... not restorable)` (ACPClient.swift:458). Resuming one must NOT surface that raw error. #acp #chat
- [convention] The full resume fallback pattern: on loadSession failure, open a fresh ACP session (`client.newSession(cwd:)`) and replay the transcript from state.db via `loadSessionHistory(sessionId: <original>, acpSessionId: <new>)`. iOS `_startResumingImpl` (ChatView.swift:2399-2523) implements this completely. Mac has the fallback in TWO resume entry points: `startACPSession` (ChatViewModel.swift:1671-1848, full pattern with fallback + replay) and `autoStartACPAndSend` (ChatViewModel.swift:1064-1191, fallback only—no transcript replay). iOS mirrors the `startACPSession` pattern (not `autoStartACPAndSend`). #parity
- [fact] The iOS reconnect ladder (`attemptReconnect`, ChatView.swift:2115) is deliberately NOT given the new-session fallback — it retries the SAME active session; adding a fallback there would mask transient failures. Only the Dashboard→tap RESUME path gets the fallback. #reconnect

## Relations
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]
