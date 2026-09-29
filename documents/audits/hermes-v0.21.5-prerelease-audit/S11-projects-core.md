# S11-projects-core — verdict: WORKS-WITH-ISSUES

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Create / add project (registry `~/.hermes/scarf/projects.json`, sidecar, locked write) | WORKS | — |
| 2 | Rename / move to folder / remove (strips AGENTS.md block, no cron removal by design) | WORKS | — |
| 3 | Archive / restore (pauses/resumes attributed cron jobs via `hermes cron pause/resume <id>`, exit-code judged) | WORKS | — |
| 4 | Project chat: cwd = project, AGENTS.md managed block written before session/new; model preset via session/set_model; auto-accept via session/set_mode accept_edits | DEGRADED | S11-F1 |
| 5 | Project Sessions tab (attribution sidecar → HermesDataService read of state.db) | WORKS | — |
| 6 | Cockpit (block preview, `[proj:]`/`[tmpl:]` cron from jobs.json, MEMORY.md block, dashboard, health) | WORKS | — |
| 7 | Project Doctor diagnose/repair (registry, sidecars, orphan scan excluding ~/.hermes and profiles/) | WORKS | — |
| 8 | Dashboards/widgets (Mac + iOS render of `.scarf/dashboard.json`, path resolver) | WORKS | — (no Hermes touchpoint) |
| 9 | Fleet apply (cron create copy with `--paused`/`--workdir`/`--`, pause fallback) | WORKS | — |
| 10 | Registry salvage / damage banner | WORKS | — |
| 11 | Git branch chip (`git -C <path> rev-parse --abbrev-ref HEAD`, 5 s timeout) | WORKS | — |
| 12 | iOS projects list/detail/sessions/site | WORKS | — |

## Findings
### S11-projects-core-F1 · P2 · SOURCE · NEW
- Claim: If a project has its own `CLAUDE.md` (or `.cursorrules`) but no `AGENTS.md`, the first project chat creates an `AGENTS.md` that holds only Scarf's block. From then on Hermes loads that file and skips the project's `CLAUDE.md`/`.cursorrules`, so the agent silently loses the user's project instructions.
- Scarf: Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift:237-244 (the `.absent` arm writes a block-only AGENTS.md); called from scarf/scarf/Core/Services/ProjectAgentContextService.swift:111 on every project chat start (iOS goes through the same writeBlock). The doc comment at ProjectAgentContextService.swift:14-15 gets the order wrong. It also treats the files as alternatives ("first match") without saying that writing AGENTS.md shadows the others.
- Hermes @v2026.9.24: agent/prompt_builder.py:1746-1747. `_load_hermes_md(...) or _load_agents_md(...) or _load_claude_md(...) or _load_cursorrules(...)`: only ONE project context type loads, first found wins (docstring :1736-1737). The `_CONTEXT_FILE_CANDIDATES` priority is at :1653-1664.
- Failure scenario: a user adds an existing repo that has a CLAUDE.md (very common for Claude Code users) as a Scarf project and opens a chat. Scarf writes `<repo>/AGENTS.md` with only the managed block. Hermes injects AGENTS.md and drops CLAUDE.md, so the agent ignores the repo's build/test/style rules. No UI shows this, and it persists for every later session, including CLI sessions in that directory.
- Evidence: prompt_builder.py:1736 "Only ONE project context type loads, first found wins". Not tracked: no hit in TASKS.md, tasks/ or .memory/decisions. The note .memory/architecture/project-scoped-chat-and-agents-md-context.md lists the priority but does not cover the shadowing side effect.
- Suggested fix: when AGENTS.md is absent and CLAUDE.md/.cursorrules exists, seed the new AGENTS.md with a pointer to it (or include its content by reference), or at least warn in the cockpit/Doctor that the block will shadow it.

## File coverage (mandatory — one row per manifest line, none skipped)
| File | Hermes touchpoints? | Status |
|---|---|---|
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/DashboardWidgetCatalog.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDoctorFinding.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectIdentity.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectManifestProjection.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectPortfolio.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectRegistrySalvage.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ScarfProject.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/FleetApplyPlan.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/FleetService.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GitBranchService.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectAutoAcceptEditsStore.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectConfigKeychain.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift | yes | FINDING-F1 |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDoctorService.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectLifecycleService.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectRootPolicy.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RegistryWriteLock.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectSessionsViewModel.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectsViewModel.swift | yes | OK |
| scarf/Scarf iOS/Projects/ProjectDetailView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/ProjectSessionsView_iOS.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/ProjectSiteView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/ProjectsListView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/ChartWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/DashboardWidgetsView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/ListWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/ProgressWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/StatWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/TableWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/TextWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/WebviewWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/Scarf iOS/Projects/Widgets/WidgetHelpers.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/ProjectAgentContextService.swift | yes | FINDING-F1 |
| scarf/scarf/Core/Services/ProjectConfigKeychain.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/ProjectConfigService.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/ProjectManifestStore.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/ViewModels/FleetApplyExecutor.swift | yes | OK |
| scarf/scarf/Features/Projects/ViewModels/FleetApplyViewModel.swift | yes | OK |
| scarf/scarf/Features/Projects/ViewModels/FleetPanelViewModel.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/ViewModels/NewProjectViewModel.swift | yes | OK |
| scarf/scarf/Features/Projects/ViewModels/ProjectCockpitViewModel.swift | yes | OK |
| scarf/scarf/Features/Projects/ViewModels/ProjectDoctorViewModel.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/ViewModels/ProjectHealthCache.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/ViewModels/ProjectMenuProbeCache.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/CockpitFleetPanel.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/FleetApplySheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/MoveToFolderSheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/NewProjectSheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/ProjectChatSettingsSheet.swift | yes | OK |
| scarf/scarf/Features/Projects/Views/ProjectCockpitView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/ProjectDoctorSheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/ProjectKanbanTab.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/ProjectSessionsView.swift | yes | OK |
| scarf/scarf/Features/Projects/Views/ProjectsView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/RegistryDamageBanner.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/RenameProjectSheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/ChartWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/ImageWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/KanbanSummaryWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/ListWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/LogTailWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/MarkdownFileWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/ProgressWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/StatWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/StatusGridWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/TableWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/TextWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/WebviewWidgetView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/WidgetErrorCard.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/WidgetHelpers.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/WidgetPathResolver.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Projects/Views/Widgets/WidgetSignatureBatch.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Navigation/SidebarProjectsWell.swift | no | NO-TOUCHPOINT |

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `<project>/AGENTS.md` managed block auto-loaded from session cwd | file/context | ProjectContextBlock.swift:211-248 | agent/prompt_builder.py:1612-1624, 1690-1709, 1746 | FINDING-F1 (shadowing); loading itself OK |
| ACP `session/new` cwd = project | ACP | (chat section) ProjectSessionsView.swift:75 | acp_adapter/server.py:609-613 | OK |
| ACP `session/set_mode accept_edits` | ACP | ChatViewModel.swift:2149-2167, ProjectAutoAcceptEditsStore.swift | acp_adapter/server.py:242, 1053 | OK |
| ACP `session/set_model` (preset) | ACP | ProjectChatSettingsSheet.swift (binding) | acp_adapter/server.py:1015 | OK |
| `hermes cron pause <id>` / `cron resume <id>` (archive/restore, fleet fallback) | argv | ProjectLifecycleService.swift:176-217; FleetApplyExecutor.swift:417 | hermes_cli/subcommands/cron.py:149-154; cron.py:785-794, 812-832 (non-zero on failure; main.py:1925 forward_return) | OK |
| `hermes cron create --name --deliver --failure-deliver --repeat --paused --skill --workdir -- <schedule> <prompt>` | argv | FleetApplyPlan.swift:491-526 | hermes_cli/subcommands/cron.py:23-89; cron.py:698-722 | OK |
| `~/.hermes/cron/jobs.json` read (attribution, paused state) | file | ProjectLifecycleService.swift:224-234; ProjectCockpitViewModel.swift:303; ProjectDoctorService.swift:1149 | cron/jobs.py (is_job_runnable :521-524 per code cite) | OK |
| `~/.hermes/memories/MEMORY.md` block read | file | ProjectCockpitViewModel.swift:310-316 | tools/memory_tool_store.py | OK |
| `~/.hermes/scarf/projects.json` + flock | file (Scarf-owned) | ProjectDashboardService.swift:263; RegistryWriteLock.swift | n/a (Scarf-owned) | OK |
| state.db sessions read (attributed ids) | SQL (via HermesDataService) | ProjectSessionsViewModel.swift:108-124 | hermes_state.py | OK (the query itself is owned by the sessions section) |
| `~/.hermes/scarf/model_presets.json` | file (Scarf-owned) | FleetApplyPlan.swift:180 | n/a | OK |
| `git rev-parse --abbrev-ref HEAD` | argv (git) | GitBranchService.swift:40-47 | n/a | OK |
| `.env` / `config.yaml` timezone read for cron note | file | ProjectCockpitViewModel.swift:327-331 | — | OK |

## Not audited / couldn't verify
- The HermesDataService SQL for attributed sessions, ChatViewModel's ACP session boot, and HermesFileService cron decoding belong to other sections. Here they were traced only as far as the call boundary.
- Widget views (Mac + iOS) are pure rendering of Scarf-owned `.scarf/dashboard.json`, with no Hermes contract. I opened them but did not trace them line by line.
- Auto-accept is keyed by project path only, not by server (ProjectAutoAcceptEditsStore). A local and a remote project with an identical path would share the setting. This is a rare edge case, so it is not reported.
