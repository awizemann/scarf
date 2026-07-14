---
id: t-01bd55ec
title: Chat — deleteSession on an active mid-turn session never stops the client
status: done
added: 2026-07-13
---

## Description

Fix-3 audit report-only finding (pre-existing): deleting the currently-active session while a turn is in flight resets the transcript but never stops the ACP client/process — the orphaned turn keeps running server-side and the process leaks until app quit. Route deleteSession-of-active-session through the same stopACP + bounded session/cancel teardown Fix 3 built (ChatViewModel.swift). Also from the same audit, minor design notes recorded in memory: stale preflight-sheet confirm supersedes a newer healthy start (last-action-wins, sheet not dismissed on new click); termination handler drains stdout only (stderr source stays armed if a grandchild holds the write end — cheap but asymmetric).

## Plan



## Artifacts

Commit 59485c1 on feat/local-models — `fix(chat): deleteSession of active session routes through teardown (t-01bd55ec)`.

- ChatViewModel.deleteSession: when the deleted session is the attached one, bump start generation → richChatViewModel.reset() → stopACP() (bounded 2s session/cancel iff inFlightPromptSessionId marks a mid-flight turn, then client.stop(), watchdog disarm, reconnect cancel) → acpStatus idle → delete-specific "Turn cancelled — session deleted." toast. Non-active delete returns before teardown. Server-side `hermes sessions delete --yes` semantics unchanged, now behind an injectable `sessionDeleteRunner` seam.
- 3 new tests in ChatViewModelStartLifecycleTests (delete-active-mid-turn / delete-active-idle / delete-inactive); mid-turn + idle tests verified failing on pre-fix body (5 + 3 issues), inactive passes pre-fix. Mac scarfTests 242/242, ScarfCore 901/901, app Debug build clean.
- Sidebar confirm dialog (ChatSessionListPane:109-114) is the only ChatViewModel.deleteSession caller. SessionsViewModel.confirmDelete is an independent delete surface that never touches the chat client (noted for potential follow-up if the Sessions pane can delete the chat-active session).

