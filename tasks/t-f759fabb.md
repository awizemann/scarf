---
id: t-f759fabb
title: Parallel chats P1: live registry, background chats, budget, approvals and notifications
status: doing
added: 2026-10-29
---

## Description

Parent t-0583409d; design §4, §6, §7. Ships as one unit: focus path, keep working chats live, per-server app-wide budget with LRU release, single-flight SSH master recovery per host, re-attach via full startACPSession, remembered approval mode (legacy), list-row state, per-chat drafts, delete/rename fan-out, window teardown, background approvals, UNUserNotificationCenter delegate + routing, rewrite switch-cancel tests.

## Plan



## Artifacts

["commit 34d572ef (step 1)", "commit 52a3552e (step 2)", "commit 47efbd13 (step 3)", "commit 01db68bc (prompt-order race fix)", "VM UI gate PASS: v0.22.5 Full+Live, v2026.9.24 Full+Live", "Pending: host Mac full unit suite x2 + mutation check of heldSendsReachHermesInSendOrder (screen was locked)"]

