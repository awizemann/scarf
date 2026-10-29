---
title: Hermes ACP multi-session behaviour by version (one process vs one per chat)
type: note
permalink: scarf/architecture/hermes-acp-multi-session-behaviour-by-version-one-process
created: 2026-10-29
updated: 2026-10-29
---

Researched 2026-10-29 for parallel chats (t-0583409d) against tagged Hermes source. Decides whether several Scarf chats can share one `hermes acp`.

## Observations
- [fact] One ACP connection has always held several sessions (SessionManager dict since 0.6.0); legacy turns run on a ThreadPoolExecutor(max_workers=4) (server.py:46 @ v2026.9.24). A turn waiting on an approval holds a worker (permissions.py:89-98), so a 5th concurrent turn queues silently. Cancel is per session #hermes-acp
- [gotcha] Below 0.18.0, concurrent turns in one process can drop another session onto the auto-approve path (HERMES_INTERACTIVE env swap, GHSA-96vc-wcxf-jjff; server.py:1495-1520 @ v2026.6.19). Below 0.11.0 the approval callback was a module global. Never run concurrent turns in one legacy process below 0.18.0 #security
- [gotcha] 0.18.0–0.21.3 run session/new and session/load on the event loop: loading one chat freezes every other session's stream for seconds (off-loop from 0.21.4, server.py:612-639 @ v2026.9.21) #hermes-acp
- [fact] Gateway-viewer `hermes acp` ships in 0.22.1 and 0.22.3+ (0.22.2 reverted it). There a running turn survives the viewer exiting (session_controls.py:854-869, session_acp_lifecycle.py:16-32 @ v0.22.5), session/cancel only stops turns this viewer submitted (gateway_server.py:414-449), and one event-projection failure fails every session on the viewer (:928-937, :243-267). Re-attaching mid-turn duplicates the partial reply (gateway_reply.py:123-128) #gateway
- [decision] Scarf parallel chats use one `hermes acp` process per live chat on every version (no gate needed); multiplexing on gateway hosts is a possible later memory optimisation. Cost measured at ~110 MB RSS per legacy process (plus its MCP children), ~70 MB per gateway viewer #parallel-chats

## Relations
- relates_to [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]
- relates_to [[Project context-file injection: release-note awareness, not a trust gate (t-42db11e9)]]
