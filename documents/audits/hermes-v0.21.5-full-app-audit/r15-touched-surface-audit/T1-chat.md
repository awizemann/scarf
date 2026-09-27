# T1-chat — verdict: WORKS-WITH-ISSUES

Scope: every file in `T1-chat.txt`, read against Hermes `~/.hermes/hermes-agent-v0215` (tag v2026.9.24, 0.21.5), with the integration worktree `/Users/awizemann/Developer/Scarf-wt/integration`. The pre-remediation chat findings (S01-F1/F2, S02-F1..F4, S03-F1..F6, S13-F2) were checked in passing and all are fixed in the current code. The one exception is S12-F6: the mini-app session still uses the project cwd, which is Alan's recorded decision (TRACKED). There are no P0 or P1 findings. Four new findings: one P2 and three P3.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Spawn `hermes acp` (local, `ssh -T` remote, iOS Citadel exec) and `initialize` | WORKS | — |
| 2 | New chat, resume (`session/load`, falls back to `session/new` + DB transcript), autostart after the connection was lost, held sends, replay gate | WORKS | — |
| 3 | Send a prompt: stream text and thoughts, tool cards, `promptComplete`, echo-to-row reconciliation (`notePromptWire`, `persistedUserRowKeys`) | WORKS | — |
| 4 | Stop (`session/cancel` notification) and permission prompts (`request_permission` with a selected/cancelled reply) | WORKS | F3 (P3) |
| 5 | Reconnect ladder (Mac with held sends and drain; iOS load-only) and the iOS stall policy (75 s / 900 s) | WORKS | — |
| 6 | Sidebar rename / delete (`sessions rename -- id title`, `sessions delete --yes -- id`, whole chain) | WORKS | F4 (P3) |
| 7 | Project model preset and auto-accept edits (`session/set_model` provider:model, `session/set_mode`), mid-chat model/mode switch | WORKS | — |
| 8 | Slash menu: ACP roster, static fallback, project and global `/scarf-*` expansion, remote bootstrap, quick commands kept out of the chat menu, bundled `scarf-cron`/`scarf-export` bodies | WORKS | — |
| 9 | Personalities (`display.personality`, SOUL.md) with honest "CLI, TUI and gateway" scoping | WORKS | — |
| 10 | Bot Chat: ACP-born sessions stream; CLI-born sessions go through `hermes -p <bot> chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file`; the first message creates the chat | DEGRADED | F1 (P2) |
| 11 | Bot routines and bot agent config (`-p <bot> tools enable|disable --platform`, `config set/unset`) | WORKS | — |
| 12 | Mini-app agent session (own `hermes acp`, auto-deny permissions, end-of-turn drain handshake) | WORKS | TRACKED (S12-F6 decision) |
| 13 | Terminal-mode chat and voice (`chat` / `--resume` / `--continue`, `/voice on|off|tts`, Ctrl+B) | WORKS | — |
| 14 | ACP error classification hints | DEGRADED | F2 (P3) |

## Findings

### T1-chat-F1 · P2 · SOURCE · NEW
- **Claim:** Every Bot Chat turn sent over the CLI transport is hard-killed after 300 s. This includes the first message, which creates the chat. A long bot turn therefore ends as a failure banner and its reply is lost.
- **Scarf:** `scarf/scarf/Features/Bots/ViewModels/BotConversationViewModel.swift:623` (`context.runHermes(argv, timeout: 300)` inside `createCanonicalBotChat`). `deliverViaCLI` (:302-337) and `createThenConnect` (:494-515) both go through it. The timeout path is `LocalTransport.runProcess` → `waitDraining` → SIGTERM → `TransportError.timeout` (`Packages/ScarfCore/Sources/ScarfCore/Transport/LocalTransport.swift:335-342`). On failure `deliverViaCLI` calls `rich.cancelPendingSend()`, which stops the DB poll, and sets `acpError`.
- **Hermes @v2026.9.24:** `hermes_cli/cli_single_query.py:180-260` runs `-Q` as one synchronous `run_conversation` with no turn cap of its own. It then lingers for notify completions (`continue_quiet_notify_completions`, `quiet_notify_linger_seconds()`). Hermes' own Bot Mode delivery (`tools/bot_mode_dm.py:282`, `_start_delivery`/`_spawn_delivery`) runs the same command as a background process and never kills it; only the reply waiter has a budget (`:733-758`).
- **Failure scenario:** The user asks a bot for a task that runs tools longer than 5 minutes: a build, several web extracts, or a delegate. At 300 s Scarf SIGTERMs `hermes chat`. The user row is already in `state.db`, but the assistant reply is never written or is cut off. The Bot Chat shows "Couldn't start <bot>'s conversation (hermes exited …)" or the partial output as an error. Polling has stopped, so the transcript does not recover until the chat is reopened. On a bot with no chat yet, the first message sits in `.creating` for 5 minutes and then fails.
- **Evidence:** `timeout: 300` is the only bound. Nothing in `.memory/decisions`, `tasks/` or the audits records the cap as deliberate.
- **Suggested fix:** Run the CLI delivery without a hard kill (or with a far larger ceiling) and let the existing `state.db` poll show the reply. Or spawn it detached, the way Hermes' `_start_delivery` does.

### T1-chat-F2 · P3 · LIVE · NEW
- **Claim:** The error hint for a session whose model is no longer available tells the user to run `hermes sessions clone`, and that verb does not exist.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift:1385`
- **Hermes @v2026.9.24:** the `sessions` subparser has `list, export, delete, prune, archive, optimize, clean-markers, optimize-storage, repair, set-journal-mode, repair-routing, repair-profiles, recover, stats, rename, pin, unpin, pinned, retitle-skills, browse, import` and no `clone` (`hermes_cli/sessions_cmd.py:1005` dispatch table). The hint's claim that the session is pinned to its model is also stale: Scarf's own header model switch (`session/set_model`, `acp_adapter/server.py:1015-1051`) changes the model of the live session.
- **Failure scenario:** A provider drops the model, a resumed chat returns 404/model_not_found, and the banner's recovery step fails with an argparse "invalid choice".
- **Evidence:** `hermes sessions --help` lists no `clone`.
- **Suggested fix:** Point the hint at the chat header's model switcher (or at starting a new chat) instead.

### T1-chat-F3 · P3 · SOURCE · NEW (the behaviour is described in `.memory/architecture/chat-session-layer-mechanism-map-and-2026-07-13-diagnosis.md:74`, but only as a stall-detector input, not as a UI defect)
- **Claim:** When Hermes gives up on an unanswered permission prompt after `approvals.timeout` (300 s by default), it denies the tool and sends a closing update. Scarf drops that update, so the permission sheet stays open. An "Allow" tapped later does nothing, and the user has no way to know.
- **Scarf:** `Packages/ScarfCore/Sources/ScarfCore/Models/ACPMessages.swift:584-602` (`parsePermissionRequest` keeps the title, kind and options but not `toolCall.toolCallId`). `Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift:2680-2704` drops a `tool_call_update` whose id never had a start. Pending permissions are cleared only at turn end, connection loss or reset (`:2837`, `:2953`, `:1992`).
- **Hermes @v2026.9.24:** `acp_adapter/permissions.py:54-64` builds the request's tool call as `perm-check-N`. `:94-99` hits `FutureTimeout`, calls `future.cancel()` and sets `timed_out`. `:102-113` sends `update_tool_call(perm-check-N, status="failed")` to the client. The default timeout is 300 s (`tools/approval_context.py:239-247`).
- **Failure scenario:** The agent asks to run `rm -rf build/`. The user steps away for 6 minutes. Hermes self-denies and carries on with the turn. The Allow/Deny sheet is still on screen. The user taps Allow and believes the command ran. The reply to the cancelled request is discarded and the tool never executed.
- **Suggested fix:** Keep `toolCall.toolCallId` on `PendingPermission`. When a `tool_call_update` arrives for that id, resolve the sheet and show a short "Hermes timed out waiting — denied" hint.

### T1-chat-F4 · P3 · SOURCE · NEW
- **Claim:** If the chat sidebar's delete fails outright (the first segment's `hermes sessions delete` exits non-zero), Scarf gives no feedback at all.
- **Scarf:** `scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:3153` returns early when `outcome.deleted` is empty. Only a partial chain failure gets a hint (`:3163-3170`). `ChatSessionListPane.swift:122-125` fires the delete and forgets it. For comparison, rename does surface its error (`:3034-3041`).
- **Hermes @v2026.9.24:** `hermes_cli/sessions_cmd.py:575-590`: `_not_found` returns 1, and a `delete_session` failure also returns through `_not_found`. A locked or unwritable DB raises an error with a non-zero exit.
- **Failure scenario:** The user confirms "Delete", the row stays in place, and nothing explains why. The row staying is honest, but the silence is misleading.
- **Suggested fix:** Set a `transientHint` or `acpError` with the CLI output when `outcome.failed != nil && outcome.deleted.isEmpty`.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes acp` local / `-p <bot> acp` | argv | ACPClient+Mac.swift:57-61,77-85 | hermes_cli/main.py:484-524,593-650 | OK |
| remote `ssh -T … [-p default] hermes acp`, `HERMES_HOME=` for a named profile | argv | HermesProfileScope.swift:172,221-242; SSHTransport.swift:741-745 | main.py:603-605,607-619; profiles.py:2366-2369 | OK |
| iOS `cd …; PATH=… HERMES_HOME=… exec hermes [-p default ]acp` | argv | ACPClient+iOS.swift:117-142 | same | OK |
| `initialize` {protocolVersion 1, clientCapabilities, clientInfo} | ACP req | ACPClient.swift:323-336 | acp_adapter/server.py:523-544 | OK |
| `session/new` {cwd, mcpServers:[]} | ACP req | ACPClient.swift:445-463 | server.py:609-614 | OK |
| `session/load` ({} → not restorable) + `_meta.hermes.sessionProvenance` | ACP req | ACPClient.swift:478-529 | server.py:616-624; session.py:428 (`source != "acp"` → None) | OK |
| `session/prompt` {sessionId, messageId, prompt[resource…, text, image]} | ACP req | ACPClient.swift:595-659 | server.py:811-876; content.py | OK |
| prompt usage / stopReason (`end_turn`/`cancelled`/`refusal`) | ACP resp | ACPClient.swift:611-636; RichChatViewModel.swift:2811-2925 | server.py:816-843,991-999 | OK (session-cumulative usage `+=` is TRACKED S02 latent note, masked by the DB value) |
| `session/cancel` (notification) | ACP notif | ACPClient.swift:682-688,912-935 | acp router.py:112; server.py:636-657 | OK |
| write ordering (`writeTail`), keepalive `$/ping` outside the queue | transport | ACPClient.swift:88,892-907,434-441 | router.py:165-182 | OK (ProcessACPChannel.send is an actor with a synchronous write; the ping cannot interleave) |
| `session/set_model` provider:model | ACP req | ACPClient.swift:740-773; ChatViewModel.swift:1825-1880 | server.py:1015-1051 (busy → -32603, rejected → -32602) | OK |
| `session/set_mode` default/accept_edits/dont_ask | ACP req | ACPClient.swift:703-712; ChatViewModel.swift:1891-1916,1979-2004 | server.py:1053-1066 | OK |
| `session/request_permission` in, selected/cancelled out | ACP req/resp | ACPMessages.swift:584-602; ACPClient.swift:797-825 | permissions.py:33-64,77-114 | FINDING-F3 |
| `session/update` types (message/thought/user chunks, tool_call, tool_call_update, available_commands, session_info_update) | ACP notif | ACPMessages.swift:510-582 | events.py; tools.py:781-854; commands.py:85-94; server.py:393-420 | OK |
| `messageId` reply split | ACP field | RichChatViewModel.swift:2557-2602 | events.py:185-236 | OK |
| perm-check-N / edit-approval-N updates dropped | ACP notif | RichChatViewModel.swift:2680-2704 | permissions.py:113; edit_approval.py:199-207 | OK (for the transcript) / FINDING-F3 (sheet) |
| replay gate + held sends + event-loop drain | lifecycle | ChatViewModel.swift:1250-1345,1350-1500,2429-2438,2495-2650 | server.py:563-602 | OK |
| echo reconciliation keys (`[screenshot]`, slash names, /steer,/queue args) | reconciliation | RichChatViewModel.swift:2041-2186 | session_persistence.py:69-119; commands.py:97-104 | OK |
| ACP slash roster help/model/tools/context/reset/compress/steer/queue/version | ACP prompt | RichChatViewModel.swift:823-900 | commands.py:53-80 | OK |
| global `/scarf-*` bootstrap (local + remote) and expansion | Scarf file | SlashCommandBootstrapService.swift; scarfApp.swift:119-125,519-522; RichChatViewModel.swift:1560-1580 | n/a | OK |
| `scarf-cron.md` body: `cron create --name --workdir --deliver <schedule> <prompt>`, `cron list` | agent prompt | BuiltinSlashCommands.bundle/scarf-cron.md | `hermes cron create --help` (LIVE) | OK |
| `scarf-export.md` body | agent prompt | scarf-export.md | n/a | OK |
| `hermes config set display.personality <name>` (default = neutral) | argv | PersonalitiesViewModel.swift:109-140 | hermes_cli/personality.py:16,86-124 | OK |
| `agent.personalities` / root `personalities` read, SOUL.md write | config/file | PersonalitiesViewModel.swift:56-100,142-163 | personality.py:86-97 | OK |
| `approvals.mode == off` → YOLO chip | config read | SessionInfoBar.swift:141-146,209 | tools/approval_context.py:197-214 | OK |
| `hermes sessions rename -- id title` | argv | ChatViewModel.swift:630-632,3017-3063 | sessions_cmd.py:726-744 | OK |
| `hermes sessions delete --yes -- id` (chain, tip first) | argv | ChatViewModel.swift:621-623,3137-3200 | sessions_cmd.py:575-590 | FINDING-F4 (feedback only) |
| Bot Chat CLI `-p <bot> chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file` | argv | BotConversationViewModel.swift:541-552,583-631 | `hermes chat --help` (LIVE); cli_single_query.py:150-260; main.py:1542-1558 | FINDING-F1 (timeout) |
| Bot Chat ACP-born gate (`source == "acp"`) | ACP | BotConversationViewModel.swift:210-247 | acp_adapter/session.py:428 | OK |
| `-p <bot> tools enable|disable <ts> --platform <p>` | argv | BotAgentConfigService.swift:318-337 | `hermes tools enable --help` (LIVE) | OK |
| `-p <bot> config set/unset` | argv | BotAgentConfigService.swift:515,552,558-561 | `hermes config unset --help` (LIVE) | OK |
| bot routine → `cron create … --deliver bot-chat:<bot>` | argv | BotRoutinesViewModel.swift:180-275 | `cron create --help` lists `bot-chat[:profile]` (LIVE) | OK |
| bot config.yaml read (model.default/provider/base_url, skills.disabled, platform_toolsets, mcp_servers.*.enabled) | config read | BotAgentConfigService.swift:105-200 | config_defaults.py | OK (config internals owned by T3) |
| mini-app `hermes acp` + `session/new(cwd: projectRoot)` + auto-deny | ACP | MiniAppAgentSession.swift:180-200,300-312 | server.py:759-770 | TRACKED (decision project-context-file-injection…:34,56) |
| terminal mode `chat`, `chat --resume <id>`, `chat --continue` | argv | ChatViewModel.swift:1036,1107,1161,3474-3550 | `hermes chat --help` (LIVE) | OK |
| `/voice on|off|tts`, Ctrl+B record key | TTY | ChatViewModel.swift:3422-3465 | cli_commands_mixin.py:2719-2721; config_defaults.py:1203 | OK |
| error hint `hermes sessions clone` | copy | ACPClient.swift:1385 | `hermes sessions --help` (LIVE) | FINDING-F2 |
| hint `hermes profile use <name>` | copy | SessionInfoBar.swift:179 | `hermes profile use --help` (LIVE) | OK |
| state.db reads (history, reconcile, poll, tool hydration, cost) | SQL | RichChatViewModel.swift:3141-3860 | — | OK / owned by T2 |
| iOS stall policy (75 s / 900 s) | timeout | ACPStallPolicy.swift; Scarf iOS/Chat/ChatView.swift:2553-2585 | permissions.py:117-125; terminal_tool.py:75 | OK |
| compaction-summary markers | parse | HermesMessage.swift:178-189 | context_compressor.py:258,292,484,4124-4133 | OK |
| stored tool_calls `{id, function{name, arguments}}` | parse | HermesMessage.swift:366-386 | — | OK |

## Not audited / couldn't verify
- Live Voice and HermesSpeechService internals (VoiceLive*, HermesSpeechService) are not in this manifest. Only the ChatViewModel host seams were read.
- SQL text in RichChatViewModel / HermesDataService belongs to T2 (sessions). I checked only how the results are used.
- iOS reconnect sets `.ready` without waiting for the load replay to drain, unlike the Mac held-send path. The window is sub-second, because replay events are dropped cheaply on the main actor, and I could not show that a user can hit it. It is not reported.
- `ScarfMiniAppBridge.handleQuery("kanban.tasks")` runs `KanbanTenantReader` (transport I/O) inside a MainActor-inherited `Task`. On a remote host that would be SSH on the main actor, but mini-app assets are anchored to the local context (`MiniAppSchemeHandler.swift:66-68`), so I could not show that a remote mini-app reaches it. It is not reported.
- QuickCommandsView says removal needs hand-editing config.yaml because there is "no unset primitive". `hermes config unset` does exist (`hermes_cli/config.py:3656`), so this is a feature gap, not a defect.
- Nothing was run beyond `--help` probes. There is no live ACP session trace.
