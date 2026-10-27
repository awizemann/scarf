---
id: t-b2ba0fa8
title: Pass /retry and /undo through on gateway-backed ACP
status: done
added: 2026-10-26
priority: high
---

## Description

On Hermes v0.22.1 and v0.22.3+ (hasGatewayBackedACP), the gateway ACP advertises and serves title/undo/retry/usage/status (acp_adapter/gateway_session_meta.py:26-41 and gateway_commands.py:1-10 @ v0.22.5; /undo and /retry are the gateway 'rewind' mutation). Scarf 3.7.0 still intercepts /retry and /undo on every version (RichChatViewModel.cliOnlySlashNames, ~line 1448) and says "Hermes doesn't offer it to apps", which is wrong on those hosts. Fix: gate the interception on !hasGatewayBackedACP and send them to Hermes. Then the transcript has to follow a rewind: the removed turns must leave the chat view (check how RichChatViewModel reloads from state.db). Keep pre-0.22.3 hosts byte-identical (C1). Then post the held gh#147 reply (Alan approved posting retest replies on 2026-10-26).

## Plan



## Artifacts



