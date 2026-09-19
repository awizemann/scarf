---
id: t-97cf2ed9
title: Fix F5: iOS SSH output splits UTF-8 at packet boundaries (old)
status: done
added: 2026-09-18
priority: high
---

## Description

OLD bug, found in the final audit (t-f8c66377). `ScarfIOS/CitadelServerTransport.swift:449,457`: `buf.readString(length:)` decodes each SSH data packet separately, so a multi-byte character split across two packets becomes two U+FFFD characters, and invalid bytes are silently replaced. This hits EVERY iOS exec/streamScript, e.g. RemoteSQLiteBackend chat JSON over about 32 KB with CJK text or emoji: the message shows "��". Fix: accumulate raw bytes (Data) per stream and decode once at the end. For line streaming, decode on complete lines. Also:
- Fix the stale "does not support stdin yet" error (:205-208).
- Fix the stale base64 comment in RemoteSQLiteBackend.swift:80.
- Fix the misplaced PermissionWrapper doc comment in `Scarf iOS/Chat/ChatView.swift` (~2993).
- Document the edge case where the host's login rc files read stdin (now that the script arrives on stdin).
Standards: a test that feeds a split multi-byte sequence across chunks and fails on the old code; the iOS build; a fresh-eyes check.

## Plan



## Artifacts

Orchestrator: merged into feat/voice (a353c378). The UTF-8 fix, its tests, and the RemoteSQLiteBackend / PermissionWrapper comment fixes are done. Two small leftovers moved to task t-3ba95f7e's neighbourhood as notes: (1) CitadelServerTransport.swift ~205-208 still throws "does not support stdin yet" though runExec now supports stdin; (2) the rc-file-reads-stdin edge case isn't documented. Both are folded into the whole-surface follow-up list.

