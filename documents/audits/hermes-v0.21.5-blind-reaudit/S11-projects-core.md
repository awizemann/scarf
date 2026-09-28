# S11-projects-core — verdict: WORKS-WITH-ISSUES

The main Hermes-facing path works against v2026.9.24 (0.21.5). A project chat sets the ACP session cwd to the project, Hermes loads that folder's AGENTS.md for the session, and the model preset and accept-edits mode are applied through RPCs Hermes really has. Archive and restore call `hermes cron pause|resume`, and those exit non-zero when they fail. Fleet cron copy builds a `cron create` argv that matches the tagged argparse. No P0 or P1 found. Four findings (2×P2, 2×P3): two are Scarf-internal filtering errors and two are cosmetic.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Create project (scaffold, registry write, root policy, AGENTS.md block) | WORKS | — |
| 2 | Open project cockpit (record load-or-derive, AGENTS.md block preview, cron panel, MEMORY.md block, host zone note, doctor) | WORKS | (TRACKED caveat: .hermes.md shadowing) |
| 3 | Start or resume a project chat (cwd, AGENTS.md block, model preset, auto-accept edits, attribution), Mac and iOS | WORKS | F3 (git chip, Mac local only) |
| 4 | Project Sessions tab (attribution sidecar → state.db list), Mac and iOS | DEGRADED | F1 |
| 5 | Project Doctor (diagnose/repair) | WORKS (false positives possible with symlinked roots) | F4 |
| 6 | Archive/restore (pause/resume attributed cron jobs); remove (grant revoke + AGENTS.md block strip); rename; move | WORKS | — |
| 7 | Fleet apply across servers (preset, board, cron copy) | DEGRADED | F2 |
| 8 | Dashboard widgets that read files (log_tail, path resolver) | WORKS | — |
| 9 | Registry salvage / damage banner | WORKS (no Hermes dependency except MEMORY.md flock interop, which matches) | — |
| 10 | iOS project list, detail and picker | WORKS (parity note: iOS never applies project auto-accept edits; the setting is per-Mac UserDefaults, so this is by design) | F1 applies |

## Findings

### S11-projects-core-F1 · P2 · SOURCE · NEW
- **Claim:** The Project Sessions tab (Mac and iOS) only looks at the 200 newest sessions on the whole host. On a host that runs cron or gateway traffic, a project's older chats drop off the list, and the empty-state text wrongly says they "may have been deleted from Hermes".
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectSessionsViewModel.swift:124` (`fetchSessionsChecked(limit: 200)`, then client-side filter at :132). The hint is at :142. The list query is `HermesDataService.swift:541` with predicate :375-395. That predicate does not filter by source, so cron, gateway and CLI sessions all count toward the 200.
- **Hermes @v2026.9.24:** every cron run writes its own session row (`cron/scheduler.py:69-82` `_set_cron_session_title(session_db, session_id, …)`). The `hidden` column (`hermes_state_common.py:395`) is not set for cron or gateway sessions.
- **Failure scenario:** One 15-minute cron job produces 96 sessions a day. About two days later the 200-row window contains only recent cron and gateway sessions. The project tab shows "This project has N attributed sessions, but none are in the recent history. They may have been deleted from Hermes." In fact they are still in state.db. If only some have fallen out, the list is silently partial.
- **Evidence:** the code comment at :116-121 itself says "If a single project accumulates more than 200 attributed sessions, we'll need a paged query". But the cap applies to all sessions on the host, not per project. No TASKS/tasks/decisions entry covers this.
- **Suggested fix:** query the attributed ids directly (`WHERE id IN (…)` plus compression-chain expansion) instead of filtering a global top-200.

### S11-projects-core-F2 · P2 · SOURCE · NEW
- **Claim:** Fleet apply never copies the cron jobs of a project installed from a template. The preview says "source has no copyable project cron jobs" even though the project has jobs attributed to it.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/FleetApplyPlan.swift:286` (`for job in jobs where job.name.hasPrefix(tag)`, where tag is `[proj:<uuid>]`). Template installs name jobs `[tmpl:<id>] [proj:<uuid>] …` (`ProjectCronAttribution.swift:34-41`, used at `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:365`). Everything else in Scarf matches both shapes with `ProjectCronAttribution.namesProject` (`ProjectCronAttribution.swift:47-52`), and the doctor uses it at `ProjectDoctorService.swift:366`.
- **Hermes @v2026.9.24:** not a Hermes question. Hermes stores `--name` exactly as given (`cron/jobs.py:1804,1811`).
- **Failure scenario:** The user installs a template (its cron jobs are created as `[tmpl:x] [proj:U] Daily digest`), then opens Fleet → Apply to another host. The cron field is offered as "skip: source has no copyable project cron jobs" (`FleetApplyPlan.swift:225-226`) and nothing is copied. The only exclusion documented at :220-223 is *legacy* `[tmpl:<id>]` jobs with no project tag, so leaving out project-tagged template jobs looks like an oversight.
- **Evidence:** `hasPrefix("[proj:…]")` is false for any name that starts with `[tmpl:`.
- **Suggested fix:** partition with `ProjectCronAttribution.namesProject(jobName:projectID:)` instead of `hasPrefix(tag)`.

### S11-projects-core-F3 · P3 · SOURCE · NEW
- **Claim:** In a local project chat on the Mac, the git-branch chip never appears. `GitBranchService` starts the bare name `"git"`, and `LocalTransport` turns it into a file URL relative to the process cwd; it never searches PATH.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GitBranchService.swift:46-51` (`executable: "git"`) → `scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/LocalTransport.swift:271` (`proc.executableURL = URL(fileURLWithPath: executable)`). Called from `scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:2307-2311`.
- **Hermes:** n/a (Scarf-only subprocess).
- **Failure scenario:** The user opens a project chat on the local server for a git repo. The URL resolves to `/git` (a GUI app's cwd is `/`), the launch throws, the error is caught at :57, the function returns nil and the chip is hidden. Remote (SSH) and iOS are unaffected because the remote shell resolves `git` through PATH.
- **Evidence:** none of the other local `runProcess` call sites in this section use a bare name (e.g. `LogTailWidgetView` uses `/usr/bin/tail`).
- **Suggested fix:** use `/usr/bin/git` locally, or `/usr/bin/env git`.

### S11-projects-core-F4 · P3 · SOURCE · NEW
- **Claim:** Project Doctor compares cron `workdir` values as text against registry paths, but Hermes stores workdir symlink-resolved. For a project whose registered path goes through a symlink, the doctor reports a false "scheduled jobs that run elsewhere" (low severity) and a false "looks like a project but isn't listed" orphan for the project's own folder (medium).
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDoctorService.swift:365-369` (`normalizedPath(workdir) != normalizedRoot`) and :469-471 (cron workdirs become orphan candidates, checked against `known`, which is text-only). `ProjectIdentity.normalizedPath` is lexical and never resolves symlinks.
- **Hermes @v2026.9.24:** `cron/jobs.py:1580-1590` `_normalize_workdir`: `expanded.resolve()` and `return str(resolved)`.
- **Failure scenario:** The project is registered at `/home/alan/proj`, where `/home` is a symlink (e.g. to `/var/home`), or at `~/Work/proj` through a symlinked `~/Work`. A job created with `--workdir /home/alan/proj` is stored as `/var/home/alan/proj`, so the doctor shows both false findings. Adoption is withheld because the record name collides, so no duplicate row is written. The effect is misleading health output only.
- **Suggested fix:** compare physical paths when local (`ProjectRootPolicy.physicalPath`), or skip workdir comparisons when the two paths differ only after resolving symlinks.

### TRACKED (not new)
- **.hermes.md / HERMES.md / AGENTS.override.md shadow the Scarf AGENTS.md block.** Hermes loads only the first context type it finds: `.hermes.md` (walking up to the git root) wins over the AGENTS.md chain (`agent/prompt_builder.py:1733-1752`, `_find_hermes_md` :139-148). Within one directory, `AGENTS.override.md` wins over `AGENTS.md` (:1612-1627). If a project or an ancestor up to the git root has one of these, the managed block (kanban tenant, `[proj:]` cron naming) is silently not loaded, and the cockpit still shows it as the block the agent will see. Already recorded as a known caveat in `.memory/architecture/project-scoped-chat-and-agents-md-context.md:27` ("deferred"). One doc comment is stale: `scarf/scarf/Core/Services/ProjectAgentContextService.swift:14-15` still lists the priority as "AGENTS.md (or .hermes.md / CLAUDE.md / .cursorrules, in that priority)", but Hermes checks .hermes.md first.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| ACP `session/new` with cwd = project path | ACP | ChatViewModel.swift:2162-2218; iOS ChatView.swift:3060-3066 | acp_adapter/server.py:609-614; session.py:176-182 | OK |
| ACP `session/load` / resume with project cwd | ACP | ChatViewModel.swift:2179 | server.py:616-625; session.py:252-259 | OK |
| Per-turn cwd → context-file discovery (AGENTS.md chain) | Hermes behaviour | ProjectAgentContextService.swift:69-114 | server.py:429-437 → runtime_cwd.py:84-109 → system_prompt.py:707-719 → prompt_builder.py:1733-1752 | OK (TRACKED shadowing caveat) |
| Context-file injection scan vs Scarf block text | Hermes behaviour | ProjectContextBlock.swift:315-386 | prompt_builder.py:81-110; tools/threat_patterns.py | OK (rendered static block scanned with `scan_for_threats(scope="context")` → `[]`) |
| Resume reuses stored system prompt (block not re-read) | Hermes behaviour | ChatViewModel.swift:2105-2118 (documented) | agent/conversation_loop.py:681-730 (per Scarf comment) | OK |
| `<project>/AGENTS.md` guarded write/strip | file | ProjectContextBlock.swift:157-247 | — | OK |
| ACP `session/set_model` (project preset) | ACP | ProjectModelPresetApplier.swift:71-78; ACPClient.swift:740-751 | server.py:1015-1051 (ModelRejected → -32602 error, not a silent success) | OK |
| ACP `session/set_mode` `accept_edits` (project auto-accept) | ACP | ChatViewModel.swift:1979-2004; ACPClient.swift:24 | server.py:239-250, 1053-1065 | OK |
| `hermes cron pause <id>` (archive) | argv | ProjectLifecycleService.swift:186-218 | hermes_cli/cron.py:766-794, 892; main.py:3614-3618 (rc→exit) | OK (LIVE `--help`) |
| `hermes cron resume <id>` (restore) | argv | ProjectLifecycleService.swift:177-181 | cron.py:812-820 | OK (LIVE) |
| Runnable/paused judgement (`enabled`, `state`, `paused_at`) | jobs.json | ProjectLifecycleService.swift:147-160; HermesCronJob.swift:703-714 | cron/jobs.py:515-524, 2067-2077 | OK |
| `~/.hermes/cron/jobs.json` read (cockpit, doctor, store, lifecycle, fleet) | file | ProjectDoctorService.swift:1039; ProjectStore.swift:583; ProjectLifecycleService.swift:228; ProjectCockpitViewModel.swift:302 | cron/jobs.py load_jobs | OK (decoder owned by S08) |
| `hermes cron create --name --deliver --failure-deliver --repeat --paused --skill --workdir -- schedule prompt` (fleet) | argv | FleetApplyPlan.swift:474-523; FleetApplyExecutor.swift:333-341 | cron.py:700-722 (exit 1 on failure) | OK (LIVE `--help`) |
| Fleet copy-set selection by `[proj:]` prefix | Scarf filter | FleetApplyPlan.swift:283-298 | cron/jobs.py:1804 | FINDING-F2 |
| `hermes cron pause` after create (pre-`--paused` hosts) | argv | FleetApplyExecutor.swift:412-423 | cron.py:892 | OK |
| cron `workdir` compare (doctor) | jobs.json field | ProjectDoctorService.swift:365-369, 469-471 | cron/jobs.py:1571-1590 | FINDING-F4 |
| state.db `sessions` list for project tab | SQL | ProjectSessionsViewModel.swift:124; HermesDataService.swift:541, 375-395 | hermes_state_common.py:395 | FINDING-F1 |
| `~/.hermes/scarf/session_project_map.json` attribution | Scarf file | SessionAttributionService.swift:116,148; ChatViewModel.swift:2278; iOS ChatView.swift:3096 | ACP session id = agent session id at create (session.py:176-181) | OK |
| `~/.hermes/scarf/projects.json` registry (+ lock) | Scarf file | ProjectDashboardService.swift:116,312; RegistryWriteLock.swift:215-233 | — (Hermes-native projects live in `projects.db`, separate: hermes_cli/projects_db.py:23-25) | OK |
| `MEMORY.md.lock` flock interop | file lock | RegistryWriteLock.swift:207-210, 338-375 | tools/memory_tool_store.py:168-173 | OK |
| `~/.hermes/memories/MEMORY.md` project block (cockpit read) | file | ProjectCockpitViewModel.swift:309-315 | — | OK |
| `config.yaml` `timezone` + `.env` (cockpit cron zone note) | config | ProjectCockpitViewModel.swift:330-334 | owned by S08 | OK |
| `model.default` (chat settings copy) | config | ProjectChatSettingsSheet.swift:144 | hermes_cli/auth_model_picker.py:291 | OK |
| Block guidance: `hermes kanban create --tenant` | argv (agent-facing) | ProjectContextBlock.swift:346,365 | LIVE `hermes kanban create --help` shows `--tenant TENANT` | OK |
| Block guidance: `hermes cron create --name … --workdir …` | argv (agent-facing) | ProjectContextBlock.swift:375-377 | LIVE `--help` | OK |
| Block guidance: `hermes skills install <identifier>` | argv (agent-facing) | ProjectContextBlock.swift:379 | LIVE `--help` | OK |
| Root policy vs Hermes home | path | ProjectRootPolicy.swift:141-190, 270-282 | — | OK |
| `git -C <path> rev-parse` | subprocess (non-Hermes) | GitBranchService.swift:46-51 | — | FINDING-F3 |
| `/usr/bin/tail -n` (log_tail widget) | subprocess (non-Hermes) | LogTailWidgetView.swift:176-190 | — | OK |
| Capability gates (`hasSessionEditAutoApproval`, `hasKanban`, `hasCronCreatePaused`, `hasCronWorkdir`, `hasCronFailureDeliver`) | caps | ChatViewModel.swift:1986; SidebarProjectsWell.swift:499; iOS ProjectDetailView.swift:70; FleetApplyPlan.swift:488-515 | — (gate floors out of scope) | OK |
| iOS registry read (`loadRegistryDetailed`, archived filter) | Scarf file | ProjectsListView.swift:153-180; ProjectPickerSheet.swift:101-123 | — | OK |
| iOS AGENTS.md block write before `hermes acp` | file | iOS ChatView.swift:2966-3001 | same as Mac | OK |

## Not audited / couldn't verify
- Not run live: no chat, cron or ACP sessions were started (brief forbids it). Every ACP and exit-code verdict is SOURCE or LIVE `--help` only.
- Remote/profile `HERMES_HOME` scoping for `transport.runProcess(context.paths.hermesBinary, …)` in ProjectLifecycleService was not re-traced; it goes through the same transport as every other CLI call (S15 owns it).
- The HermesCronJob / CronJobsFile decoder, the `CronScheduleArgument` round-trip, and the `supportsCronDeliver` grammar are S08's. KanbanTenantResolver and model-preset storage belong to S13/S06. ProjectTemplate* and the MiniApp/MCP kit belong to S12.
- Hermes's own `hermes project` / `projects.db` (0.21.x) is a separate store. Scarf deliberately doesn't write it (KanbanTenantResolver.swift:22-28). Not integrating with it is a product decision, not a defect.
- The per-project auto-accept store is keyed by project path only, not (server, path). Two servers with an identical project path would share the toggle. Not reported because it needs an unusual setup.
