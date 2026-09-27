# S11-projects-core — verdict: WORKS-WITH-ISSUES

Hermes reference: `~/.hermes/hermes-agent-v0215` @ `v2026.9.24` (0.21.5, `hermes --version` confirmed). Prior audits read: `documents/reports/2026-09-03-projects-full-surface-audit.md`, `…-stability-investigation.md`, `2026-09-04-projects-post-remediation-audit.md`, `…-p8-remediation-closeout.md`. Those were integrity/security/perf audits, and this report does not repeat any of their items. It covers only Scarf↔Hermes behaviour.

Summary: the main path works on 0.21.5. A project chat reaches Hermes through the ACP `session/new`/`session/load` `cwd`, which Hermes pins per turn, and the spawned `hermes acp` also gets the project as its process cwd. Hermes loads `<project>/AGENTS.md` from that cwd. Scarf's managed block passes Hermes's context-file injection scanner. The model preset goes through `session/set_model`, and auto-accept edits go through `session/set_mode accept_edits`. Fleet `cron create` argv, and the archive `cron pause/resume`, match the tagged argparse, and their exit codes are honest. I found no P0 or P1 defects. There are five findings: three P2 and two P3.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Create project (scaffold, registry write, root policy, skill bootstrap, auto-prompt) | WORKS | — (registry/root policy are Scarf-only; skill install is S10) |
| 2 | Open project cockpit (record, AGENTS.md, manifest, cron, MEMORY.md block, dashboard, doctor) | WORKS | F5 (cron list is prefix-only) |
| 3 | Start project chat, Mac (block write → spawn with cwd → session/new cwd → set_model → set_mode → attribution) | WORKS | TRACKED: `.hermes.md`/`HERMES.md`/`AGENTS.override.md` shadow the block |
| 4 | Resume project chat (Mac + iOS) | DEGRADED | F4 (refreshed block is not seen by a resumed session) |
| 5 | Start/resume project chat, iOS | DEGRADED | F3 (bound model preset never applied on iOS) |
| 6 | Project sessions list (attribution sidecar ∩ state.db list) | WORKS | — |
| 7 | Project doctor checks (registry/record/sidecars, cron `[proj:]`+workdir, orphan scan) | WORKS | — |
| 8 | Hermes "shadow" detection (Dashboard banner + fix command) | BROKEN (false premise) | F1 |
| 9 | Dashboards/widgets reading Hermes data | WORKS (my part) | cron_status → S08, kanban_summary → S13 |
| 10 | Fleet apply across servers (preset bind, board, `hermes cron create` copy) | WORKS | — |
| 11 | Rename / remove / archive / unarchive | DEGRADED | F2 (unarchive re-arms jobs that were paused before archiving) |
| 12 | Registry salvage / damage banner / write lock | WORKS | — (Scarf-only files) |
| 13 | iOS project list / detail / picker | WORKS | F3 (detail shows a preset the chat does not use) |

## Findings

### S11-projects-core-F1 · P2 · SOURCE · NEW
- Claim: the Dashboard "Project-local Hermes home shadowing global setup" banner rests on behaviour Hermes 0.21.5 does not have. Its copyable "fix" renames away a project `.hermes/` directory that Hermes does use legitimately.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectHermesShadowDetector.swift:6-18` (premise), `:71-101` (detect: any `<project>/.hermes/` dir), `:146-177` (fix = `mv .hermes .hermes.scarf-bak.<ts>`). Wired in `scarf/scarf/Features/Dashboard/ViewModels/DashboardViewModel.swift:191-195`. Banner copy is in `scarf/scarf/Features/Dashboard/Views/DashboardView.swift:154` ("Hermes' CLI uses the closest one as `$HERMES_HOME`…") and `:220-222`.
- Hermes @v2026.9.24: `hermes_constants.py:112-119` + `:161-170`. `get_hermes_home()` = context override → `HERMES_HOME` env → `~/.hermes`. It never walks the cwd for `.hermes/`. The only cwd-relative `.hermes/` readers are legitimate project features: project skills at `agent/skill_utils.py:431-437` (`<root>/.hermes/skills`, loaded when trusted via `skills.trusted_project_dirs`); project plugins at `hermes_cli/plugins_discovery.py:187-189` (`HERMES_ENABLE_PROJECT_PLUGINS`); and the verify manifest at `agent/verify/environment.py:17` (`.hermes/environment.json`).
- Failure scenario: a user keeps project-scoped Hermes skills in `<project>/.hermes/skills/`. The Dashboard shows a yellow warning saying credentials and config are "shadowed". The user copies and runs the fix, which renames `.hermes/` aside. The project's skills, plugins and verify manifest then silently stop loading in that project's chats. Nothing about `$HERMES_HOME` changes, because nothing was ever shadowed. Separately, `hermes auth add` run from inside such a project still writes to `~/.hermes/auth.json`, so the "missing provider" story in the doc comment cannot happen on 0.21.5.
- Evidence: `get_hermes_home` docstring: "context-local override → HERMES_HOME env var → platform default". `PROJECT_SKILLS_SUBDIRS = (os.path.join(".hermes", "skills"), …)`.
- Suggested fix: retire the detector and banner, or reduce it to an informational note about project skills/plugins. Either way, drop the rename one-liner.

### S11-projects-core-F2 · P2 · SOURCE · NEW
- Claim: Unarchive runs `hermes cron resume` on every job tagged for the project, including jobs that were paused before archiving. Template-installed jobs are created paused, so those get switched on too. Separately, a failed pause during archive is discarded, so "archived" can hide jobs that are still running.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectsViewModel.swift:650-652` (archive → `setCronPaused(true)`, result discarded) and `:669-671` (unarchive → `setCronPaused(false)` for all). `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectLifecycleService.swift:137-150` (`cronJobIDs` has no enabled-state filter) and `:159-186`. The installer creates jobs paused at `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:283-330`.
- Hermes @v2026.9.24: `hermes_cli/cron.py:812-820` (`cron resume <id>` → `_job_action("resume")` re-enables and schedules), `:766-791`, `:892`.
- Failure scenario: install a template (its 3 jobs are created PAUSED and still waiting for review), archive the project, then restore it. All 3 jobs are now enabled and fire on schedule, using the default model and costing money, although the user never enabled them. Also, when archive's `cron pause` fails (for example SSH timeout or a busy lock), the project still shows as archived and the jobs keep firing. The `failed` array returned by `setCronPaused` is dropped, so there is no UI signal.
- Suggested fix: on archive, record which job ids were enabled (for example in the registry row or the record), and resume only those. Show pause failures to the user.

### S11-projects-core-F3 · P2 · SOURCE · NEW
- Claim: iOS never applies a project's bound model preset to a project chat. The iOS project screen still shows "Model: <preset>", and the block written from iOS tells the agent the preset was already applied.
- Scarf: `scarf/Scarf iOS/Projects/ProjectDetailView.swift:78-82,184-223` (badge) and `:96` (New Chat). `scarf/Scarf iOS/Chat/ChatView.swift:2919-3050` (`resetAndStartInProject` → `startInternal`: `newSession(cwd:)` then attribution, with no `setSessionModel`). The resume path at `:3129-3190` behaves the same. `grep setSessionModel` finds no hits in `Scarf iOS/` or `Packages/ScarfIOS`. The Mac path does apply it, in `scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:1988-1993` and `:1705-1758`. The block text is at `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift:360` ("`session/set_model` already applied it at session boot").
- Hermes @v2026.9.24: `acp_adapter/server.py:1015-1051` (`set_session_model` exists). Without that call, `_make_agent` uses `model.default` from config (`acp_adapter/session.py:472-495`).
- Failure scenario: on the Mac, bind preset "Opus-fast" to project P. On iPhone, open P: the header shows "Model: Opus-fast". Tap New Chat. The session actually runs on the config.yaml default, and the agent has been told the preset is active.
- Suggested fix: port `applyProjectModelPreset`, which is transport-agnostic ScarfCore reads plus an ACP RPC, into the iOS `startInternal` and resume paths.

### S11-projects-core-F4 · P3 · SOURCE · NEW
- Claim: the "refresh the AGENTS.md block before resume so a resumed chat picks up cron/config changes" step has no effect on 0.21.5. For a session that has history, Hermes reuses the system prompt it stored at creation, including the Project Context tier.
- Scarf: `scarf/Scarf iOS/Chat/ChatView.swift:3122-3128` (the comment's premise is "Hermes re-reads context at every `hermes acp` boot"). The Mac equivalent is `scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:1896-1928`, which rewrites the block on every start, resume included. The rename rationale in `.memory/architecture/project-lifecycle-transitions-have-side-effects-outside.md` assumes the same thing.
- Hermes @v2026.9.24: `agent/conversation_loop.py:681-730`. If there is `conversation_history` and a stored `system_prompt` row, the stored bytes are reused when `_stored_prompt_matches_runtime` holds (`:815-838`), which checks only model, provider, session id and cwd.
- Failure scenario: a user resumes an old project chat after adding a slash command, a cron job, or renaming the project. The agent still sees the block from when the chat started: the old project name, and no new cron or slash commands. A new chat is correct.
- Suggested fix: fix the comments and set expectations only. For example, a note that "project context updates apply to new chats". No code change is needed unless fresh context on resume matters.

### S11-projects-core-F5 · P3 · SOURCE · NEW
- Claim: the managed block tells the agent to schedule project work with `hermes cron create --workdir <project>`. Every Scarf project surface, however, attributes cron jobs only by a `[proj:<uuid>]` or `[tmpl:<id>]` name prefix, which the block never mentions. Jobs the agent creates in a project chat therefore never appear as the project's jobs.
- Scarf: the block is at `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift:362`. Prefix-only attribution appears in `ProjectContextBlock.swift:389-401` (the block's own cron list), `scarf/scarf/Features/Projects/ViewModels/ProjectCockpitViewModel.swift:294-302` (cockpit), and `ProjectLifecycleService.swift:137-150` (archive pause).
- Hermes @v2026.9.24: `cron/jobs.py:498` keeps `--name` verbatim, and the agent chooses the name. `hermes cron create --help` lists `--workdir` (LIVE).
- Failure scenario: in a project chat the user says "refresh the data every morning". The agent runs `hermes cron create --workdir /path/proj "0 9 * * *" …` as instructed. The job runs, but the cockpit cron panel and the block's "Registered cron jobs" still say "(none attributed to this project)", and archiving the project does not pause it.
- Suggested fix: add `--name "[proj:<id>] <label>"` to the block's cron instruction, since the id is known at render time. Alternatively, also attribute jobs whose `workdir` equals the project root.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `<project>/AGENTS.md` auto-load from session cwd | file/context | `ProjectContextBlock.swift:209-256`; `ChatViewModel.swift:1891-1928` | `agent/prompt_builder.py:1733-1756,1689-1710`; `agent/system_prompt.py:709-718`; `acp_adapter/server.py:761-770` (per-turn cwd pin) | OK |
| Context-file priority (`.hermes.md`/`HERMES.md` walk-up, `AGENTS.override.md`) shadows the block | file/context | `ProjectAgentContextService.swift:14-16` | `agent/prompt_builder.py:139-149,1611-1627,1750-1752` | TRACKED (`.memory/features/Project-Scoped Chat and AGENTS.md Context.md:25`; `.memory/architecture/hermes-system-prompt-tier-order-…md:18`) |
| Block vs context injection scanner (`html_comment_injection`, context-scope patterns) | file/context | `ProjectContextBlock.swift:307-373` | `tools/threat_patterns.py:25-105`; `agent/prompt_builder.py:81-108` | OK (no pattern matches the markers or block text) |
| Stored system prompt reused on resume | behaviour | `ChatView.swift:3122-3128` (iOS), `ChatViewModel.swift:1896-1928` | `agent/conversation_loop.py:681-730,815-838` | FINDING-F4 |
| `hermes acp` process cwd = project | spawn | `ChatViewModel.swift:550-552,1891-1894`; iOS `makeClient(projectCwd:)` | fallback launch dir, `prompt_builder.py:1743` | OK (redundant with session cwd) |
| ACP `session/new` / `session/load` `cwd` | ACP | `ChatViewModel.swift:1942-1985`; iOS `ChatView.swift:3017-3027,3164-3170` | `acp_adapter/session.py:176-182,252-265` | OK |
| ACP `session/set_model` (`provider:model`) | ACP | `ChatViewModel.swift:1705-1758` | `acp_adapter/server.py:1015-1051` | OK (Mac) / FINDING-F3 (iOS never calls it) |
| ACP `session/set_mode accept_edits` | ACP | `ChatViewModel.swift:1780-1805`; `ProjectAutoAcceptEditsStore.swift` | `acp_adapter/server.py:240-249,1053-1065` (`workspace_session` policy) | OK |
| `~/.hermes/cron/jobs.json` read (`{"jobs":[…]}`, `name`, `workdir`, `schedule.expr/display/kind`, `enabled`) | file | `ProjectDoctorService.swift:1035-1040`; `ProjectLifecycleService.swift:190-195`; `ProjectCockpitViewModel.swift:151,294-302`; `ProjectStore` | `cron/jobs.py:1,74,498,765-834,1376` | OK |
| `[proj:<uuid>]` / `[tmpl:<id>]` cron name attribution | convention | `ProjectContextBlock.swift:389-401`; `ProjectLifecycleService.swift:137-150`; `ProjectDoctorService.swift:352-376` | `cron/jobs.py:498` (name verbatim) | OK / FINDING-F5 (agent not told the convention) |
| `hermes cron pause <id>` / `hermes cron resume <id>` | argv | `ProjectLifecycleService.swift:159-186`; `FleetApplyExecutor.swift:417` | `hermes_cli/cron.py:766-791,812-820,892`; exit via `hermes_cli/main.py:3614-3617` | OK (argv, exit) / FINDING-F2 (resume policy) |
| `hermes cron create --name --deliver --failure-deliver --repeat --paused --skill --workdir -- <schedule> [prompt]` | argv | `FleetApplyPlan.swift:474-523`; `FleetApplyExecutor.swift:333-401` | `hermes_cli/cron.py:698-722` (returns 1 on failure) → `main.py:3614-3617`; `--help` LIVE | OK |
| Fleet per-host model preset presence check | file | `FleetApplyViewModel.swift:29-36,104-131` | n/a (Scarf store `~/.hermes/scarf/model_presets.json`) | OK |
| Fleet board / Kanban tenant set | file (manifest) | `FleetApplyExecutor.swift:213-218` | n/a (Scarf manifest; tenant is consumed by `hermes kanban create --tenant`, LIVE) | OK |
| Block text: `hermes kanban create --tenant`, `hermes cron create --workdir`, `hermes skills install <identifier-or-https-url>` | argv (guidance) | `ProjectContextBlock.swift:340,362,363` | `--help` LIVE for all three | OK |
| Block text: kanban tasks stamped with the originating session id | behaviour (guidance) | `ProjectContextBlock.swift:359` | `hermes_cli/kanban_db.py:730,951`; `tools/kanban_tools.py:221,1038-1048` | OK (detail belongs to S13) |
| `<project>/.hermes/` shadow-home assumption | behaviour | `ProjectHermesShadowDetector.swift:6-18,71-177`; `DashboardView.swift:145-222` | `hermes_constants.py:112-119,161-170`; `agent/skill_utils.py:431-437`; `hermes_cli/plugins_discovery.py:187-189` | FINDING-F1 |
| `~/.hermes/memories/MEMORY.md` template namespace block (read-only in cockpit) | file | `ProjectCockpitViewModel.swift:152,305-313` | `tools/memory_tool.py` | OK for the read; write side is S12 |
| state.db `sessions` list ∩ attribution sidecar | SQL | `ProjectSessionsViewModel.swift:71-121` → `HermesDataService.swift:344-360,492` | compression children excluded as Hermes does (`hermes_state_common` ref in Scarf) | OK (SQL owned by S04) |
| `~/.hermes/scarf/projects.json`, `session_project_map.json`, `<project>/.scarf/*` | Scarf-owned files | `HermesPathSet.swift:94-129`; `ProjectDashboardService`, `ProjectStore`, `RegistryWriteLock`, `ProjectRegistrySalvage`, `ProjectDashboard`, `ScarfProject`, `ProjectPortfolio` | n/a (Hermes never reads them) | OK |
| Doctor orphan scan excludes `~/.hermes` + `~/.hermes/profiles/*` | path | `ProjectDoctorService.swift:535-547` | profiles live at `<root>/profiles/<name>` (`hermes_cli/profiles.py`) | OK |
| Root policy refuses roots containing the Hermes home | path | `ProjectRootPolicy.swift:67-102,159-190` | n/a | OK |
| Widget path resolution | path | `WidgetPathResolver.swift` | n/a | OK |
| Hermes native `projects.db` (`hermes_cli/projects_db.py:23-60`) not used | design | — | `hermes_cli/projects_db.py` | TRACKED (`.memory/architecture/hermes-has-no-project-concept-…md:22`; deliberate) |
| iOS list/picker registry load (`loadRegistryDetailed`, archived filter) | file | `Scarf iOS/Projects/ProjectsListView.swift:25-98`; `Scarf iOS/Chat/ProjectPickerSheet.swift:112-144` | n/a | OK |
| Sidebar / cockpit view / chat settings sheet / damage banner | UI | `SidebarProjectsWell.swift`, `ProjectCockpitView.swift`, `ProjectChatSettingsSheet.swift`, `RegistryDamageBanner.swift` | no direct Hermes touchpoint (they go through the services above) | OK |

## Not audited / couldn't verify
- ACP transport internals (spawn, SSH `cd`/env, `HERMES_HOME` injection for named profiles) → S01/S15. I only checked that the project cwd reaches `session/new` and `session/load`, and that Hermes pins it per turn.
- `cron_status` and `log_tail` widgets (S08/S14) and `kanban_summary` (S13) have their own Hermes readers, which I did not re-audit here.
- Template install/uninstall and MEMORY.md block writes, mini-apps, and the `scarf-projects` MCP server → S12. Skill bootstrap during project creation → S10.
- The session-list SQL predicate itself → S04.
- A Hermes session born through the `session/load` fallback `newSession` on resume is not attributed to the project when the caller did not pass `projectPath` (Mac global resume). This only affects non-ACP-persisted sessions (cron/CLI), so I judged it an edge case and did not report it.
- `ProjectAutoAcceptEditsStore` keys only by project path, not by server, so two hosts with the same absolute project path share the toggle. This is a documented design choice and I did not report it.
