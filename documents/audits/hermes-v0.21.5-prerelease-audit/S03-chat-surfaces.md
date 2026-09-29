# S03-chat-surfaces — verdict: WORKS-WITH-ISSUES

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Slash menu: Hermes ACP roster (help/model/tools/context/reset/compress/steer/queue/version) + client-side `/new [name]` | WORKS | — (roster matches `acp_adapter/commands.py:53-73`; unknown names fall to LLM `:93-94`, Scarf never offers any) |
| 2 | `/scarf-*` global commands: bundle → `<home>/scarf/slash-commands/` (local at launch, remote on window connect), client-side `{{argument}}` expansion, sent as a normal prompt | DEGRADED | F2 |
| 3 | Project slash commands: create/edit/delete under `<project>/.scarf/slash-commands/`, expand on send (Mac + iOS) | WORKS | — |
| 4 | Personalities: list (14 in-code built-ins + `agent.personalities`), set active (`hermes config set display.personality`), edit SOUL.md | DEGRADED | F1 |
| 5 | Quick commands: list/add via `hermes config set quick_commands.<n>.{type,command}`; intentionally not offered in ACP chat menu | WORKS | — |
| 6 | Model badge (preset switch / "use global default" → `session/set_model`) + preflight sheet (writes model+provider plan, replays start) | WORKS | — |
| 7 | Approval-mode chip → `session/set_mode` default/accept_edits/dont_ask; state read back from `modes.currentModeId` | WORKS | — |
| 8 | Stop button → `session/cancel` notification (Mac + iOS) | WORKS | — |
| 9 | Chat list: new/resume, rename (`hermes sessions rename -- id title`), delete (`hermes sessions delete --yes -- id`, lineage chain) | WORKS | — |
| 10 | iOS deltas: same shared RichChatViewModel menu/expansion, `/new <name>` rename after first turn, `/steer`/`/queue` gating, Stop | WORKS | — |

## Findings

### S03-chat-surfaces-F1 · P1 · SOURCE · NEW
- Claim: The first "Edit" of SOUL.md on the Personalities page opens a **blank** editor, and Save overwrites the real SOUL.md with that buffer.
- Scarf: scarf/scarf/Features/Personalities/Views/PersonalitiesView.swift:56-58 (`viewModel.load(); soulDraft = viewModel.soulMarkdown` — `load()` is a `Task.detached` (PersonalitiesViewModel.swift `load()`), so `soulMarkdown` is still "" when copied); :137-139 (`Button("Edit") { editingSOUL = true }` never re-seeds `soulDraft`); :129-131 Save → `saveSOUL(soulDraft)` → `unguardedWriteText(soulPath, …)` whole-file replace.
- Hermes @v2026.9.24: n/a (Scarf-side; SOUL.md is injected into every session per the page's own caption).
- Failure scenario: open Personalities (read-only view correctly shows existing SOUL.md) → Edit → editor is empty → user types an addition and presses Save / ⌘S → SOUL.md now contains only the new text; previous content lost, "SOUL.md saved" toast. Only after pressing Reload (or Cancel) is `soulDraft` seeded. Local and remote.
- Suggested fix: set `soulDraft = viewModel.soulMarkdown` inside the Edit button action (or `.onChange(of: viewModel.soulMarkdown)`).

### S03-chat-surfaces-F2 · P2 · SOURCE · NEW
- Claim: The bundled `/scarf-widget`, `/scarf-dashboard` and `/scarf-help` prompts advertise widget kinds Scarf does not support (`markdown`, `file_glob`, `command_output`, `sqlite_query`, `recent_messages`) and call the field `kind`; the real catalog is `stat, progress, text, table, chart, list, webview, markdown_file, log_tail, cron_status, image, status_grid, kanban_summary` keyed by `type`.
- Scarf: scarf/scarf/Resources/BuiltinSlashCommands.bundle/scarf-widget.md:4 (argumentHint `"sqlite_query" or "command_output"`), :14-23 (kind list); scarf-dashboard.md:15; scarf-help.md:10 — vs Packages/ScarfCore/Sources/ScarfCore/Models/DashboardWidgetCatalog.swift:45-59 and :106 ("unknown widget type"); the bundled skill agrees with the catalog (scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md:150).
- Hermes: n/a (prompt content sent to the agent).
- Failure scenario: user types `/scarf-widget sqlite_query` as the hint suggests → agent designs a `sqlite_query` widget → `project_update_dashboard` refuses it (unknown type), or without the MCP tools the agent writes it directly and the dashboard shows an unrenderable widget. `/scarf-help` tells users about widgets that do not exist.
- Suggested fix: replace the kind lists with the catalog's types (or just point at SKILL.md § Widget Catalog) and bump each file's `version:` so the bootstrap upgrades installed copies.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| Packages/ScarfCore/.../Models/HermesSlashCommand.swift | no (model) | OK |
| Packages/ScarfCore/.../Models/ProjectSlashCommand.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Parsing/HermesPersonalities.swift | yes (config `agent.personalities`, BUILTIN list) | OK |
| Packages/ScarfCore/.../Parsing/HermesQuickCommandsYAML.swift | yes (config `quick_commands`) | OK |
| Packages/ScarfCore/.../Services/ProjectSlashCommandService.swift | yes (`~/.hermes/scarf/slash-commands`, Scarf-owned) | OK |
| Scarf iOS/Chat/ChatContentFormatter.swift | no | NO-TOUCHPOINT |
| Scarf iOS/Chat/ChatView.swift | yes (ACP prompt/cancel, slash dispatch, `sessions rename`) | OK |
| Scarf iOS/Chat/IOSSlashCommandMenu.swift | no (renders shared list) | OK |
| Scarf iOS/Chat/ProjectPickerSheet.swift | yes (projects.json via transport) | OK |
| Scarf iOS/Chat/ProjectSlashCommandsBrowser.swift | no (reads shared VM) | NO-TOUCHPOINT |
| scarf/Core/Services/ChatNotificationService.swift | no (UserDefaults/UN) | NO-TOUCHPOINT |
| scarf/Core/Services/SlashCommandBootstrapService.swift | yes (`<home>/scarf/slash-commands`, remote bootstrap) | OK |
| scarf/Features/Chat/ChatDensitySettings.swift | no | NO-TOUCHPOINT |
| .../Chat/Views/ChatApprovalModeBadge.swift | yes (`session/set_mode` ids) | OK |
| .../Chat/Views/ChatInspectorPane.swift | no | NO-TOUCHPOINT |
| .../Chat/Views/ChatKanbanOnboardingSheet.swift | yes (`platform_toolsets.acp` += kanban; `acp_adapter/session.py:481-484`) | OK |
| .../Chat/Views/ChatModelBadge.swift | yes (`session/set_model`, config default) | OK |
| .../Chat/Views/ChatModelPreflightSheet.swift | yes (model.default/model.provider write plan) | OK |
| .../Chat/Views/ChatQueueIndicator.swift | no (mirrors `/queue`) | OK |
| .../Chat/Views/ChatSessionListPane.swift | yes (sessions rename/delete) | OK |
| .../Chat/Views/ChatView.swift | yes (sheets, config diagnostics, preflight) | OK |
| .../Chat/Views/CodeBlockView.swift | no | NO-TOUCHPOINT |
| .../Chat/Views/ComposerAttachmentSlots.swift | no | NO-TOUCHPOINT |
| .../Chat/Views/RichChatInputBar.swift | yes (config read off-main for vision hint; Stop) | OK |
| .../Chat/Views/RichChatView.swift | no | NO-TOUCHPOINT |
| .../Chat/Views/SessionInfoBar.swift | yes (profile chip, badges) | OK |
| .../Chat/Views/SlashCommandMenu.swift | no (renders shared list) | OK |
| .../Chat/Views/TerminalRepresentable.swift | no | NO-TOUCHPOINT |
| .../Chat/Views/ToolCallCard.swift | no | NO-TOUCHPOINT |
| .../Chat/Views/WorkingElapsedIndicator.swift | no | NO-TOUCHPOINT |
| .../Personalities/ViewModels/PersonalitiesViewModel.swift | yes (`config set display.personality`, SOUL.md) | OK (bug is in view) |
| .../Personalities/Views/PersonalitiesView.swift | yes (SOUL.md edit) | FINDING-F1 |
| .../Projects/ViewModels/ProjectSlashCommandsViewModel.swift | no (Scarf-owned files) | OK |
| .../Projects/Views/ProjectSlashCommandsView.swift | no | NO-TOUCHPOINT |
| .../QuickCommands/ViewModels/QuickCommandsViewModel.swift | yes (`config set quick_commands.*`) | OK |
| .../QuickCommands/Views/QuickCommandsView.swift | no | NO-TOUCHPOINT |
| BuiltinSlashCommands.bundle/scarf-cron.md | yes (`hermes cron create --name --workdir --deliver schedule prompt`) | OK (LIVE: flags exist) |
| BuiltinSlashCommands.bundle/scarf-dashboard.md | no | FINDING-F2 |
| BuiltinSlashCommands.bundle/scarf-export.md | no | OK |
| BuiltinSlashCommands.bundle/scarf-help.md | no | FINDING-F2 |
| BuiltinSlashCommands.bundle/scarf-new.md | yes (`hermes cron create --workdir`) | OK |
| BuiltinSlashCommands.bundle/scarf-widget.md | no | FINDING-F2 |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes | Status |
|---|---|---|---|---|
| available_commands_update roster | ACP | RichChatViewModel.swift:895-966, 1052-1122 | acp_adapter/commands.py:53-80; server.py:596 (sent after new/load/resume) | OK |
| unknown slash → LLM | ACP | RichChatViewModel (menu never offers non-ACP names) | commands.py:93-94 | OK |
| `/new` client-side | local | ChatViewModel.swift:1593-1611; iOS ChatView.swift:2174-2190 | not in `_COMMANDS` | OK |
| `/steer` `/queue` | ACP | ChatViewModel.swift:1643-1720; iOS ChatView.swift:2223-2270 | commands.py:62-71 | OK |
| session/set_mode default/accept_edits/dont_ask | ACP | ACPClient.swift:19-27, 713-722 | server.py:240-250, 1053-1065 | OK |
| session/set_model | ACP | ChatViewModel.swift:1895-1946; ACPClient.swift:750-761 | server.py:1015-1051 | OK |
| session/cancel | ACP notif | ACPClient.swift:673-696; iOS ChatView.swift:1773-1777 | server.py:636-657 | OK |
| `hermes sessions rename -- id title` | argv | HermesSessionRenameCommand.swift:14 | sessions_cmd.py `_cmd_rename` (exit 1 on failure, main.py:3616-3618) | OK (LIVE) |
| `hermes sessions delete --yes -- id` | argv | SessionsViewModel.swift:613 | sessions_cmd.py `_cmd_delete`, `_not_found` returns 1 | OK (LIVE) |
| `config set display.personality` | argv/config | PersonalitiesViewModel.swift setActive | hermes_cli/personality.py:3,114 | OK |
| BUILTIN_PERSONALITIES 14 names | code mirror | HermesPersonalities.swift:37-52 | hermes_cli/personality.py:19+ | OK |
| `config set quick_commands.<n>.type/command` | argv/config | QuickCommandsViewModel.swift addOrUpdate | cli.py:1219-1222; gateway/config.py:775 | OK |
| `platform_toolsets.acp` kanban | config | ChatKanbanOnboardingSheet / ChatViewModel:3543 | acp_adapter/session.py:481-484; toolsets.py:163 | OK |
| `<home>/scarf/slash-commands/*.md` | Scarf file | SlashCommandBootstrapService.swift:77,167; HermesPathSet.swift:140 | Scarf-owned | OK |
| SOUL.md write | file | PersonalitiesViewModel.saveSOUL | — | FINDING-F1 |
| `hermes cron create` (prompt text) | argv in prompt | scarf-cron.md, scarf-new.md | `hermes cron create --help` | OK (LIVE) |

## Not audited / couldn't verify
- `LocalModelConfigPlan` / `applyModelConfigPlan` internals (model section owns them); `KanbanToolsetEnabler` write path (not in manifest).
- ChatViewModel internals beyond the slash/rename/delete/model/mode paths (S01/S02 own the ACP lifecycle).
- iOS ChatView.swift (4163 lines) read by path for slash/Stop/rename/preflight; UI-only rendering code skimmed, not line-by-line.
- `ProjectSlashCommandService.serialise` quoting round-trip of descriptions containing `:` not traced through `parseNestedYAML` quote handling.
