# S03-chat-surfaces — verdict: WORKS-WITH-ISSUES

Everything around the chat turn works against Hermes v2026.9.24 (0.21.5) on its main paths: the ACP slash commands, the project and global Scarf slash-command expansion, the model and approval-mode switches, session rename and delete, Hermes Voice TTS and the Live Voice host exchange. The problems are all P2/P3, in secondary surfaces:
- Quick commands and the active personality both look like chat features, but Hermes's ACP adapter (which Scarf's chat talks to) ignores both of them.
- The YOLO warning chip checks for a config value Hermes does not have.
- A bundled agent prompt tells the agent to use cron flags that don't exist.
- One main-actor subprocess spawn.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Slash menu: ACP-advertised and static fallback commands (`/help /model /tools /context /reset /compress /steer /queue /version`, client-side `/new`) | WORKS | — (roster matches `acp_adapter/commands.py:53-80`; `/new` name drop is TRACKED t-fa0043f6) |
| 2 | Slash menu: user `quick_commands` rows | BROKEN | F1 |
| 3 | Project-scoped and global `/scarf-*` commands (client-side expansion, sent as a plain prompt) | WORKS locally; DEGRADED on remote | F5, F6 |
| 4 | Built-in bundle install (SlashCommandBootstrapService) | WORKS (local, active profile); never runs for remote hosts | F5 |
| 5 | Personalities: pick active and edit SOUL.md | DEGRADED | F2 |
| 6 | Quick Commands editor (`hermes config set quick_commands.<n>.{type,command}`) | WORKS | — |
| 7 | Model badge and mid-chat switch (`session/set_model`), model preflight sheet | WORKS | — (config write path belongs to S06) |
| 8 | Approval-mode chip (`session/set_mode`) and YOLO chip | Chip: WORKS; YOLO chip: BROKEN | F3 |
| 9 | Session list: new/resume (handed to S01), rename, delete | WORKS; rename blocks the main actor | F4 (delete main-actor spawn TRACKED t-fa0043f6) |
| 10 | Hermes Voice message TTS (HermesSpeechService) | WORKS | — |
| 11 | Live Voice: host exchange, readiness (`voice.voice_chat_mode`), chained turns | WORKS | — |
| 12 | iOS ChatView differences | Same shared VM paths; F1 applies; iOS never gets global `/scarf-*` (F5) | F1, F5 |

## Findings

### S03-F1 · P2 · SOURCE · NEW (related to TRACKED t-fa0043f6, unknown-slash notice)
- Claim: Scarf offers `quick_commands` in the chat slash menu (Mac and iOS) as "Run: <cmd>", but over ACP a quick command is never executed. The literal `/name` goes to the model as an ordinary prompt.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift:2224-2241` (loads the rows with source `.quickCommand`), `:1003-1007` (merges them into `availableCommands`), `:1554` (doc comment: quick commands "go to Hermes literally"); `scarf/Features/Chat/Views/SlashCommandMenu.swift:115` ("user" pill); `Scarf iOS/Chat/IOSSlashCommandMenu.swift:91`; `scarf/Features/QuickCommands/Views/QuickCommandsView.swift:56` ("Shell shortcuts hermes exposes in chat as `/command_name`").
- Hermes @v2026.9.24: `acp_adapter/commands.py:53-80` (`_COMMANDS` has no quick-command lookup); `:103-104` (an unknown name returns `None`); `acp_adapter/server.py:827-837` (a `None` result falls through to the agent turn). `quick_commands` is only dispatched by `cli.py:1219-1222` (`_run_quick_command` `:1233`), `gateway/run_inbound.py:812,1033` and `tui_gateway/methods_tools.py:551`. `acp_adapter/` never reads it.
- Failure scenario: the user defines `quick_commands.deploy: {type: exec, command: ./deploy.sh}`, types `/deploy` in a Scarf chat and picks the "Run: ./deploy.sh" row. The script never runs. The LLM gets "/deploy", which costs a turn, and the model may improvise (possibly calling its own terminal tool on a guess).
- Suggested fix: drop `.quickCommand` rows from the ACP chat menu, or run them Scarf-side through the transport (the CLI's `exec` semantics) and show the output locally. Also fix the editor subtitle.

### S03-F2 · P2 · SOURCE · NEW
- Claim: the "Active Personality" Scarf writes (`display.personality`) has no effect on Scarf's own chats. The ACP adapter never applies a personality overlay. Only the CLI, TUI and gateway do.
- Scarf: `scarf/Features/Personalities/ViewModels/PersonalitiesViewModel.swift:110-126` (`hermes config set display.personality <name>`, toast "Active personality set to …"); `scarf/Features/Settings/ViewModels/SettingsViewModel.swift:658`; `PersonalitiesView.swift:63-70` (no caveat).
- Hermes @v2026.9.24: the overlay is resolved by `hermes_cli/personality.py:118-124` (`resolve_ephemeral_system_prompt`). Its only consumers are `hermes_cli/cli_init_mixin.py:249`, `gateway/run_config_loaders.py:99` and `tui_gateway/server.py:2384-2385`. The ACP agent is built at `acp_adapter/session.py:487-530` with no `ephemeral_system_prompt`, and no module under `acp_adapter/`, `run_agent.py` or `agent/` reads `display.personality`. SOUL.md is still loaded (`agent/prompt_builder.py`), so the SOUL editor does work in chat.
- Failure scenario: the user picks "pirate", sees a green "Active personality set to pirate", opens a Scarf chat, and gets the neutral assistant. The setting is real, but it only reaches the CLI, TUI and messaging gateway.
- Suggested fix: add copy saying the personality applies to CLI, TUI and gateway sessions, not Scarf chat. Or, if Scarf wants it in chat, file a Hermes request (ACP has no personality surface).

### S03-F3 · P2 · SOURCE · NEW
- Claim: the chat header's YOLO warning chip only renders when `approvals.mode == "yolo"`. That value is not a valid mode at any tag (Hermes treats it as `manual`). So the chip never appears when approvals really are off (`off`, or YAML `false/no/off`), and it would falsely appear for a stray `yolo` value.
- Scarf: `scarf/Features/Chat/Views/SessionInfoBar.swift:197` (`approvalMode == "yolo"`); fed by `ChatViewModel.swift:694,702` → `ChatTranscriptPane.swift:64`. Scarf's own `HermesApprovalMode.swift:8,130` documents the valid set `["manual","smart","off"]`, and Settings writes `off`, never `yolo`. The chip's help text (`:207`) also says "Toggle via `/yolo`", which S03's own roster notes is not an ACP command, so it goes to the LLM.
- Hermes @v2026.9.24: `tools/approval_context.py:197` `_VALID_MODES = ("manual", "smart", "off")`; `:200-214` maps unknown strings to `manual`; `tools/approval.py:973,1179,1257` bypass approvals when the mode is `off`.
- Failure scenario: the user sets Settings → Agent → Approval Mode → Off. Dangerous commands then run unprompted in chat, and the warning chip that exists for exactly this case never shows.
- Suggested fix: key the chip on the normalized `HermesApprovalMode` being `off` (including the bool arm), and drop the `/yolo` hint.

### S03-F4 · P2 · SOURCE · NEW (twin of TRACKED t-fa0043f6 "deleteSession main actor")
- Claim: renaming a chat from the chat sidebar spawns `hermes sessions rename` synchronously on the main actor. On a remote host that is an SSH exec, which violates charter C10.
- Scarf: `scarf/Features/Chat/ViewModels/ChatViewModel.swift:2711-2726` (`context.runHermes(...)` inline; the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `scarf.xcodeproj/project.pbxproj:606`), called synchronously from `ChatSessionListPane.swift:190`. The twin `SessionsViewModel.performRename` (`:526-537`) hops off the main actor. t-fa0043f6 tracks only `deleteSession`.
- Hermes @v2026.9.24: the argv is correct (`hermes_cli/subcommands/sessions.py:252-255`; exit codes propagate via `hermes_cli/sessions_cmd.py:48-50,726-744` and `hermes_cli/main.py:3616-3618`).
- Failure scenario: renaming a chat on a slow or remote SSH host freezes the whole window for the round trip.
- Suggested fix: use the same `OffPool.run` hop as `SessionsViewModel`, and fold it into t-fa0043f6.

### S03-F5 · P3 · SOURCE · NEW
- Claim: the global `/scarf-*` commands are only bootstrapped into the LOCAL host's (active-profile) `~/.hermes/scarf/slash-commands`. Remote SSH windows and every iOS/ScarfGo session read `globalSlashCommandsDir` on the remote host, which nothing populates, so the menu never shows them there. The wiki says they work "uniformly on Mac + iOS, local + remote SSH".
- Scarf: `scarf/scarfApp.swift:117-125` (`SlashCommandBootstrapService(context: .local)` only); the reader is `ProjectSlashCommandService.swift:192-217`, called from `RichChatViewModel.loadGlobalScopedCommands` and `Scarf iOS/Chat/ChatView.swift:2911,2931,3108`; `wiki/Slash-Commands.md:19`. `/scarf-new` also relies on the `scarf-template-author` skill, which is likewise only installed locally (`scarfApp.swift:100-108`, handed to S10/S11).
- Hermes: n/a (a Scarf-side file store).
- Failure scenario: a remote-host or iPhone user never sees `/scarf-help`, `/scarf-new` and the rest. Nothing breaks; the feature is just missing.
- Suggested fix: bootstrap per connected server on first connect (version-gated, same guard), or correct the wiki.

### S03-F6 · P3 · LIVE · NEW
- Claim: the bundled `/scarf-cron` command tells the agent to run `hermes cron create --name … --schedule … --prompt … --workdir … --deliver "<delivery>"` and `hermes cron list --json`, and offers `print` as a delivery. `--schedule`, `--prompt` and `cron list --json` don't exist, and `print` is not a delivery target.
- Scarf: `scarf/scarf/Resources/BuiltinSlashCommands.bundle/scarf-cron.md` (the "Then run" block, delivery option 3, and the "Context-from" option 5, which is also not an argv at any tag, as t-fa0043f6 notes).
- Hermes @v2026.9.24: `hermes cron create --help` gives `usage: hermes cron create [...] schedule [prompt]` (both positional); `hermes cron list --help` shows only `[--all]`; `--deliver` grammar is "origin, local, telegram, discord, signal, platform:chat_id, or bot-chat[:profile]".
- Failure scenario: `/scarf-cron fetch hn daily` makes the agent run the documented command, which exits 2 with an argparse usage error. A capable model usually retries with the right shape; a weaker one reports failure or loops.
- Suggested fix: rewrite the command to `hermes cron create [--name N] [--deliver T] [--workdir P] "<schedule>" "<prompt>"`, drop `--json` and `print`, and bump `version:` so the bootstrap upgrades installed copies.

Also minor: `SlashCommandBootstrapService.swift:14-16,24-25` says it ships "six" commands including `/scarf-cron`. The bundle does hold six files, but `scarf-cron.md` is missing from the S03 manifest. Informational only.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `available_commands_update` parse | ACP notif | RichChatViewModel.swift:~2195-2219 | acp_adapter/commands.py:76-91 | OK |
| `/help /model /tools /context /reset /compress /version` (sent literally) | ACP prompt | RichChatViewModel.swift:816-887 | commands.py:53-80,97-130 | OK |
| `/compress <focus>` from the compress sheet | ACP prompt | RichChatInputBar.swift:535-542 | commands.py:254-266 | OK |
| `/steer`, `/queue` | ACP prompt | RichChatViewModel.swift:722-735 | commands.py:290-311 | OK |
| `/new` client-side intercept | client | ChatViewModel.swift:1313; iOS ChatView.swift:2066-2078 | (no ACP `new`) | OK (name drop TRACKED t-fa0043f6) |
| `/goal`, `/subgoal`, other unknown names | ACP prompt fall-through | RichChatViewModel.swift:1195-1203 | commands.py:103-104 | TRACKED t-fa0043f6 |
| quick_commands as slash rows | ACP prompt | RichChatViewModel.swift:2224-2241,1003 | commands.py:103-104; server.py:827-837 | FINDING-F1 |
| `quick_commands` read (config.yaml) | config read | HermesQuickCommandsYAML.swift:32-63 | config_defaults.py:1682; cli.py:1233-1245 | OK |
| `hermes config set quick_commands.<n>.type exec` / `.command` | argv | QuickCommandsViewModel.swift:85-91 | cli.py:1235-1247 | OK |
| project slash commands `<project>/.scarf/slash-commands/*.md` | Scarf file | ProjectSlashCommandService.swift:50-145 | n/a (expanded client-side) | OK |
| global `~/.hermes/scarf/slash-commands/*.md` | Scarf file | SlashCommandBootstrapService.swift:50-159; ProjectSlashCommandService.swift:192-217 | n/a | FINDING-F5 |
| `/scarf-cron` body argv | agent prompt | BuiltinSlashCommands.bundle/scarf-cron.md | `hermes cron create --help` (LIVE) | FINDING-F6 |
| `/scarf-new`, `/scarf-dashboard`, `/scarf-widget`, `/scarf-export`, `/scarf-help` bodies | agent prompt | bundle *.md | `cron create --workdir` exists (LIVE) | OK |
| `display.personality` write | argv | PersonalitiesViewModel.swift:118 | personality.py:112-124 (CLI/TUI/gateway only) | FINDING-F2 |
| `agent.personalities` / root `personalities` read | config read | HermesPersonalities.swift:71-133 | personality.py:86-97 | OK |
| built-in personality names (14) and neutral names | constant | HermesPersonalities.swift:37-55 | personality.py:16-33 | OK |
| `SOUL.md` write | file | PersonalitiesViewModel.swift:142-163 | agent/prompt_builder.py:82-93 | OK |
| `session/set_model` (preset / global default) | ACP method | ChatViewModel.swift:1599-1653,1747 | server.py:1015-1051, 315-352 | OK |
| model preflight `model.default`/`model.provider` | config read/write | ChatModelPreflightSheet.swift; ModelPreflight.swift:41-66 | acp_adapter/session.py:472-476 | OK (write plan → S06) |
| `session/set_mode` default/accept_edits/dont_ask | ACP method | ACPClient.swift:19-27; ChatViewModel.swift:1665-1687 | server.py:240-250,1053-1066 | OK |
| `approvals.mode` → YOLO chip | config read | SessionInfoBar.swift:197,207 | tools/approval_context.py:197-214 | FINDING-F3 |
| `hermes sessions rename -- <id> <title>` | argv | ChatViewModel.swift:2711-2733; SessionsViewModel.swift:512-514 | subcommands/sessions.py:252-255; sessions_cmd.py:726-744 | FINDING-F4 (main actor) |
| `hermes sessions delete --yes -- <id>` | argv | ChatViewModel.swift:597-599,2805-2806 | subcommands/sessions.py:101-103; sessions_cmd.py:575-590 | TRACKED t-fa0043f6 (main actor); argv and exit OK |
| session new/resume (`session/new`/`session/load`) | ACP | ChatSessionListPane.swift:49 | — | handed to S01 |
| `session_info_update` title | ACP notif | ChatViewModel.swift:2143-2149 | — | handed to S02 |
| TTS: `tools.tts_tool.text_to_speech_tool(text, output_path=)` in hermes's python, `HERMES_HOME` | script | HermesSpeechService.swift:520-566 | tools/tts_tool.py:419-468 | OK |
| TTS envelope `success/file_path/file_paths/chunk_count/error` | output parse | HermesSpeechService.swift:314-352 | tts_tool.py:374,465-468; tool_error | OK |
| TTS `tts.*` config keys (cache fingerprint only) | config read | HermesSpeechService.swift:201-221 | tts_tool.py:141 | OK |
| Live Voice `tools.voice_live.create_webrtc_session(sdp, history)` | script | VoiceLiveHostExchange.swift:174-242 | tools/voice_live.py:162-186 | OK |
| Live Voice no-key / vendor error shapes | output parse | VoiceLiveHostExchange.swift:217-229,246-283 | voice_live.py:171-172,183-186 | OK |
| `voice.voice_chat_mode` parse | config read | VoiceLiveReadiness.swift:34-41 | voice_live.py:107-111 | OK |
| history message shape `{type:message, role, content:[{type,text}]}` | vendor payload | VoiceLiveText.swift:23-40 | voice_live.py:147-159 (passes it through as `input`) | OK (vendor side UNVERIFIABLE) |
| Chained voice turn: interrupt rewrite / turn note | ACP prompt | VoiceConversationEngine.swift:88-179 | server.py:201-210,644,701; voice_live.py:73,84-90 | OK |

## Not audited / couldn't verify
- Vendor (OpenAI `/v1/live/sessions`) acceptance of the history payload: vendor-side, UNVERIFIABLE.
- `HermesPythonDiscovery`, `HermesConfigSet.argv/judge` and `HermesProfileScope.shellQuotePath` are shared helpers owned by other sections. I assumed they are correct.
- The model preflight write plan (`LocalModelConfigPlan`, `applyModelConfigPlan`) is left to S06. ACP session start and resume and the event stream are left to S01/S02.
- `VoiceLiveSessionSheet` (iOS) and `VoiceLivePresentation`/`VoiceLiveController` (Mac): read for Hermes touchpoints only. They use the same exchange and engine, and I found no separate argv or config.
- iOS ChatView (3988 lines): only its Hermes touchpoints (slash intercept, config set, command loading) were traced. It has no chat-pane rename or delete.
