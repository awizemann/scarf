---
title: iOS session resume must fall back to newSession for non-ACP-persisted sessions
type: note
permalink: scarf/architecture/ios-session-resume-must-fall-back-to-newsession-for-non-acp
source_paths: [scarf/Scarf iOS/Chat/ChatView.swift, scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift]
source_paths_inferred: false
source_sha: cc42250a7195da79d17ebe0e2d8351d5ea93c384
created: 2026-08-19
updated: 2026-08-19
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

## Observations
- [gotcha] Cron- and CLI-created Hermes sessions are NOT ACP-persisted, so ACP `session/load` returns null/empty by design (Hermes `load_session`→None→`{}` on the wire); ACPClient.loadSession throws `invalidResponse(... not restorable)` (ACPClient.swift:340). Resuming one must NOT surface that raw error. #acp #chat
- [convention] Both resume paths must fall back the same way: on loadSession failure, open a fresh ACP session (`client.newSession(cwd:)`) and replay the transcript from state.db via `loadSessionHistory(sessionId: <original>, acpSessionId: <new>)`. Mac did this (ChatViewModel.swift:1559); iOS `_startResumingImpl` (ChatView.swift ~2447) was missing it and dead-ended on cron sessions — fixed 2026-08-19 (commit a75be27). #parity
- [fact] The iOS reconnect ladder (`attemptReconnect`, ChatView.swift:2122) is deliberately NOT given the new-session fallback — it retries the SAME active session; adding a fallback there would mask transient failures. Only the Dashboard→tap RESUME path gets the fallback. #reconnect

## Relations
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]
