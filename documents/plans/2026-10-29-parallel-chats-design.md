# Parallel chats — design plan (2026-10-29)

Task: t-0583409d. Trigger: a Reddit user, used to Hermes Desktop, found that chats "stop working when you click into a different chat".

## 1. What happens today

- A Mac server window runs one chat. Opening another chat, from the chat list or from any handoff, goes through `startACPSession`, whose first line is `stopACP()` (ChatViewModel.swift:2338, :3048-3127). That sends `session/cancel` for the running turn, kills `hermes acp`, and shows "Turn cancelled — switched sessions." This was a deliberate fix (S4, t-5451bd1b), not a regression.
- iOS does the same, without the cancel (`stop()` at the top of every start path, ChatView.swift:3168/3188/3395), and drops the connection whenever the app goes to the background (:2915-2942).
- File ▸ New Window (⌘N) can already open a second window on the same server. Each window has its own ChatViewModel and process, so two chats can run side by side today, just in two windows.

## 2. Hermes facts that decide the design (tagged source; memory: architecture/hermes-acp-multi-session-behaviour-by-version-one-process)

| Hermes | Several chats in one `hermes acp` |
|---|---|
| < 0.11.0 | Unsafe: approvals can go to the wrong session |
| < 0.18.0 | Unsafe: one chat can switch another onto auto-approve (GHSA-96vc-wcxf-jjff) |
| < 0.19.1 | Project context (AGENTS.md) comes from the process cwd, so one process = one project |
| 0.18.0–0.21.3 | Loading one chat freezes every other chat's stream for seconds |
| legacy, any version | 4 worker threads; a turn waiting on an approval holds one; a 5th turn waits silently |
| 0.22.1, 0.22.3+ (gateway) | Works, but one projection error fails every chat on the viewer, and cancel only reaches turns that viewer started |

## 3. Decision: each live chat owns its own connection

Introduce **`ChatSession`**: everything per-chat that ChatViewModel holds today, plus the `hermes acp` connection it runs on. ChatViewModel becomes the window's list of live chats, plus a pointer to the one on screen.

Why this is the simplest correct design:
- It behaves the same on every Hermes version from 0.6, so there is no capability gate and no version split.
- Every hardened piece is already scoped to one client and moves over intact: the start watchdog, the reconnect ladder, the bounded cancel, held sends, the stall check, and the per-project process cwd and environment hint.
- It avoids the work multiplexing needs on Scarf's side: an event demultiplexer, per-session stall/stderr/drain counters, and the last-writer-wins `currentSessionId` / `lastSessionState` in ACPClient.
- Multiplexing on gateway hosts stays open as a later memory optimisation, hidden behind ChatSession.

Rejected: **"Open in new window" as the answer.** `openWindow(value: serverID)` focuses the existing window rather than making a new one, so it needs its own window identity anyway. It also duplicates the whole app UI per chat and does nothing for approvals or notifications from a chat you can't see.

## 4. Resource limits (from review: the riskiest part)

- **Remote hosts share one SSH master connection per host** (ControlMaster `%C`, SSHTransport.swift:210-224, :778-801). Each live chat holds one channel on it, next to log tails and short query bursts. OpenSSH allows 10 channels per connection by default. Past that, ssh silently opens a new, fully authenticated connection, which brings back the gh#138 side effects (browser tabs, hardware-key touches). The ACP spawn also skips `SSHConnectionGate.admit`.
  - **Per-server live-chat budget, app-wide (across windows):** remote 4, local 8, counting every chat that holds a process. When the budget is full, release the least recently used idle chat; if every chat is working, ask the user to wait or stop one.
  - **One master recovery per host.** Today each failing chat runs `recoverRemoteTransportAfterFailure` → `-O exit` (ChatViewModel.swift:1626, 2715, 2910; SSHTransport.swift:174-195), which would kill every other chat on the host. Make it a single shared operation per host; chats wait for it, then reconnect staggered.
- **Idle chats.** A background chat that finishes keeps its process (so coming back to reply is instant) until the budget needs the slot (least recently used first). A released chat keeps its transcript in memory. When you focus it again, it re-attaches through the full `startACPSession` path, not the weaker autostart path (which skips the model preset and project chip, :1539-1553). It then reloads its transcript from the database.
- **What a release loses on legacy Hermes:** the approval mode picked in the chat (held in memory only; server.py:1057-1069). ChatSession remembers it and re-sends `session/set_mode` after load. The model picked mid-chat and `/queue` survive (session.py:343-360, server.py:988-1015).

## 5. What moves where

**ChatSession (per chat; mostly moved, not rewritten):** RichChatViewModel; ACPClient, event loop, health monitor, reconnect ladder; prompt turns, in-flight turn, busy origins; held sends; start pipeline (generation counter, watchdog, preflight args); its own environment-hint slot (fixes the shared-slot race, ProjectEnvironmentHint.swift:135); project path, name, branch; model preset; approval mode; pending title; resume fallback; status; error banner; inspector focus; composer draft; voice turn bookkeeping; stop, cancel, permission answers.

**ChatViewModel (per window):** session list and previews; config diagnostics; display mode and terminal; the live chat registry and the focused chat; coordinator handoffs; delete/rename lookups; the Live Voice controller (bound to one chat); window teardown. It keeps forwarding properties to the focused chat, so views and tests keep compiling.

**Bots** keep using a ChatViewModel as a one-chat controller: no registry, same routers and seams.

**Client factory:** the factory must receive the chat's own hint slot. Its signature changes, which touches 51 test assignments and BotConversationViewModel.swift:191-195. Do this in P0.

## 6. Behaviour

- Clicking a live chat **focuses** it. Focusing is a new, light path: no respawn, no SSH gate reset, no "resume" analytics event. It still ends Live Voice and terminal voice, as switching does today.
- Opening another chat while the current one is replying leaves it running in the background.
- Chat list rows show each live chat's state: replying, needs your answer, finished (unread), error, idle. Today only the displayed chat can show "replying".
- **Background approvals and questions** queue in that chat (verified: they pass the replay gate, RichChatViewModel.swift:2966-2968). The row shows a badge, a notification fires, and the sheet opens when you focus the chat. Hermes still denies an approval that times out.
- **Notifications.** Today there is one, "reply finished". It is suppressed whenever Scarf is the active app (ChatNotificationService.swift:46), has no click routing, and there is no notification delegate. Add a delegate (`willPresent` for background chats, `didReceive` routing by server and session id to the right window and chat), plus a "needs your answer" notification. Clicking focuses the chat. Answering an approval from the notification itself is a separate feature.
- Stop, `/queue`, `/steer`, `/undo`, `/retry`, model and approval-mode changes act on the chat they were typed in.
- Drafts are kept per chat.
- Handoffs (project New Chat, Project Sessions rows, New Project, Upgrade Project) focus the chat if it's live, otherwise open it. They never replace another chat. Dashboard "New Session" starts a new chat.
- Deleting or renaming a chat from anywhere applies to the matching live chat. Deleting a replying chat stops it first.
- Closing the window or quitting with chats still replying asks first: "N chats are still replying." Then each gets a bounded cancel.
- `stopACP()` is split into "stop this chat" and "stop all chats in this window". Callers are reviewed one by one.
- Diagnostics banners that wait for "no process" (ChatView.swift:254-339) wait for "no live chats".

## 7. Phases (each: plan, build, real tests, fresh-eyes audit, commit)

- **P0: extract ChatSession, no behaviour change.** ChatViewModel owns exactly one ChatSession for its whole life and reuses one RichChatViewModel via `reset()`, as today. Change the factory signature and split `stopACP`. All suites pass; only the factory assignments change mechanically.
- **P1: parallel chats, released as one unit.**
  - The live registry and focus path.
  - Background chats kept running.
  - The per-server budget, with least-recently-used release.
  - Single-flight SSH master recovery.
  - Re-attach through the full start path.
  - Remembered approval mode.
  - List-row state and per-chat drafts.
  - Delete/rename fan-out and window-close teardown.
  - Background approvals, the notification delegate and the new notifications.
  - Rewriting the tests that assert "Turn cancelled — switched sessions." (ChatViewModelStartLifecycleTests.swift:469, :528) and SessionDeletedSignalTests.
- **P2: remaining edges.**
  - Handoffs become focus-or-open.
  - Voice binding.
  - The close/quit confirm.
  - Banner gating.
  - Analytics (a "parallel chats" event).
  - Gateway stop/restart recovery across N chats.
- **P3: live UI tests in the scarf-ui VM, on Hermes v0.22.5 and v0.21.5.**
  - Two chats replying at once, switching between them.
  - An approval in a background chat.
  - Deleting a background chat.
  - Closing the window while chats run.
  - A remote host at the budget.
- **iOS interim (small, any time):** confirm before switching away from a chat that is still replying.

P1 must not ship without its approval and notification work. Otherwise a background approval sits unseen until Hermes denies it.

## 8. Not in v1

- **iOS parallel chats.** These are foreground-only on iOS. They need a background and push design tied to gh#151.
- **Sharing one process across chats on gateway hosts.**
- **Moving ChatSession into ScarfCore to share with iOS.** The iOS ChatController is a separate copy; merging them is its own project.
- **The same chat live in two windows (⌘N).** Possible today. Later, focus the other window instead.

## 9. Decisions needed from Alan

1. The budget: 4 live chats per remote server and 8 per local one?
2. Should a finished background chat keep its process until the budget needs it (instant return), or release it straight away (less memory)?
3. A confirm on window close or quit while chats are replying?
4. iOS: leave it for later, and add the interim confirm now?
