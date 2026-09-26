---
title: iOS session resume must fall back to newSession for non-ACP-persisted sessions
type: note
permalink: scarf/architecture/ios-session-resume-must-fall-back-to-newsession-for-non-acp
source_paths: [scarf/Scarf iOS/Chat/ChatView.swift, scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-08-19
updated: 2026-08-19
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

## Observations
- [gotcha] Cron- and CLI-created Hermes sessions are NOT ACP-persisted, so ACP `session/load` returns null/empty by design (Hermes `load_session`→None→`{}` on the wire); ACPClient.loadSession throws `invalidResponse(... not restorable)` (ACPClient.swift line 496). Resuming one must NOT surface that raw error. #acp #chat
- [convention] The full resume fallback pattern: on loadSession failure, open a fresh ACP session (`client.newSession(cwd:)`) and replay the transcript from state.db via `loadSessionHistory(sessionId: <original>, acpSessionId: <new>)`. iOS `_startResumingImpl` (ChatView.swift:3075+) implements this completely. Mac has the fallback in TWO resume entry points: `startACPSession` (ChatViewModel.swift:1807+, full pattern with fallback + replay) and `autoStartACPAndSend` (ChatViewModel.swift:1153+, fallback only—no transcript replay). iOS mirrors the `startACPSession` pattern (not `autoStartACPAndSend`). #parity
- [fact] The iOS reconnect ladder (`attemptReconnect`, ChatView.swift:2768+) is deliberately NOT given the new-session fallback — it retries the SAME active session; adding a fallback there would mask transient failures. Only the Dashboard→tap RESUME path gets the fallback. #reconnect

## Relations
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]
