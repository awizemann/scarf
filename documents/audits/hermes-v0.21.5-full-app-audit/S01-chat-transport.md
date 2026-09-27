# S01-chat-transport — verdict: WORKS-WITH-ISSUES

The core ACP transport is sound against Hermes 0.21.5 (v2026.9.24). This covers spawn, initialize, session/new, session/load, prompt, cancel, set_mode, set_model, the permission round trip, keepalive, EOF/stderr diagnostics and reconnect. Every JSON-RPC shape Scarf sends or parses matches the tagged adapter and the pinned `agent-client-protocol==0.9.0` lib. I found two real defects, and both are at the edges of the transport. The first is a profile-pinning gap on the ACP argv for the *default* bot. The second is the iOS stall detector, which kills a healthy turn during long silent waits.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Mac local: spawn `hermes acp`, `initialize` (protocolVersion 1, empty clientCapabilities, clientInfo) | WORKS | — |
| 2 | Mac remote: `ssh -T host bash -lc '… hermes acp'` + initialize | WORKS | — |
| 3 | iOS: Citadel exec `cd …; PATH=… HERMES_HOME=… exec hermes acp` + initialize | WORKS | — |
| 4 | `session/new` with cwd + `mcpServers: []` | WORKS | — |
| 5 | `session/load` of an existing session (Hermes replays history before responding); fallback to new on `{}` | WORKS | — |
| 6 | `session/prompt` with text + image blocks (+ usage decode) | WORKS | — |
| 7 | `session/cancel` mid-turn (notification) → `stopReason:"cancelled"` | WORKS | — |
| 8 | Process death / EOF / SSH drop → fail pending, reconnect via load-only ladder | WORKS (Mac) / DEGRADED (iOS) | F2 |
| 9 | `session/set_mode`, `session/set_model` (provider:model encoding) | WORKS | — |
| 10 | `session/request_permission` round trip (selected / cancelled) | WORKS (iOS degraded by F2 on slow answers) | F2 |
| 11 | stderr capture, 60 s control watchdog, `$/ping` keepalive | WORKS | — |
| 12 | Profile selection: `-p <name>` (Mac), `HERMES_HOME=` (Mac SSH + iOS) | DEGRADED | F1 |

## Findings

### S01-chat-transport-F1 · P2 · SOURCE · NEW
- **Claim:** `ACPClient.acpArguments(profile:)` drops the `-p` flag for the `default` profile. A Bot Mode chat with the *default* bot therefore runs `hermes acp` under the host's sticky `active_profile`, while Scarf reads and writes the root home.
- **Scarf:** `scarf/scarf/Core/Services/ACPClient+Mac.swift:56-62`. `HermesProfileScope.normalize("default")` returns nil, so the argv is `["acp"]`. The doc comment claims "`-p default` is a no-op Hermes special-cases anyway". The caller is `scarf/scarf/Features/Bots/ViewModels/BotConversationViewModel.swift:151-167`: `context.pinnedToProfile(profileName)` re-points the file layer at the root home (`ServerContext.swift:257-265`, see `pinnedToProfile`), but the ACP process is not pinned. Remote has the same gap: `SSHTransport.composedRemoteCommand` emits no `HERMES_HOME=` for a root home (`HermesProfileScope.swift:161-164`).
- **Hermes @v2026.9.24:** `hermes_cli/main.py:613-622`: with no `-p` and no profile-shaped `HERMES_HOME`, `_apply_profile_override` reads `<root>/active_profile` and re-homes the process to that profile. `hermes_cli/profiles.py:2366-2369`: `-p default` resolves explicitly to the root, so it is not a no-op when `active_profile` is set.
- **Failure scenario:** The user ran `hermes profile use work`, so `~/.hermes/active_profile` is `work`. They open the default bot's conversation in Bots. Scarf shows the root `state.db` transcript. The spawned agent runs as `work`, with `work`'s SOUL, config, memory and model, and it persists the turn into `profiles/work/state.db`. Replies come from the wrong identity and never land in the transcript Scarf is showing.
- **Evidence:** `BotAgentConfigService.swift:50-57` already documents this hazard and deliberately passes `-p default` on every CLI invocation ("without it, step 2 of the override follows the host's sticky `~/.hermes/active_profile` … the default bot … would write into `work`'s `config.yaml`"). Memory `decisions/decision-scarfgo-profile-switching-via-per-connection.md` also records "`-p default` defeats a non-default host active_profile for the default case". Only the ACP argv builder disagrees. `hermes --help` lists `hermes -p <profile> <cmd>` (LIVE).
- **Suggested fix:** When a profile was explicitly requested (the bot path), emit `["-p", name ?? "default", "acp"]`. Keep `["acp"]` only for `profile == nil` (a normal chat that should follow `active_profile`), and fix the doc comment.

### S01-chat-transport-F2 · P2 · SOURCE (permission wait) / PLAUSIBLE (long silent tool) · NEW
- **Claim:** The iOS health monitor declares the ACP channel dead whenever `isAgentWorking` is true and no byte has arrived for 75 s. It does not exempt a pending permission request, and Hermes emits nothing while it waits for the answer. So a user who takes more than 75 s to answer an approval sheet, or a tool that runs silently for more than 75 s, gets a forced reconnect that tears down the running turn.
- **Scarf:** `scarf/Scarf iOS/Chat/ChatView.swift:2534` (`stallDetectionSeconds = 75`) and `:2550-2571` (the only condition is `vm.isAgentWorking` plus `client.secondsSinceLastIncoming`). `isAgentWorking` stays true until `promptComplete` (`RichChatViewModel.swift:2599`). `secondsSinceLastIncoming` only advances on stdout/stderr lines (`ACPClient.swift:145-157`). The 30 s `$/ping` keepalive is a notification, so it gets no reply and does not refresh the clock (`ACPClient.swift:423`). On reconnect, `handleConnectionDied` stops the old client (closing the exec channel and killing the remote turn), `clearPendingPermissions()` drops the sheet, and the load-only ladder re-attaches.
- **Hermes @v2026.9.24:** `acp_adapter/permissions.py:89-98`: the agent thread blocks on `future.result(timeout=…)`, which defaults to `approvals.timeout` = 300 s (`tools/approval_context.py:239-247`, `permissions.py:117-125`), with no intermediate output. `acp_adapter/events.py` (`make_tool_progress_cb`, around lines 127-153) emits only `tool.started` and `tool.completed`, never in-flight progress, so a long `terminal` command is silent on stdout too.
- **Failure scenario:** On ScarfGo, the agent asks to run `sudo apt upgrade`. The user reads the command and hesitates for 80 s. Before they tap Allow, the sheet disappears, the chat reconnects, and the turn is gone. Hermes never received an answer, so the command was never approved. A second example: a 2-minute `npm install` or build run by the agent is cut off the same way. Mac is unaffected, because its health monitor (`ChatViewModel.swift:2168-2180`) checks only `isHealthy`.
- **Evidence:** The detector's own comment concedes "a long-running tool call … can legitimately hold a turn silent for tens of seconds". The permission case is fully source-traced. The long-tool case depends on Hermes not incidentally logging to stderr during the tool, which is likely but not guaranteed, hence PLAUSIBLE.
- **Suggested fix:** Skip the stall check while `vm.pendingPermission != nil`, and raise the threshold or require a failed liveness probe before declaring death. For example, send a real request such as an unknown method that gets a `-32601` reply, as Hermes' `entry.py:39-42` anticipates, and treat any reply as alive.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes acp` (local argv, `forMacApp`) | argv | ACPClient+Mac.swift:59-62, 81-85 | hermes_cli/main.py:2886; acp_adapter/entry.py:175-230 | OK |
| `hermes -p <name> acp` (bot pin) | argv | ACPClient+Mac.swift:59-62 | hermes_cli/main.py:484-514, 593-650 | FINDING-F1 |
| `ssh -T host bash -lc 'COLUMNS=… [HERMES_HOME=…] hermes acp'` | argv (remote) | SSHTransport.swift:658-681, 699-719; ACPClient+Mac.swift:87-101 | main.py:603-605 (profile-shaped HERMES_HOME trusted) | OK |
| iOS `cd …; PATH=… HERMES_HOME=… exec hermes acp` | argv (remote) | ACPClient+iOS.swift:113-131 | main.py:603-605 | OK |
| Env: TERM stripped, enriched PATH, SSH_AUTH_SOCK | env | ACPClient+Mac.swift:87-109 | entry.py:65-91 (logs → stderr, .env from HERMES_HOME) | OK |
| `initialize` {protocolVersion:1, clientCapabilities:{}, clientInfo} | ACP request | ACPClient.swift:316-329 | server.py:523-544; acp meta.py PROTOCOL_VERSION=1 | OK |
| `session/new` {cwd, mcpServers:[]} → sessionId | ACP request | ACPClient.swift:436-454 | server.py:609-614 | OK |
| `session/load` {cwd, sessionId, mcpServers} → `{}` on not-found | ACP request | ACPClient.swift:456-505 | server.py:616-624; acp/agent/router.py:62-68 (normalize_result None→{}); session.py:418-428 (non-acp source → None) | OK |
| History replay `session/update` before load response | ACP notification | RichChatViewModel.swift:2104-2156 (pre-engagement gate); setSessionId :1912-1919 | server.py:563-602 | OK (rendering → S02) |
| `session/resume` | ACP request | not used (ACPClient.swift:507-523, deliberate) | server.py:626-634 | OK (TRACKED t-217da62b decision) |
| `session/prompt` {sessionId, messageId, prompt[text, image{data,mimeType}, resource]} | ACP request | ACPClient.swift:571-635 | server.py:811-876; content.py:224-275; schema PromptRequest.messageId | OK |
| PromptResponse usage {inputTokens, outputTokens, thoughtTokens, cachedReadTokens}, stopReason | ACP response | ACPClient.swift:587-612 | server.py:991-999; acp schema Usage aliases | OK |
| `session/cancel` (notification, no id) | ACP notification | ACPClient.swift:658-664; ACPMessages.swift:43-60 | router.py:112; server.py:636-657, 965/999 | OK |
| `session/set_mode` {modeId: default/accept_edits/dont_ask} | ACP request | ACPClient.swift:679-688 | server.py:240-250, 1053-1065 | OK |
| `session/set_model` {modelId: "provider:model"} | ACP request | ACPClient.swift:716-749 | server.py:1015-1051 (busy → -32603, rejected → -32602 details) | OK |
| `session/set_config_option` | ACP request | not called by Scarf | server.py:1067-1086 | OK (N/A) |
| `session/request_permission` (agent→client request, id from 0) | ACP request in | ACPClient.swift:1018-1024; ACPMessages.swift:479-499 | permissions.py:33-64, 77-114; acp connection.py:135-141 | OK |
| Permission reply {outcome:{outcome:"selected",optionId}} / {outcome:"cancelled"} | ACP response out | ACPClient.swift:773-801 | schema RequestPermissionResponse/AllowedOutcome/DeniedOutcome; permissions.py:67-74 | OK |
| `$/ping` keepalive (notification) | ACP notification | ACPClient.swift:410-432 | router.py:165-182 (method_not_found) inside connection.py:239-242 `suppress(Exception)` → silent | OK |
| JSON-RPC error `data.details` | ACP error | ACPMessages.swift:87-127; ACPClient.swift:1097-1107 | acp connection.py:228-237 | OK |
| stderr ring buffer + summary line | diagnostics | ACPClient.swift:115-157, 1138-1151 | entry.py:65-76 (`%(asctime)s [LEVEL] …` → [INFO] filtered) | OK |
| 60 s watchdog on non-prompt requests | timeout | ACPClient.swift:829-837 | server.py:612/619 (to_thread builds) | OK |
| EOF / exit code / write-fail cleanup | lifecycle | ACPClient.swift:1035-1073; ProcessACPChannel.swift:182-187, 238-310 | — | OK |
| iOS exec channel lifecycle | lifecycle | SSHExecACPChannel.swift:85-159 | — | OK |
| iOS stall detector (75 s) | timeout | Scarf iOS/Chat/ChatView.swift:2534-2571 | permissions.py:89-98; events.py make_tool_progress_cb | FINDING-F2 |
| Mac reconnect ladder (load-only) | lifecycle | ChatViewModel.swift:2270-2350 | server.py:616-624 | OK |
| iOS resume (load → fallback new) | lifecycle | Scarf iOS/Chat/ChatView.swift:3170-3190, 2795-2830 | server.py:616-624 | OK |

## Handoffs / notes (not findings)
- **S02:** replayed `plan` updates (from `todo` tool history) and `usage_update` during load pass the pre-engagement gate as `.unknown` / other events. Rendering is S02's.
- **S13/S15:** for a *non-bot* remote window whose viewing profile is "default" while the host's `active_profile` is a named profile, Scarf's file layer reads the root home, but every remote hermes invocation, ACP included, follows `active_profile`. `hermesHomeShellAssignment` returns `""` for root homes on purpose. The Design-B decision note says `-p default` would fix this. It is a cross-cutting transport choice, not ACP-specific; flagged for the profiles/transport auditors.
- **Minor, not reported:** when Hermes' 300 s approval timeout elapses first, the permission sheet stays up until `promptComplete`, and a late tap answers an id Hermes has already dropped. Hermes ignores it (`task/state.py:57-60`). It is cosmetic and rare.

## Not audited / couldn't verify
- I did not live-probe `hermes acp` itself; the brief forbids starting it. All wire shapes are source-traced against the tag and the pinned acp 0.9.0 lib in `~/.hermes/hermes-agent-v0215/.venv`.
- `session/load` replay duration for very large sessions over slow links, against the 60 s watchdog: the replay is awaited before the response (server.py:589), so huge transcripts over a slow SSH link could in principle approach the watchdog. I did not measure it.
- Remote login shells other than bash/sh (for example fish) for the iOS `PATH="…$PATH" … exec` prefix are outside the brief's scope.
- iOS `hostKeyValidator: .acceptAnything()` (ACPClient+iOS.swift:161) is a security posture for S15/security, not a Hermes-compat issue.
