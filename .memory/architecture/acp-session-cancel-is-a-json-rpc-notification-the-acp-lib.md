---
title: ACP session/cancel is a JSON-RPC notification; the acp lib routes by id-key presence
type: note
permalink: scarf/architecture/acp-session-cancel-is-a-json-rpc-notification-the-acp-lib
tags: [acp, hermes, cancel]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ACPMessages.swift]
source_paths_inferred: false
source_sha: 495b264ffc4c8c44da89a3f8129a6c16ce0392a7
created: 2026-09-26
updated: 2026-09-26
---

Wire contract of the acp Python lib Hermes pins (agent-client-protocol ==0.9.0 at v2026.9.14/v2026.9.24; >=0.8.1,<0.9 at the v0.6.0 floor v2026.3.30; both verified identical). Found in P7a (t-67f960a6) after Scarf's cancel had been request-shaped, and therefore inert, since it was written. Probe script: import acp.agent.router.build_agent_router + acp.connection.Connection over an in-memory StreamReader with a stub agent.

## Observations
- [invariant] session/cancel is registered only via route_notification (acp/agent/router.py:112 in 0.9.0, :53 in 0.8.1); no supported Hermes ever accepted it as a request #acp #cancel
- [gotcha] The acp Connection classifies frames by `"id" in message` (connection.py:166), so `"id": null` is still a request; a request-shaped cancel draws -32601 Method not found and Agent.cancel never runs #acp
- [fact] Scarf's ACPClient.cancel sends an ACPNotification (no id key) and returns once written; the turn end arrives as the session/prompt response with stopReason cancelled (acp_adapter/server.py:999 @ v2026.9.24) #acp #cancel
- [gotcha] On stdin EOF the acp Connection.close cancels in-flight handler tasks, so a cancel written immediately before client.stop() may not finish; wait (bounded) for the prompt response before stopping if the turn must finalize #acp #s4
- [convention] ACPClient fails fast (processTerminated) for any request or notification once the transport hit EOF; a failed initialize closes the channel so start() can retry cleanly #acp

## Relations
- relates_to [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]
- relates_to [[ACP turn completion is sendPrompt's return, not a stream .promptComplete event]]
