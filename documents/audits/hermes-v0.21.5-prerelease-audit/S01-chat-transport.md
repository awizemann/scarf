# S01-chat-transport — verdict: WORKS

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Spawn + `initialize` (Mac local `hermes [-p x] acp`, Mac SSH `ssh -T host bash -lc …`, iOS Citadel exec with PATH/HERMES_HOME/-p default prefix) | WORKS | — |
| 2 | `session/new` with cwd + empty mcpServers; mode/model state read from response | WORKS | — |
| 3 | `session/load` + in-request history replay; `{}`/null result treated as not-restorable | WORKS | — |
| 4 | `session/prompt` with text / image / embedded-resource blocks; stopReason + usage decode | WORKS | — |
| 5 | Stop = `session/cancel` notification (no id), ordered behind prompt write | WORKS | — |
| 6 | Process death / EOF / broken pipe → pending requests fail with exit code + stderr tail; stall policy on iOS | WORKS | — |
| 7 | `session/set_mode` (default/accept_edits/dont_ask), `session/set_model` (`provider:model`) incl. -32602/-32603 errors surfaced via data.details | WORKS | — |
| 8 | `session/request_permission` → `{outcome:{outcome:"selected",optionId}}` / cancelled | WORKS | — |
| 9 | Profile pinning local (`-p <bot>` / `-p default`) and remote (HERMES_HOME= + `-p default` for root) | WORKS | — |

## Findings
None. (Considered and dropped: `$/ping` keepalive is an unknown notification — acp router raises method_not_found for it, but notifications get no reply, so harmless (`acp/router.py:165-182`). Hermes-initiated request ids start at 0 and share the Int namespace with Scarf's ids, but requests are distinguished by `method`, so no collision. iOS silently drops a non-UTF-8 stdout line whereas Mac fails the stream — Hermes routes all logging to stderr (`acp_adapter/entry.py:66-69`), so not reachable in normal use.)

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| ScarfCore/ACP/ACPChannel.swift | no (protocol) | NO-TOUCHPOINT |
| ScarfCore/ACP/ACPClient.swift | yes | OK |
| ScarfCore/ACP/ACPContextNote.swift | yes (resource block) | OK |
| ScarfCore/ACP/ACPStallPolicy.swift | yes (timing assumptions) | OK |
| ScarfCore/ACP/ProcessACPChannel.swift | yes (process lifecycle) | OK |
| ScarfCore/Models/ACPMessages.swift | yes (wire shapes) | OK |
| ScarfCore/Transport/PipeReader.swift | no (framing) | NO-TOUCHPOINT |
| ScarfProjectsMCPKit/JSONRPC.swift | no (Scarf's own MCP server framing) | NO-TOUCHPOINT |
| ScarfIOS/ACPClient+iOS.swift | yes (remote argv) | OK |
| ScarfIOS/SSHExecACPChannel.swift | yes (exec transport) | OK |
| scarf/Core/Services/ACPClient+Mac.swift | yes (argv/env/profile) | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes @v2026.9.24 | Status |
|---|---|---|---|---|
| `hermes [-p name] acp` | argv | ACPClient+Mac.swift:65-69,88-92 | hermes_cli/main.py:598-622 (profile override); `hermes acp --help` LIVE | OK |
| `PATH=… [HERMES_HOME=…] exec hermes [-p default] acp` | remote argv | ACPClient+iOS.swift:118-141 | hermes_cli/profiles.py:2345-2369 | OK |
| `ssh -T host bash -lc <cmd>` | remote argv | SSHTransport.swift:758-777 | — | OK |
| `initialize` (protocolVersion 1) | ACP req | ACPClient.swift:331-340 | acp_adapter/server.py:523-544 | OK |
| `session/new` {cwd, mcpServers:[]} | ACP req | ACPClient.swift:453-472 | server.py:609-614 | OK |
| `session/load` {cwd, sessionId, mcpServers}; `{}` on failure | ACP req | ACPClient.swift:487-539 | server.py:616-624, 563-602 (replay before response; no sessionId in response → Scarf falls back to requested id) | OK |
| `modes.currentModeId` / `models.currentModelId` | response fields | ACPMessages.swift:526-535 | server.py:597-602 | OK |
| `session/prompt` blocks text/image/resource; `stopReason`, `usage.inputTokens…` | ACP req | ACPClient.swift:605-669 | server.py:811-876, 941-999; content.py | OK |
| `session/cancel` notification | ACP notif | ACPClient.swift:692-698, ACPMessages.swift:43-60 | server.py:636-657; acp/agent/router.py:112 | OK |
| `session/set_mode` modeId | ACP req | ACPClient.swift:713-722 | server.py:238-252, 1053-1065 | OK |
| `session/set_model` modelId `provider:model` | ACP req | ACPClient.swift:750-783 | server.py:1015-1051 | OK |
| `session/request_permission` in / outcome out | ACP req (server→client) | ACPClient.swift:807-835,1066-1072; ACPMessages.swift:637-658 | acp_adapter/permissions.py:40-110 | OK |
| `session/update` kinds (agent/user/thought chunk, tool_call(+update), available_commands_update, session_info_update, `_meta.hermes.*`, messageId) | ACP notif | ACPMessages.swift:559-635 | events.py:185-250; server.py:52-170, 393-420; tools.py | OK |
| JSON-RPC error `data.details` | error decode | ACPMessages.swift:87-127 | acp/connection.py (wrapped internal errors) | OK |
| `$/ping` keepalive | ACP notif | ACPClient.swift:440-449 | acp/router.py:165-182 (ignored) | OK |
| stderr tail / exit code diagnostics | stderr | ACPClient.swift:130-168,1083-1121 | entry.py:66-69 (logs→stderr) | OK |
| 60 s control-request watchdog; prompt unbounded | timeout | ACPClient.swift:863-871 | — | OK |

## Not audited / couldn't verify
- No live ACP session was run (read-only brief); behaviour traced from source only.
- Consumers of these events (ChatViewModel / RichChatViewModel / ScarfGo ChatController reconnect ladder) belong to other chat sections.
