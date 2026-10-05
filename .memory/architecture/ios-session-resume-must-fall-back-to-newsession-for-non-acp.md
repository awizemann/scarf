---
title: iOS session resume must fall back to newSession for non-ACP-persisted sessions
type: note
permalink: scarf/architecture/ios-session-resume-must-fall-back-to-newsession-for-non-acp
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/SessionResume.swift, scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift, scarf/Scarf iOS/Chat/ChatView.swift]
source_paths_inferred: false
source_sha: b97c2ea41ac22e1a530ce324d87d59b5546d5605
created: 2026-08-19
updated: 2026-09-29
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---
Scope note (2026-09-29, gh#146): despite the title, this now covers Mac AND ScarfGo. The shared logic lives in `scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/SessionResume.swift`; the notice names the raw `sessions.source` value (e.g. "cli", "telegram").


Updated 2026-09-29 for #146 (t-96585713): the fallback is now shared, source-gated, typed, and announced. Mac and ScarfGo both go through ScarfCore `SessionResume` — do not re-grow per-platform catch-alls.

## Observations
- [invariant] Hermes ACP restores ONLY rows with `sessions.source == "acp"` (`_restore`, acp_adapter/session.py:428 @ v0.21.5; `load_session` returns None → `{}` on the wire, server.py:616-624). webui/CLI/gateway/cron sessions can never be `session/load`ed. `SessionResume.resolve` reads the source first (sidebar row on Mac, else `SessionResume.fetchSource` read-only) and skips the load for a known non-acp source; unknown/empty source still attempts the load. #acp #chat #146
- [convention] Fall back to `session/new` ONLY on `ACPClientError.sessionNotRestorable` (thrown for a null/`{}` load result). Every other load error (JSON-RPC error, timeout, dead process) is rethrown: Mac start paths land in their failure catch (acpStatus failed + banner); ScarfGo shows the failed overlay whose Retry reopens the SAME session (`failedResumeSessionID` / `retryAfterFailure`), never a blank `start()`. #resume #t-238d2ab3
- [convention] A fallback raises `RichChatViewModel.resumeContinuityNotice` — a persistent, non-dismissible transcript row anchored after the last state.db row (positive id) of the replayed history; cleared only by `reset()`, never by `setSessionId`. Logging and `session_resume_fallback {kind: non_acp_source | new_session_fallback}` live in `SessionResume` so Mac/iOS stay in parity. #parity
- [gotcha] A Mac start that fails after arming its event loop must disarm it (`stopWatchingFailedStart`) before `client.stop()`, or the EOF reads as a dropped connection and `handleConnectionDied` paints a reconnect ladder over the failure, re-sending the failing load — EXCEPT on `processTerminated`, where the EOF is a real drop and the ladder must run (it carries held sends; ChatReconnectHoldR17Tests) — the Mac autostart catch hands off explicitly (`handOffDeadStartToReconnect`) because the ladder vs `dropHeldSends` race is timing-dependent. On iOS, `stop()` resets state to `.idle`, so set `.failed` AFTER stopping or the overlay/Retry vanishes; and re-assert `vm.setSessionId(resolvedID)` after `loadSessionHistory` (it leaves the VM on the origin id when state.db is unreadable). #reconnect #ios
- [fact] Reconnect ladders (Mac + iOS `attemptReconnect`) stay load-only with NO fallback — they retry the same session; after a fallback that session is the new ACP-born id, which reloads fine. `hermes kanban list --session` takes ONE id (kanban_parser.py:239 @ v0.21.5), so old-id tasks drop off the chat badge after a fallback; the Mac notice says so when `hasKanbanSessionFilter`. #kanban #t-e875803c

## Relations
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]



## Retry/Reconnect after a later failure in a fallback chat (2026-09-29)
After a fallback the chat's `sessionId` is the continuation (S2), not the session the user opened. Retry (ScarfGo `ChatController.retryAfterFailure`) and the Mac error banner's Reconnect (`ChatViewModel.reconnectSessionId`) reopen the ORIGIN session, so the fallback repeats with the original transcript + notice. Reopening S2 instead loaded only S2's history, or (no turn yet → not restorable) fell back again over a blank chat. iOS keeps `resumeFallbackOriginID` (cleared by every start path); Mac uses `lastResumeFallback` (origin, continuation), valid only while the chat is on that continuation, chained across repeated auto-start fallbacks, then `originSessionId`. Trade-off: turns typed into S2 stay in state.db under S2 (own list row) but aren't replayed on Retry. Tests: ChatControllerResume146Tests.retryAfterAFallbackReopensTheOriginSession, ChatResumeFallback146Tests.reconnectAfterAFallbackReopensTheOriginSession / autoStartFallbackIsWhatReconnectReopens.
