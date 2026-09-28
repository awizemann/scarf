# S03-chat-surfaces — verdict: WORKS-WITH-ISSUES

Reference: Hermes `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (0.21.5). Scarf paths relative to `scarf/`.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Slash menu: ACP-advertised + static fallback roster (`help model tools context reset compress steer queue version`) sent literally over ACP | WORKS | — (roster matches `acp_adapter/commands.py:53-75` exactly; unknown names fall through to the LLM `:103-104`, which Scarf already notices) |
| 2 | Client-side commands: `/new`, project-scoped and global `/scarf-*` commands expanded to a prompt | WORKS (cosmetic gap) | S03-F5 |
| 3 | `/steer` / `/queue` mid-turn and idle | WORKS | — (`commands.py:290-310`, `server.py:701-723`, `:824-845`) |
| 4 | Built-in `/scarf-*` bundle install (local at launch, remote on first window) | WORKS | — (Scarf-owned dir `<home>/scarf/slash-commands`; Hermes never reads it, expansion is client-side) |
| 5 | Personalities: pick active (`display.personality`), SOUL.md edit, list built-ins + `agent.personalities` | WORKS | — (Scarf correctly says the pick applies to CLI/TUI/gateway only: ACP never calls `resolve_ephemeral_system_prompt`) |
| 6 | Quick commands: add/edit via `hermes config set quick_commands.<name>.{type,command}` | DEGRADED | S03-F4 |
| 7 | Model badge / mid-chat `session/set_model` switch / "Use global default" | DEGRADED | S03-F2 |
| 8 | Model preflight sheet (no model/provider in config) → write + replay start | WORKS | handoff S06 for the write plan |
| 9 | Approval-mode badge → `session/set_mode` | WORKS | — (ids `default/accept_edits/dont_ask` match `server.py:240-250`; mode is not persisted across ACP processes so "Default" on resume is correct) |
| 10 | Session list pane: new / resume / rename / delete | WORKS | — (`sessions rename -- id title`, `sessions delete --yes -- id`; `_not_found` returns 1 and `main.py:3616-3618` exits with it) |
| 11 | Hermes Voice message playback (`tools.tts_tool.text_to_speech_tool` via host script) | BROKEN on stock install.sh layout (silently falls back to system voice) | S03-F1 |
| 12 | Live Voice (GPT-Live) SDP exchange via `tools.voice_live.create_webrtc_session` on host | BROKEN on stock install.sh layout | S03-F1 |
| 13 | Chained voice turn (context note over ACP) | WORKS (TTS leg degrades per F1) | — (turn notes byte-match `tools/voice_live.py:73-90`) |
| 14 | `/goal` → Kanban toolset onboarding sheet → "Enable kanban tools" | BROKEN (enables the wrong platform) | S03-F3 |
| 15 | iOS ChatView deltas (slash dispatch, `/new`, idle `/queue`, preflight `config set`) | WORKS | — (same RichChatViewModel helpers; preflight uses `HermesConfigSet` argv + judge) |

## Findings

### S03-F1 · P1 · SOURCE (+ discovery fragment reproduced) · NEW
- Claim: Scarf's shared host-Python discovery cannot find Hermes's interpreter when `hermes` is the launcher that the v0.21.5 `install.sh` writes, so Hermes Voice (TTS playback) and Live Voice (GPT-Live) both fail on a default install.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Services/HermesPythonDiscovery.swift:23-58` (used by `HermesSpeechService.swift:512` and `VoiceLiveHostExchange.swift:177`); binary choice `Packages/ScarfCore/Sources/ScarfCore/Models/HermesPathSet.swift:151,209-218` (local default is `~/.local/bin/hermes`).
- Hermes @v2026.9.24: `scripts/install.sh:2156-2175` deletes any old symlink and writes `~/.local/bin/hermes` as a bash shim: `#!/usr/bin/env bash` … `exec "$HERMES_BIN" "$HERMES_ENTRYPOINT" "$@"`, with `HERMES_BIN="$INSTALL_DIR/venv/bin/python"` (`:2122-2123`). The FHS layout (`/usr/local/bin/hermes`) gets the same shim.
- Failure scenario: fresh install via install.sh (local or SSH host). The discovery reads `~/.local/bin/hermes`. `readlink -f` returns the same file because it is not a symlink. The shebang interpreter is `/usr/bin/env`, which is not `python*`. The fallback then looks for `python` or `python3` in `~/.local/bin`, which is normally absent. If `uv python install` put one there, it is the wrong interpreter and `import tools…` fails. As a result:
  - Hermes Voice logs `synthesisFailed` and silently speaks with the macOS system voice (`scarf/Core/Services/MessageSpeechService.swift:166-175`). The user who picked "Hermes Voice" never gets it and is never told.
  - Live Voice (GPT-Live mode) fails with "Couldn't find Hermes's Python on the server" (`VoiceLiveHostExchange.swift:273-276`).
  - The chained engine's TTS falls back to the system voice.
  pipx/pip installs still work, because their console-script shebang is a Python path.
- Evidence: I ran the discovery fragment verbatim against a file with the installer's shim content: `py=[]`. Against this machine's real `~/.local/bin/hermes` (a `#!/bin/sh` exec wrapper): `py=[]`.
- Suggested fix: when the shebang isn't Python, parse the shim's `exec "<…/python>"` line. Alternatively, try `$HERMES_HOME/hermes-agent/venv/bin/python` / `$INSTALL_DIR` before giving up.

### S03-F2 · P2 · SOURCE · NEW
- Claim: the chat header's model badge (and the vision heads-up that shares its source) does not reflect the model the ACP session actually runs.
- Scarf: `scarf/Features/Chat/ViewModels/ChatViewModel.swift:311`. `currentModelPreset` is written in only 3 places: `:1831`/`:1876` (the badge's own switch) and `:1944`, which runs only for project chats (`:2228-2233`). It is never reset when a non-project session is created or resumed, and it is never updated from a typed `/model`. Consumers: `scarf/Features/Chat/Views/ChatModelBadge.swift:54-66` and `scarf/Features/Chat/Views/RichChatInputBar.swift:331-344`.
- Hermes @v2026.9.24:
  - `set_session_model` persists the switch (`acp_adapter/server.py:348-351` `save_session`), and session restore reloads it (`acp_adapter/session.py:431-450`, `row.get("model")`).
  - `/model <name>` over ACP switches the model and only returns text (`acp_adapter/commands.py:142-151`).
  - `session/new` and `session/load` return the true `models.current_model_id` (`server.py:600`, `:670`), which Scarf ignores.
- Failure scenarios:
  - (a) Switch chat A to preset "Opus" via the badge, then start a new non-project chat B in the same window. B runs the config.yaml default while the badge still says "Opus" (with a checkmark).
  - (b) Resume a chat that was switched earlier. It runs the switched model, but the badge says "Default — Running on config.yaml default".
  - (c) Pick `/model gpt-5` from the slash menu. The model changes and the badge is unchanged.
- Suggested fix: reset `currentModelPreset` at every session boundary and seed it from the `models.current_model_id` in the new/load response (match it to a preset, else show the raw id).

### S03-F3 · P2 · SOURCE · NEW
- Claim: the chat's Kanban onboarding checks and enables `platform_toolsets.cli`, but Scarf chats run on the `acp` platform. Enabling kanban there never gives the chat agent kanban tools, yet Scarf toasts success.
- Scarf:
  - `scarf/Features/Chat/ViewModels/ChatViewModel.swift:3383-3422` (trigger + `enableKanbanToolset`).
  - `Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetDetector.swift:70-97` ("default `cli`, which is the platform Hermes uses for ACP chats").
  - `Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetEnabler.swift:66-76`.
  - Sheet copy: `scarf/Features/Chat/Views/ChatKanbanOnboardingSheet.swift:65`.
- Hermes @v2026.9.24:
  - ACP resolves its toolsets with `_get_platform_tools(config, "acp")`, i.e. `platform_toolsets.acp`, else the `hermes-acp` composite (`acp_adapter/session.py:480-486`).
  - `hermes-acp` excludes kanban (`toolsets.py:70,202-206`), and `kanban` is default-off (`hermes_cli/tools_config.py:97`).
  - Kanban tool gating explicitly refuses to "borrow another platform's opt-in during schema assembly" (`tools/kanban_tools.py:40-50`).
  - The only cross-platform path is the legacy top-level `toolsets: [kanban]` (`:46`, `tools_config.py:619-620`). `acp` is not a `tools enable --platform` choice (`hermes_cli/tools_config_mcp.py:223-252`; `platforms.py` has no `acp`).
- Failure scenario: the user types `/goal ship the release`, the sheet appears, and they click "Enable kanban tools". Scarf writes `kanban` into `platform_toolsets.cli` and says "Kanban tools enabled. Start a new chat to pick this up." Every new Scarf chat still has zero kanban tools. The detector is also wrong in the other direction: a host with `platform_toolsets.acp: [..., kanban]` still gets the sheet.
- Suggested fix: detect and write `platform_toolsets.acp` (a list, seeded from `hermes-acp`'s configurable subset), or the top-level `toolsets` opt-in, and fix the sheet copy.

### S03-F4 · P3 · SOURCE · NEW
- Claim: quick commands saved with an uppercase letter in the name can never be run, because every Hermes surface lowercases the typed command before looking it up.
- Scarf: `scarf/Features/QuickCommands/ViewModels/QuickCommandsViewModel.swift:65-91` (the name is used verbatim apart from space/dot sanitising via `ConfigDottedKeySegment.escaped`, `Packages/ScarfCore/Sources/ScarfCore/Services/ConfigDottedKeySegment.swift:49-56`); `scarf/Features/QuickCommands/Views/QuickCommandsView.swift:171`.
- Hermes @v2026.9.24:
  - CLI looks up `bare = base_cmd.lstrip("/")` from `cmd_lower` (`cli.py:1213-1222`).
  - Gateway: `get_command()` returns `.lower()` (`gateway/platforms/event.py:105`), used at `gateway/run_inbound.py:812,1033`.
  - Keys are stored case-preserved (`hermes_cli/config.py:3479+`, no lowercasing).
- Failure scenario: the user adds "Deploy" → `quick_commands.Deploy.*` is written → typing `/Deploy` or `/deploy` in the CLI or Telegram never matches. The text falls through to skills/prefix expansion or the model. Scarf shows "Saved /Deploy".
- Suggested fix: lowercase the name on save (or reject uppercase) in the editor.

### S03-F5 · P3 · SOURCE · NEW
- Claim: the slash menu advertises `/new [<name>]`, but both Mac and iOS drop the name.
- Scarf: hint at `Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift:887-896` (`hasNewWithSessionName`); name discarded at `scarf/Features/Chat/ViewModels/ChatViewModel.swift:1536-1546` and `scarf/Scarf iOS/Chat/ChatView.swift:2077-2083` (`_ = name`).
- Hermes @v2026.9.24: `/new` is not an ACP command (`acp_adapter/commands.py:53-75`), so this is purely client-side.
- Failure scenario: `/new Release notes` opens an untitled session, and nothing tells the user the name was ignored.
- Suggested fix: after `session/new`, apply the name via the existing rename path (`hermes sessions rename`), or drop the argument hint.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `available_commands_update` → menu | ACP notif | `Models/ACPMessages.swift:571`, `RichChatViewModel.swift:2540` | `acp_adapter/commands.py:78-95` | OK |
| Static fallback roster help/model/tools/context/reset/compress/version | ACP prompt text | `RichChatViewModel.swift:887-957` | `acp_adapter/commands.py:53-75` | OK |
| `/steer`, `/queue` (+ idle handling) | ACP prompt text | `RichChatViewModel.swift:790-806`; `ChatViewModel.swift:1585-1690` | `commands.py:290-310`; `server.py:701-745,824-845` | OK |
| `/new` client intercept | client | `ChatViewModel.swift:1536`; iOS `ChatView.swift:2072` | n/a | FINDING-S03-F5 |
| Project/global slash expansion `<!-- scarf-slash:x -->` | ACP prompt text | `ProjectSlashCommandService.swift:157-164` | `commands.py:97-104` (not a slash → model) | OK |
| `<project>/.scarf/slash-commands/*.md` read/write/delete | Scarf file | `ProjectSlashCommandService.swift:50-145` | n/a (Scarf-owned) | OK |
| `<home>/scarf/slash-commands/*.md` bootstrap | Scarf file | `SlashCommandBootstrapService.swift:53-226`; `scarfApp.swift:124,521` | n/a (Scarf-owned) | OK |
| `hermes config set -- display.personality <name>` | argv/config key | `PersonalitiesViewModel.swift:118` | `hermes_cli/personality.py:112-124` | OK |
| `agent.personalities.*` / `personalities.*` read | config key | `HermesPersonalities.swift:71-133` | `personality.py:86-97` | OK |
| `BUILTIN_PERSONALITIES` names | constant | `HermesPersonalities.swift:37-52` | `personality.py:19-34` | OK |
| `SOUL.md` write | ~/.hermes file | `PersonalitiesViewModel.swift:144-166` | (Hermes reads SOUL.md, not re-verified) | OK |
| `hermes config set -- quick_commands.<n>.type exec` / `.command` | argv/config key | `QuickCommandsViewModel.swift:85-91` | `cli.py:1213-1260`; `gateway/run_inbound.py:812,1033`; `tui_gateway/methods_tools.py:550` | FINDING-S03-F4 |
| `quick_commands` read (type/command; `alias`/`target` shown as type only) | config key | `HermesQuickCommandsYAML.swift:32-58` | `cli.py:1233-1250` | OK |
| `session/set_model` `<provider>:<model>` | ACP method | `ACPClient.swift:740-767`; `ChatViewModel.swift:1825-1880` | `server.py:315-352,1015-1051` | OK |
| Badge's source of truth (`currentModelPreset`) | UI state | `ChatViewModel.swift:311,1831,1944` | `server.py:600,670`; `session.py:431-450` | FINDING-S03-F2 |
| `session/set_mode` default/accept_edits/dont_ask | ACP method | `ACPClient.swift:19-27`; `ChatViewModel.swift:1891-1914` | `server.py:238-252,1053-1065` | OK |
| Model preflight: `model.default` / `model.provider` check | config key | `ModelPreflight.swift:40-66`; `ChatViewModel.swift:2066-2080` | `acp_adapter/session.py:473-493` | OK |
| Preflight write (Mac write plan / iOS `config set`) | argv | `ChatViewModel.swift:2783-2855`; iOS `ChatView.swift:1771-1885` | `hermes config set --help` (LIVE) | OK (write plan → S06) |
| `hermes sessions rename -- <id> <title>` | argv | `SessionsViewModel.swift:572`; `ChatViewModel.swift:3019-3066` | `subcommands/sessions.py:252-255`; `sessions_cmd.py` `_cmd_rename` | OK |
| `hermes sessions delete --yes -- <id>` | argv | `SessionsViewModel.swift:582`; `ChatViewModel.swift:3147-3210` | `subcommands/sessions.py:101-103`; `_cmd_delete`; `main.py:3616` | OK |
| Resume / new session (session/load, session/new) | ACP | `ChatViewModel.swift:1064,2200-2220` | — | handoff S01 |
| TTS script `from tools.tts_tool import text_to_speech_tool(text, output_path=)` + envelope | host script | `HermesSpeechService.swift:236-313,505-556` | `tools/tts_tool.py:419-479,281-320` | OK (envelope/path rules match) |
| Host Python discovery (shebang / sibling python) | host script | `HermesPythonDiscovery.swift:23-58` | `scripts/install.sh:2122-2175` | FINDING-S03-F1 |
| `HERMES_HOME` export for profile | env | `HermesSpeechService.swift:525`; `VoiceLiveHostExchange.swift:178` | `hermes_constants.get_hermes_home` | OK |
| `tools.voice_live.create_webrtc_session(sdp, history)` | host script | `VoiceLiveHostExchange.swift:186-236` | `tools/voice_live.py:162-186` | OK |
| `voice.voice_chat_mode` parse | config key | `VoiceLiveReadiness.swift:34-41` | `tools/voice_live.py:107-111` | OK |
| `VOICE_LIVE_TURN_NOTE` as ACP embedded resource | ACP content | `VoiceLiveTurnNote.swift:17-45` | `tools/voice_live.py:73-90`; `acp_adapter/content.py:112-124` | OK |
| GPT-Live WebRTC/data-channel events | vendor protocol | `GPTLiveEngine.swift` | (OpenAI, not Hermes) | UNVERIFIABLE |
| `platform_toolsets.cli` kanban detect/enable | config key | `KanbanToolsetDetector.swift:76-97`; `KanbanToolsetEnabler.swift:76` | `acp_adapter/session.py:480-486`; `tools/kanban_tools.py:40-50` | FINDING-S03-F3 |
| Terminal-mode `/voice on|off` | CLI slash | `ChatViewModel.swift:3435-3442` | `hermes_cli/commands.py:202-204` | OK |
| `/scarf-cron` instructs `hermes cron create --name --workdir --deliver schedule prompt` | argv in prompt | `BuiltinSlashCommands.bundle/scarf-cron.md:21-27` | `hermes cron create --help` (LIVE) | OK |
| `ChatDensitySettings`, `ActivityBubble`, `RichMessageBubble`, `RichChatMessageList`, `RichChatView`, `ChatInspectorPane`, `ChatTranscriptPane`, `VoiceLivePresentation`, `VoiceLiveComposerButton`, `VoiceLiveText` | UI only | — | — | OK (no direct Hermes touchpoint; the speaker button routes through F1's service) |
| `SessionInfoBar` YOLO chip (`approvals.mode`), Kanban chip | config/CLI | `SessionInfoBar.swift:205-260` | — | handoff S05 / S13 |

## Not audited / couldn't verify
- S01/S02 handoffs: the ACP transport, `session/load` replay, and mid-turn prompts, which at this tag may be *redirected* into the active turn (`server.py:725-745`). The voice turn host relies on the "queued" behaviour, so S02 should confirm the host still holds submissions until `sendPrompt` returns.
- Mac preflight write plan (`LocalModelConfigPlan`/`applyModelConfigPlan`) is S06's. The iOS preflight runs `hermes` unquoted and root-pin-only inside `sh -c` (`Scarf iOS/Chat/ChatView.swift:1872-1875`). I did not check that named-profile scoping reaches that `sh -c` (S13/S15).
- A local window's `/scarf-*` commands live under the active profile's home. They are installed only at launch, so after switching the local active profile they appear only on the next launch. This is an edge case, not reported.
- Live runtime behaviour: no chat/voice/TTS was started (read-only). F1 was shown by running the discovery fragment against a file with the installer's shim content and against the machine's current launcher.
