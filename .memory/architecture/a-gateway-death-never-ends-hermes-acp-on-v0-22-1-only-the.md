---
title: A gateway death never ends hermes acp on v0.22.1+; only the next request reveals it
type: note
permalink: scarf/architecture/a-gateway-death-never-ends-hermes-acp-on-v0-22-1-only-the
created: 2026-10-30
updated: 2026-10-30
---

Read from tagged Hermes source on 2026-10-30, not run live. Citations use tag v0.22.5 unless noted. v2026.9.24 (Hermes 0.21.5) has no gateway_server.py and is always standalone, so none of this applies there.

## Observations
- [fact] From v0.22.1 `hermes acp` is always a gateway viewer, decided by version alone: acp_adapter/entry.py:201-202, acp_adapter/server.py:244-248 #hermes #acp
- [fact] When the gateway dies the viewer stays alive and stdout stays open, so process-exit and stdio-close triggers do not fire: hermes_cli/gateway_client.py:194-206, acp_adapter/gateway_server.py:930-936 #hermes #reconnect
- [fact] An in-flight prompt gets JSON-RPC -32603 "Internal error" with the real text in `error.data.details`, saying the outcome is unknown and not to resend (hermes_cli/gateway_client.py:197-198). An idle viewer is told nothing #hermes #acp
- [fact] The next request reconnects by itself and can restart a gateway the user stopped: acp_adapter/gateway_server.py:153-175, hermes_cli/gateway_client.py:264,288 #hermes #gateway
- [gotcha] A turn lost in a restart makes later prompts fail with details starting `unknown_execution:` until `/discard <id>` is sent: acp_adapter/gateway_server.py:625-633,847-850 #hermes #acp
- [gotcha] The -32603 mapping comes from the installed agent-client-protocol 0.9.0 (acp/connection.py), not tagged Hermes source; a hung socket that never closes and the timing during a graceful stop were not traced #hermes

## Relations
- relates_to [[Hermes ACP multi-session behaviour by version (one process vs one per chat)]]
- relates_to [[Hermes gateway multiplex-by-default and parked profiles (v0.21.4 / v0.21.5)]]
