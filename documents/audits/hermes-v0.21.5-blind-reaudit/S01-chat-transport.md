# S01-chat-transport — verdict: WORKS-WITH-ISSUES

The ACP wire layer matches Hermes v2026.9.24 on every method Scarf uses: framing, request/notification shape, result parsing, error `data.details`, the permission round trip, profile pinning, and the local, Mac-SSH and iOS-Citadel spawn paths. Two findings, neither a transport break:
- F1: the Mac approval-mode chip goes stale after a reconnect.
- F2: no user-facing Stop control exists, although the wiki documents one.

The acp library used for library-side citations is agent-client-protocol 0.9.0 (`~/.hermes/hermes-agent/venv/.../site-packages/acp`). That is the exact version the tag pins (`pyproject.toml:306` `agent-client-protocol==0.9.0`). Library paths below are relative to that `acp/` directory.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Spawn `hermes acp` + `initialize` (local, Mac SSH, iOS Citadel) | WORKS | — |
| 2 | `session/new` with cwd + `mcpServers: []` | WORKS | — |
| 3 | `session/load` / resume of an existing session (+ replay, + not-restorable fallback) | WORKS | — |
| 4 | `session/prompt` with text, image, embedded-resource blocks; stopReason + usage parse | WORKS | — |
| 5 | `session/cancel` mid-turn | DEGRADED | F2 (wire correct; no user control) |
| 6 | Process death / EOF / SSH drop → reconnect via `session/load` | WORKS | F1 (mode chip after reconnect) |
| 7 | `session/set_mode`, `session/set_model` (config-option not used) | WORKS | F1 |
| 8 | `session/request_permission` round trip (dangerous-command + edit approval) | WORKS | — |
| 9 | stderr capture, error-hint classification, request timeouts, keepalive | WORKS | — |
| 10 | Profile selection (HERMES_HOME / `-p`) local and remote | WORKS | — |

### Journey notes (traced, no defect)
- **Initialize.** Scarf sends `protocolVersion: 1`, `clientCapabilities: {}`, and `clientInfo` (`ACPClient.swift:323-332`). Hermes returns `PROTOCOL_VERSION=1` with `loadSession=True`, `image=True`, fork/list/resume (`acp_adapter/server.py:523-544`). Scarf advertises no fs/terminal capabilities. The only client-bound request Hermes makes is `session/request_permission` (`server.py:922,927`), so nothing goes unanswered. `authenticate` is not needed: `new_session`/`load_session` have no auth gate (`server.py:609-624`).
- **Framing.** Hermes logs go to stderr (`acp_adapter/entry.py:65-76`) and stdout is JSON-RPC only. The acp lib's stdin buffer is 50 MB (`core.py:35`), well above image prompts. Scarf skips non-JSON stdout lines (for example from a login-shell banner) instead of dying (`ACPClient.swift:971-979`).
- **session/load.** Hermes restores only `source == "acp"` rows (`session.py:418-430`). For anything else `load_session` returns None, which the acp lib's `normalize_result` turns into `{}` (`agent/router.py:62-68`, `utils.py:59-65`). Scarf treats null or `{}` as not restorable (`ACPClient.swift:516-521`).
  - A real success is never empty, because `modes` is always present (`server.py:282-291,597-602`).
  - Hermes replays history as `session/update` before it responds (`server.py:572-596`). Scarf waits for that replay to drain (`awaitEventLoopDrain`) and drops it through the replay gate. The replay-rendering details belong to S02.
  - The fallback `session/new` plus state.db transcript for CLI/cron sessions is deliberate (`ChatViewModel.swift:2179-2194`, `Scarf iOS/Chat/ChatView.swift:3232-3237`). Both reconnect ladders are load-only, by decision (`ChatViewModel.swift:2557-2569`).
- **session/prompt.** Block order is note → text → images (`ACPClient.swift:644-659`), which matches `_content_blocks_to_openai_user_content` (`content.py:249-275`). The PromptResponse usage aliases `inputTokens`, `outputTokens`, `thoughtTokens` and `cachedReadTokens` match the acp schema's `Usage` aliases (`schema.py:1124-1162`). `stopReason` values are `end_turn`, `cancelled` and `refusal` for a missing session (`server.py:815,999`). `refusal` gets a hint (`RichChatViewModel.swift:704`).
- **Cancel wire.** Scarf sends an id-less notification (`ACPClient.swift:682-688`, `ACPMessages.swift:43-60`). Hermes routes it as a notification (`agent/router.py:112`) → `cancel` (`server.py:636-657`) → `stopReason: "cancelled"`.
- **set_model.** It is routed `unstable=True` (`agent/router.py:80-87`), but `entry.py:225` runs with `use_unstable_protocol=True`. The busy case returns -32603 (`server.py:1025-1028`), which Scarf surfaces and reverts (`ChatViewModel.swift:1867-1878`). `set_mode` normalizes the id and returns `{}` (`server.py:1053-1065`).
- **Permissions.** The request carries `toolCall.{toolCallId,title,kind}` and `options[].{optionId,name}` (`permissions.py:33-64`, `edit_approval.py:199-207`), which the parser reads (`ACPMessages.swift:589-610`). Scarf's reply is `{"outcome":{"outcome":"selected","optionId":…}}` or `{"outcome":{"outcome":"cancelled"}}` (`ACPClient.swift:797-825`), which matches `AllowedOutcome` / `_map_outcome_to_hermes` (`permissions.py:67-74`). Edit approval accepts only `allow_once` (`edit_approval.py:237-239`).
- **Keepalive.** `$/ping` is an unknown notification. The acp lib raises method_not_found inside `_run_notification`, which suppresses it (`connection.py:239-242`), so there is no reply and no stderr noise.
- **Error surfacing.** For internal errors the lib puts the exception text in `error.data.details` (`connection.py:222-232`), and Scarf decodes it (`ACPMessages.swift:110-126`). `summaryLine` drops the `[INFO]` lines that match Hermes' log format (`entry.py:70`). Control RPCs have a 60 s watchdog and prompts have none (`ACPClient.swift:853-861`). A request sent after EOF fails fast (`:872-874`). EOF or a broken pipe fails every pending request with the exit code and stderr tail (`:1073-1091`).
- **Profiles.**
  - Mac local runs `hermes acp` with no pin, so it follows `active_profile`, which is also where the window reads its files. A bot gets `-p <bot>` or `-p default` (`ACPClient+Mac.swift:65-69`).
  - Mac SSH runs `ssh -T host bash -lc 'COLUMNS=… [HERMES_HOME=…] hermes [-p default] acp'` (`SSHTransport.swift:671-714,746-767`).
  - iOS runs `sh -c 'cd …; PATH=… [HERMES_HOME=…] exec hermes [-p default] acp'` (`ACPClient+iOS.swift:118-141`).
  - `-p default` resolves to the root (`hermes_cli/profiles.py:2366-2368`). A root `HERMES_HOME` alone would still follow `active_profile` (`hermes_cli/main.py:601-619`), which is why the root pin exists.

## Findings

### S01-F1 · P3 · SOURCE · NEW
- **Claim:** After a reconnect or autostart, the Mac approval-mode chip keeps the mode the user picked by hand ("Accept Edits" / "Don't Ask"). The newly loaded Hermes session is back at `default`, and Scarf neither re-asserts the mode nor reads `modes.currentModeId` from the load response.
- **Scarf:**
  - `scarf/Features/Chat/ViewModels/ChatViewModel.swift:2569-2608`: the reconnect ladder calls only `setSessionId` and re-applies only the *project* opt-in (`applyProjectAutoAcceptEdits`). It does not call `reset()`, so `activeApprovalMode` survives.
  - The same pattern appears in the autostart path, `ChatViewModel.swift:1417-1446`.
  - `ACPClient.swift:516-528` discards the load response's `modes`.
  - `RichChatViewModel.swift:1150,2073`: the chip is reset only by `reset()`.
- **Hermes @v2026.9.24:**
  - `acp_adapter/server.py:1053-1065`: `set_session_mode` stores `state.mode` only in memory.
  - `acp_adapter/session.py:130-153`: `SessionState` has no `mode` field.
  - `session.py:314-323`: `_persist` stores only cwd, provider, base_url and api_mode.
  - `server.py:282-291`: `_session_modes` falls back to `default`. A fresh `hermes acp` that restores via `_restore` (`session.py:418-446`) therefore starts at `default`, and the load response says so.
- **Failure scenario:** The user picks "Don't Ask" in the chat header. The ACP process dies, or a Mac SSH link drops, and the reconnect ladder reloads the session. The header still shows "Don't Ask", but Hermes asks before every edit again, and the user gets approval sheets that contradict the chip. This is the safe direction (more prompts, not fewer).
- **Evidence:** A memory decision in `.memory/decisions/Hermes v0.15 Capability Gating Decisions.md:12` already notes that "each of those is a fresh one" for the project opt-in. The manual chip choice was not covered.
- **Suggested fix:** On reconnect or autostart, re-send `session/set_mode` for a non-default `activeApprovalMode`, or set the chip from the load response's `modes.currentModeId`.

### S01-F2 · P2 · SOURCE · NEW
- **Claim:** Neither the Mac nor the iOS chat has a user-reachable Stop control that sends `session/cancel` for a running turn. The wiki tells users to press one.
- **Scarf:**
  - `scarf/Features/Chat/Views/RichChatInputBar.swift:272-290`: the composer has only a send button (`arrow.up`), disabled while it can't send, and no stop state. Escape only closes the slash menu (`:250-254`).
  - The only `client.cancel` callers are teardown (`ChatViewModel.swift:2698,2764`, reached only from `stopACP()`, which also kills the process) and voice barge-in (`ChatViewModel.swift:3785`, `Scarf iOS/Chat/VoiceLive/ChatController+VoiceTurnHost.swift:133`). There is no stop/cancel UI anywhere in `Scarf iOS/Chat`.
  - Docs: `wiki/Chat.md:204` says "The Stop button sends `session/cancel`…". `wiki/ScarfGo.md:125` says "Tap the Stop button in Chat to abort — that always works."
- **Hermes @v2026.9.24:** `acp_adapter/server.py:636-657` (cancel) and `:999` (`stopReason: "cancelled"`). The wire path works; it just has no user entry point.
- **Failure scenario:** A turn runs away, for example a long tool loop or a model stuck repeating. The user looks for Stop as the docs describe and finds none. The only ways out are to switch or delete the session, which calls `stopACP` and kills the `hermes acp` process after a 2 s bounded cancel, or to wait for the turn to finish. On iOS, the documented escape hatch for an "agent running forever" does not exist.
- **Evidence:** `grep` finds no `stop.fill`, `stop.circle` or "Stop" control in the Chat views on either platform. The memory note `.memory/architecture/chat-session-layer-mechanism-map-and-2026-07-13-diagnosis.md:56` refers to "Any future Stop button", which confirms none exists. No TASKS.md entry covers the main chat. t-14157321 is the Bot Chat CLI transport only.
- **Suggested fix:** Turn the send button into Stop while `isAgentWorking`. Call `noteTurnCancelRequested()` and then `client.cancel(sessionId:)`, keep the session alive, and answer any queued permission requests with `cancelled`. Otherwise correct the two wiki passages.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes acp` (local, optional `-p <bot>`) | argv | `scarf/Core/Services/ACPClient+Mac.swift:65-69,78-118` | `hermes_cli/main_agent_cmds.py:79-89`; `acp --help` LIVE | OK |
| `ssh -T … bash -lc '… hermes [-p default] acp'` | argv (Mac SSH) | `SSHTransport.swift:671-714,746-767` | `hermes_cli/main.py:595-619`, `profiles.py:2355-2372` | OK |
| `sh -c 'cd…; PATH=… HERMES_HOME=… exec hermes [-p default] acp'` | argv (iOS) | `ScarfIOS/ACPClient+iOS.swift:80-84,118-141` | same | OK |
| HERMES_HOME / profile pin | env / flag | `HermesProfileScope.swift:262,298`; `ACPClient+Mac.swift:65-69` | `hermes_cli/main.py:601-619` | OK |
| `initialize` | ACP request | `ACPClient.swift:323-336` | `server.py:523-544` | OK |
| `session/new` (cwd, mcpServers) | ACP request | `ACPClient.swift:445-463` | `server.py:609-614` | OK |
| `session/load` (+ `{}` not-restorable, `_meta.hermes.sessionProvenance`) | ACP request | `ACPClient.swift:478-529`; `ACPMessages.swift:473-506` | `server.py:572-602,616-624`; `session.py:418-446`; `acp/utils.py:59-65` | OK |
| `session/resume` | ACP request | not sent (`ACPClient.swift:531-547`) | `server.py:626-634` | OK (deliberate) |
| `session/prompt` text/image/resource blocks, messageId | ACP request | `ACPClient.swift:595-659`; `ACPContextNote.swift:33-42` | `server.py:811-876`; `content.py:222-275` | OK |
| PromptResponse `stopReason`, `usage.*Tokens` | response parse | `ACPClient.swift:611-636` | `server.py:986-999`; `acp/schema.py:1124-1162` | OK |
| `session/cancel` (notification) | ACP notification | `ACPClient.swift:682-688`; `ACPMessages.swift:43-60` | `server.py:636-657`; `acp/agent/router.py:112` | OK (UI: FINDING-F2) |
| `session/set_mode` | ACP request | `ACPClient.swift:703-712` | `server.py:1053-1065` | OK (FINDING-F1) |
| `session/set_model` (`provider:model`) | ACP request | `ACPClient.swift:740-773` | `server.py:1015-1051`; `entry.py:225` | OK |
| `session/set_config_option` | ACP request | not used | `server.py:1067-1087` | OK (n/a) |
| `$/ping` keepalive | ACP notification | `ACPClient.swift:419-441` | `acp/connection.py:239-242`, `acp/router.py:165-183` | OK |
| `session/request_permission` in + outcome reply | ACP request/response | `ACPClient.swift:797-825,1056-1062`; `ACPMessages.swift:589-610` | `permissions.py:33-114`; `edit_approval.py:199-239` | OK |
| `session/update` notifications | ACP notification | `ACPMessages.swift:511-657` | `events.py`, `server.py:125-167` | OK at transport level; rendering → S02 |
| JSON-RPC error `data.details` | response parse | `ACPMessages.swift:87-127`; `ACPClient.swift:1135-1145` | `acp/connection.py:222-232` | OK |
| stderr ring buffer / summary line / hints | stderr | `ACPClient.swift:125-160,1176-1189,1257-1391` | `entry.py:65-76` | OK |
| Control-RPC 60 s watchdog; no prompt timeout | timeout | `ACPClient.swift:853-861` | — | OK |
| EOF / exit code / broken pipe → processTerminated | lifecycle | `ACPClient.swift:1073-1111`; `ProcessACPChannel.swift:56-58,182-187,199-234` | `entry.py:224-230` | OK |
| Close: stdin EOF → SIGINT → SIGTERM → SIGKILL | lifecycle | `ProcessACPChannel.swift:238-310` | `entry.py:226-227` | OK |
| iOS Citadel exec channel framing / close | transport | `ScarfIOS/SSHExecACPChannel.swift:85-216` | — | OK |
| iOS stall ceilings (75 s / 900 s) | policy | `ACPStallPolicy.swift:29-57` | `permissions.py:117-125`; `events.py:119-153` | OK |

## Not audited / couldn't verify
- No live ACP session was run: probes were limited to `--help`/`--version`, per the brief. Replay timing against the 60 s `session/load` watchdog for very long sessions over slow SSH links was not measured. It is plausible but unproven that a huge session could time out. The fallback would then open a fresh session while Hermes finishes the load.
- Transcript rendering of replay, message chunks, tool-call cards and permission-sheet UX belong to S02. Slash commands, voice and `/steer` belong to S03. MiniApp and Bot Chat (S13) use ACPClient but were not traced beyond the transport.
- Mac SSH keepalive (`sshArgs()` ServerAlive options) and the Citadel `withExecTolerantClose` internals are owned by S15.
- A "Hermes binary" hint that is a `docker compose exec …` fragment would need `-T` for binary-clean ACP stdio. That is unusual config and out of scope.
