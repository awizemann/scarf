# S13a-kanban — verdict: WORKS-WITH-ISSUES

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Open board: `kanban list --json [--tenant/--session/--assignee/--sort/--archived]` + `stats --json` + fleet `diagnostics --json` | WORKS | — |
| 2 | Task detail: `show <id> --json`, `runs <id> --json`, `log [--tail=N] <id>` (Mac inspector + iOS sheet) | WORKS | — |
| 3 | Create task: `create [--flag=value…] --json -- <title>`, then best-effort dispatch | WORKS | — (unconfirmed dispatch TRACKED t-ad965a68) |
| 4 | Drag moves: unblock / block / complete (--result=) / reopen-review / archive / archive --rm / promote / schedule | WORKS | — |
| 5 | Drag Up Next/Blocked/Scheduled → Running (`dispatch --json`) | DEGRADED | S13a-kanban-F1 |
| 6 | Assign / reassign (`assign <id> <profile|none>`), comment (`comment [--author=] -- <id> <text>`) | WORKS | — |
| 7 | Kanban tools onboarding for chat (detect/enable `platform_toolsets.acp` on 0.21.5) | WORKS | — |
| 8 | Project-scoped board / tenant mint (manifest `kanbanTenant`) + iOS read-only board | WORKS | — |

## Findings
### S13a-kanban-F1 · P2 · SOURCE · NEW
- Claim: A drag into Running whose `dispatch` pass exits 0 without spawning that task leaves the card displayed in Running indefinitely, while Hermes still has it in ready/todo.
- Scarf: scarf/scarf/Features/Kanban/ViewModels/KanbanBoardViewModel.swift (attemptMove: `optimisticOverrides[taskId] = optimisticStatus(for: destination)` then the steps run; mergePolledTasks: an override is dropped only when the polled row's column EQUALS the override's column or the row leaves the polled set; applyStep `.dispatch` discards the summary `_ = try await service.dispatch(...)`). KanbanService.swift:493-512 decodes only `promoted`/`failed`/`per_task` — keys `failed`/`per_task` do not exist in Hermes output, `spawned`/`skipped_*` are ignored.
- Hermes @v2026.9.24: hermes_cli/kanban_ops.py:60-112 (`_cmd_dispatch` always returns 0; JSON has `spawned`, `skipped_unassigned`, `skipped_nonspawnable`, `skipped_per_profile_capped`, `respawn_guarded`…); kanban_ops.py:73-75 max_in_progress has a memory-derived default; kanban_db_dispatch.py:92-117 DispatchResult.
- Failure scenario: user drags an assigned card to Running while the per-profile/global in-progress cap is reached, or the card is `todo` (Up Next also holds todo — open parents), → dispatch exits 0, spawns nothing for it; refresh polls `ready`/`todo` (column Up Next ≠ override Running) so the override is KEPT; the card stays in Running with no worker, until Hermes eventually runs it or the view is recreated. No error/notice is shown.
- Evidence: override removal condition `if columnFromStatus(optStatus) == columnFromStatus(row.status) { remove }` — no other clearing path on success.
- Suggested fix: after the step loop succeeds, clear the override (let the poll be truth) and/or check `spawned` for the task id and show a notice ("not started: at capacity / not ready").

## File coverage (mandatory — one row per manifest line, none skipped)
| File | Hermes touchpoints? | Status |
|---|---|---|
| Packages/ScarfCore/.../Models/HermesKanbanAssignee.swift | yes (assignees JSON name/on_disk/counts) | OK |
| Packages/ScarfCore/.../Models/HermesKanbanComment.swift | yes (show.comments author/body/created_at) | OK |
| Packages/ScarfCore/.../Models/HermesKanbanDiagnostic.swift | yes (diagnostics JSON incl. null task_id home row) | OK |
| Packages/ScarfCore/.../Models/HermesKanbanEvent.swift | yes (show.events kind/payload/created_at/run_id) | OK |
| Packages/ScarfCore/.../Models/HermesKanbanRun.swift | yes (_RUNS_RUN_FIELDS/_SHOW_RUN_FIELDS) | OK |
| Packages/ScarfCore/.../Models/HermesKanbanStats.swift | yes (board_stats by_status/by_assignee/oldest_ready_age_seconds) | OK |
| Packages/ScarfCore/.../Models/HermesKanbanTask.swift | yes (_TASK_DICT_FIELDS) | OK |
| Packages/ScarfCore/.../Models/HermesKanbanTaskDetail.swift | yes (show --json envelope) | OK |
| Packages/ScarfCore/.../Models/KanbanChatBadgeState.swift | no (pure state; counts from list --session) | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Models/KanbanCreateRequest.swift | yes (create argv) | OK |
| Packages/ScarfCore/.../Models/KanbanError.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Models/KanbanFilters.swift | yes (list argv; KanbanDispatchSummary) | FINDING-F1 (dispatch summary keys) |
| Packages/ScarfCore/.../Services/KanbanService.swift | yes (all verbs) | OK / FINDING-F1 |
| Packages/ScarfCore/.../Services/KanbanTenantReader.swift | no (Scarf manifest) | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Services/KanbanToolsetDetector.swift | yes (config.yaml platform_toolsets.acp / toolsets) | OK |
| Packages/ScarfCore/.../Services/KanbanToolsetEnabler.swift | yes (config.yaml write) | OK |
| Scarf iOS/Kanban/DiagnosticDetailSheet.swift | no (renders model) | NO-TOUCHPOINT |
| Scarf iOS/Kanban/ScarfGoKanbanDetailSheet.swift | yes (show/runs/diagnostics --task) | OK |
| Scarf iOS/Kanban/ScarfGoKanbanView.swift | yes (list --tenant, stats) | OK |
| scarf/scarf/Core/Services/KanbanTenantResolver.swift | no (Scarf manifest/projects.json) | NO-TOUCHPOINT |
| scarf/scarf/Features/Kanban/ViewModels/KanbanBoardViewModel.swift | yes (via service) | FINDING-F1 |
| scarf/scarf/Features/Kanban/ViewModels/KanbanPollBackoff.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Kanban/ViewModels/KanbanTaskDetailViewModel.swift | yes (show/runs/log/comment) | OK |
| scarf/scarf/Features/Kanban/ViewModels/KanbanViewModel.swift | yes (list) | OK |
| scarf/scarf/Features/Kanban/Views/KanbanBlockReasonSheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Kanban/Views/KanbanBoardView.swift | yes (toolset detect/enable, dispatch confirm) | OK |
| scarf/scarf/Features/Kanban/Views/KanbanCardView.swift | no (renders model) | NO-TOUCHPOINT |
| scarf/scarf/Features/Kanban/Views/KanbanColumnView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Kanban/Views/KanbanCompleteResultSheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Kanban/Views/KanbanCreateSheet.swift | yes (builds KanbanCreateRequest) | OK |
| scarf/scarf/Features/Kanban/Views/KanbanInspectorPane.swift | yes (via VM) | OK |
| scarf/scarf/Features/Kanban/Views/KanbanListView.swift | yes (via KanbanViewModel) | OK |
| scarf/scarf/Features/Kanban/Views/KanbanView.swift | no | NO-TOUCHPOINT |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes @v2026.9.24 | Status |
|---|---|---|---|---|
| `kanban [--board=] list --json …` | argv/JSON | KanbanService.swift:135-160, KanbanFilters.swift:52-72 | kanban.py:418-446, kanban_output.py:18-24 | OK (LIVE --help) |
| `kanban show <id> --json` | argv/JSON | KanbanService.swift:210-222 | kanban.py:473-500 | OK |
| `kanban runs <id> --json` | argv/JSON | KanbanService.swift:224-241 | kanban.py:1217-1228 | OK |
| `kanban stats --json` | argv/JSON | KanbanService.swift:243-255 | kanban.py:1136-1140, kanban_db.py:4198-4215 | OK |
| `kanban log [--tail=N] <id>` | argv | KanbanService.swift:262-283 | kanban.py:1207-1214 (missing → stderr "(no log…)", rc 1 → folded to "") | OK |
| `kanban assignees --json` | argv/JSON | KanbanService.swift:301-314 | kanban.py:319-331, kanban_db.py:4381-4386 | OK |
| `kanban diagnostics --json [--task=]` | argv/JSON | KanbanService.swift:170-208 | kanban.py:628-703 | OK |
| `kanban create … --json -- title` | argv/JSON | KanbanService.swift:318-339, KanbanCreateRequest.swift:95-139 | kanban.py:334-391 | OK (LIVE) |
| `kanban assign <id> <profile|none>` | argv/exit | KanbanService.swift:341-346 | kanban.py:572-577 (_ok_or_err) | OK |
| `kanban comment [--author=] -- id text` | argv/exit | KanbanService.swift:348-360 | kanban.py:749-761, kanban_db.py:1763-1772 (raises on unknown id) | OK |
| `kanban complete [--result=…] -- ids` | argv/exit | KanbanService.swift:365-410 | kanban.py:894-943, kanban_output.py:61-71 | OK |
| `kanban block -- id reason` | argv/exit | KanbanService.swift:412-425 | kanban.py:981-1005 | OK |
| `kanban unblock -- ids` | argv/exit | KanbanService.swift:427-438 | kanban.py:1019-1030 | OK |
| `kanban reopen-review [--reason=] -- ids` | argv/exit | KanbanService.swift:456-477 | kanban.py:1069-1086 | OK |
| `kanban archive -- ids` / `archive --rm ids` | argv/exit | KanbanService.swift:481-593 | kanban.py:1121-1133 | OK |
| `kanban promote` / `schedule` | argv/exit | KanbanService.swift:72-127, 538-565 | kanban.py:1008-1016, 1090-1118 | OK |
| `kanban dispatch --json` | argv/JSON | KanbanService.swift:493-512, KanbanFilters.swift:80-130 | kanban_ops.py:60-112 | FINDING-F1 |
| config.yaml `platform_toolsets.acp` / top-level `toolsets` (read) | config | KanbanToolsetDetector.swift (classifyACP) | tools_config.py:575-620, acp_adapter/session.py:484 | OK |
| config.yaml `platform_toolsets.acp: [hermes-acp, kanban]` (write) | config | KanbanToolsetEnabler.swift (planEnableACP) | tools_config.py:506-521, toolsets.py:202-206 (hermes-acp excludes kanban) | OK |
| `<project>/.scarf/manifest.json` kanbanTenant | Scarf file | KanbanTenantReader.swift, KanbanTenantResolver.swift | n/a | OK |

## Not audited / couldn't verify
- Did not trace the `hasACPPlatformToolsets` capability floor value (out of scope: version floors).
- `agent.disabled_toolsets: [kanban]` or composite names in `platform_toolsets.acp` would make the detector say "enabled" while Hermes disables it — unusual config, not reported.
- Unconfirmed board-wide dispatch from create/reassign is TRACKED (t-ad965a68).
- "Goals": Scarf never sends `--goal`/`--goal-max-turns` (fields not on the wire per memory note); no defect.
