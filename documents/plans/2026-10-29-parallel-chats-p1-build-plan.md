# Parallel chats P1 — build plan (2026-10-29)

Parent task t-0583409d, P1 task t-f759fabb. Design: documents/plans/2026-10-29-parallel-chats-design.md. Grounded against HEAD 1f7b0f23. Paths relative to `scarf/`; CS = ChatSession.swift, CVM = ChatViewModel.swift.

## Corrections to the design found in the code
1. Citations moved in P0: master recovery callers CS:945, :1959, :2154 plus the wake sweep scarfApp.swift:959/:974; ServerRegistry.swift:236 also runs `-O exit` on server removal. Start teardown is CS:1580. "Switched sessions" tests: ChatViewModelStartLifecycleTests.swift:476/:520.
2. The registry cannot be keyed by session id (nil until ready CS:1843, #146 fallback CS:1803, compression rotation CS:1985). Use ordered `[ChatSession]` with a `ChatSession.id: UUID`; look up by `covers(sessionId)` (transcript lineage or `targetSessionId`).
3. Budget key is the SSH ControlMaster (`.local` or user@host:port, `%C` at SSHTransport.swift:213), not ServerID. Budget must be injectable (tests share ServerContext.local.id).
4. Re-attach must close the replay gate and hold sends during reload, or the session/load replay paints as new content and sends race the load.
5. A per-chat RichChatViewModel loses `acpCommands` (kept across reset because Hermes doesn't re-emit on load, RichChatViewModel.swift:2343-2358) — seed new chats from the window's last known set.
6. Drafts are view @State today (RichChatInputBar.swift:49/:58), rebuilt per session id (ChatTranscriptPane.swift:144); move into ChatSession.
7. A chat that is only starting with nothing typed is still superseded (no process leak from browsing).
8. Notification delegate installed in ScarfApp.init; route via a window directory + captured openWindow; pending route if no window.
9. Bot chats get no notification route.
10. Permission sheet id must include the chat id (JSON-RPC ids restart per process).
11. Hermes's own unread dot exists (ChatSessionListPane.swift:525); Scarf's finished-unread must not draw a second one.
12. Handoffs mostly inherit focus-or-open from resumeSession.

## Steps (each compiles and is green; P1 ships whole)
1. **Registry and focus core.** `chats`, `focusedChat` var, `Mode { window, single }` (Bots = single), `makeChat()` with fan-outs (host, fileService, capabilities, scoped commands, seeded acpCommands), focus vs open, leave rules (working/pending/held → keep; starting & empty → supersede; idle live → keep; blank/error → drop), `targetSessionId`/`covers`, continue-last re-route, preflight targets the chat that bailed, terminal flag split from hasActiveProcess, voice teardown only for the focused chat, `stop(reason:)`, delete/rename fan-out, stop-all teardown. Rewrite the two lifecycle tests; registry tests. No process limit yet.
2. **Budget, release/re-attach, approval mode, SSH single-flight.** `LiveChatBudget` (4 remote / 8 local per ControlMaster, LRU idle release, all-working dialog with Stop/Wait), `releaseProcess`/`reattach` (closed gate, held sends), `userPickedApprovalMode` re-sent after load and after reconnect, `SSHMasterRecovery` (single-flight + ~5 s cooldown + staggered followers), wake sweep routed through it.
3. **Row state, drafts, background approvals, notifications.** `rowState` (needsAnswer > error > replying > finishedUnread > idle), row UI, composer state in ChatSession, composite permission-sheet id, UNUserNotificationCenter delegate (willPresent, didReceive routing), needs-answer notification (cleared on resolve), window directory, app-init hookup.

Each step: build → serial scarfTests → fresh-eyes audit → commit on feat/parallel-chats. VM UI gate after step 3.
