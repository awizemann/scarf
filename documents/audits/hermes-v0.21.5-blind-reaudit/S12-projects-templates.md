# S12-projects-templates — verdict: WORKS-WITH-ISSUES

Local template install/uninstall/export, the projects MCP server and registrar, and the mini-app agent session all trace cleanly against Hermes v2026.9.24. The one substantive defect is **remote (SSH) template uninstall**: with the default `~`-rooted remote paths it deletes none of the template's files or skills, yet reports success. There are two smaller issues: the projects MCP server ignores the profile of the Hermes that spawned it, and the export sheet does SSH/disk I/O on the main actor.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Browse catalog (fetch/cache/fallback) | WORKS | F4 (P3, main-actor cache read) |
| 2 | Install template — project files, skills → `skills/templates/<slug>/`, cron via `hermes cron create`, MEMORY.md entry, registry row, lock, `.env` mirror | WORKS (local + remote) | — |
| 3 | Template config editor (config.json + Keychain + `.env` re-mirror) | WORKS | — |
| 4 | Uninstall template (lock-driven) | WORKS local / BROKEN remote with default `~` paths | F1 (P1) |
| 5 | Export template (.scarftemplate lands on the Mac via NSSavePanel + local staging/zip) | WORKS; DEGRADED responsiveness on remote | F3 (P2) |
| 6 | ProjectsMCPRegistrar (`hermes mcp add scarf-projects --command <bundle path>`, re-point in place) | WORKS | — |
| 7 | scarf-projects-mcp server vs Hermes MCP client (handshake, tools/list, tools/call, ping) | WORKS; profile-scoping gap | F2 (P2) |
| 8 | MiniApp agent session (dedicated `hermes acp`, session/new cwd=project, auto-deny permissions) | WORKS | — |
| 9 | MiniApp grants / assets / kanban query | WORKS (Scarf-only files; kanban via S13 service) | — |
| 10 | Template upgrade | UNVERIFIABLE — no template-upgrade path exists in the manifest files (only re-install / uninstall). `ProjectUpgradeService` (project structure upgrade) belongs to S11. | — |

## Findings

### S12-F1 · P1 · SOURCE · NEW
- **Claim:** On an SSH host with the default remote paths, template uninstall refuses to delete every project file and the template's skills folder as "outside this project". It still removes the registry row, the cron jobs, the memory entry and the Keychain items, and it reports success.
- **Scarf:**
  - `scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift:1090-1091`: `PathGuard.admits` returns false unless both the candidate and the root start with `/`.
  - The uninstaller applies that check at `:118`, `:138`, `:547`, `:566`, `:579` and `:599` (skills root `:1007-1008` = `context.paths.skillsDir + "/templates"`).
  - Remote paths are `~`-rooted by default:
    - `Packages/ScarfCore/Sources/ScarfCore/Models/HermesPathSet.swift:63` (`defaultRemoteHome = "~/.hermes"`)
    - `ServerContext.swift:141`
    - `ServerContext.swift:161-170` (`defaultProjectsRoot` → `"~/projects"`)
    - `TemplateInstallSheet.swift:476,571-576` (passed verbatim to `buildPlan`)
    - `ProjectTemplateService.swift:114,174`
    - The lock records these paths as-is: `ProjectTemplateInstaller.swift:539-541`.
  - `ProjectRootPolicy.lexicalRefusal` lets non-absolute roots through (`ProjectRootPolicy.swift:185`), so the uninstall proceeds instead of refusing.
  - The comment at `ProjectTemplateUninstaller.swift:1082-1086` ("remote template installs don't exist yet") is stale: the installer supports SSH (`ProjectTemplateInstaller.swift:84-98`) and the install sheet has a remote Verify path.
- **Hermes @v2026.9.24:**
  - The skills that stay behind are still discovered and loaded. `agent/skill_utils.py:790-800` (`iter_skill_index_files` walks the whole skills dir) and `tools/skills_tool.py:343-361`.
  - The cron jobs are removed correctly: `hermes_cli/cron.py:766-794`.
- **Failure scenario:**
  1. The user installs a template on an SSH server with the default parent `~/projects`.
  2. They then click Uninstall.
  3. The plan sheet lists README.md, AGENTS.md, `.scarf/*`, the lock and `~/.hermes/skills/templates/<slug>` under "Skipped — outside this project" (copy that implies the lock was tampered with).
  4. The plan says the project dir becomes empty (extras are empty), and after Remove the sheet reports success.
  - **Actual result:**
    - Every project file stays on the remote host.
    - The template's skills stay installed and keep appearing in the agent's skill index.
    - The registry row is gone, so the project vanishes from the sidebar while its folder remains.
- **Evidence:** `guard candidate.hasPrefix("/"), root.hasPrefix("/") else { return false }` (`ProjectTemplateUninstaller.swift:1091`). `var defaultProjectsRoot … return "~/projects"` (`ServerContext.swift:170`).
- **Suggested fix:** Resolve `~` to the remote home once (transport `$HOME` probe) before building the plan, or have the installer store absolute remote paths. Then keep the absolute-path requirement.

### S12-F2 · P2 · SOURCE · NEW
- **Claim:** The registered `scarf-projects` MCP server always operates on the sticky `active_profile` home, not the home of the Hermes profile that spawned it. An agent running under a non-active profile therefore reads and writes another profile's `scarf/projects.json` and project records.
- **Scarf:**
  - `ProjectsMCPRegistrar.swift:235-239` registers `command: <bundle path>` with no `args` (no `--hermes-home`), into whichever profile is active at Scarf launch (`scarfApp.swift:156`, `.local`).
  - `scarf-projects-mcp/main.swift:96` falls back to `.local`, i.e. `HermesProfileResolver.resolveLocalHome()` (`HermesPathSet.swift:57-59`). That reads `~/.hermes/active_profile` and ignores `HERMES_HOME`.
  - Per-profile registry path: `HermesPathSet.swift:105-106`.
- **Hermes @v2026.9.24:**
  - Stdio MCP children get a filtered env of PATH/HOME/USER/LANG/LC_ALL/TERM/SHELL/TMPDIR/XDG_* only, so `HERMES_HOME` is dropped: `tools/mcp_tool_config.py:74,111-119`, used at `tools/mcp_tool_transport.py:319,330`.
  - `hermes -p <name>` sets `HERMES_HOME` without touching `active_profile`: `hermes_cli/main.py:593-620`.
- **Failure scenario:**
  1. Profiles `default` and `work` both exist. `work` was active when Scarf last launched, so its config.yaml holds the entry. The user later runs `hermes profile use default`.
  2. A `hermes -p work` gateway or chat calls `project_register` or `project_update_dashboard`.
  - **Actual result:** the tool reports success, but the row lands in `~/.hermes/scarf/projects.json` (the default profile's registry), and Scarf's `work` window never shows it.
- **Evidence:** `main.swift` help text documents only the mid-session `active_profile` switch caveat. The `-p`/HERMES_HOME case is not handled.
- **Suggested fix:** Register with `--args --hermes-home <context.paths.home>`, so each config.yaml entry is pinned to the home that owns it.

### S12-F3 · P2 · SOURCE · NEW
- **Claim:** The template export sheet runs `previewPlan()` synchronously on the main actor, three times per render (every keystroke in the form). Each run does about 7 `fileExists` calls, a `jobs.json` read and a slash-command directory listing through the context transport. On an SSH host these are SSH round-trips on the main thread (charter: no SSH on the main actor).
- **Scarf:**
  - `Features/Templates/Views/TemplateExportSheet.swift:139,149,243` call `viewModel.previewPlan()` from `body` / computed view properties.
  - `TemplateExporterViewModel.swift:66-68` is `@MainActor`.
  - `ProjectTemplateExporter.swift:85-106` does 3 + 4 `transport.fileExists`, `HermesFileService.loadCronJobs()` and `ProjectSlashCommandService.loadCommands`.
  - The sheet is not gated to local contexts (`ProjectsView.swift:143-146`).
- **Hermes @v2026.9.24:** n/a (Scarf-side threading).
- **Failure scenario:**
  - **Remote:** the user opens "Export as Template…" on an SSH project and types a description. Every character blocks the UI for roughly 25 SSH operations, so the sheet stutters or beachballs on a slow link.
  - **Local:** it re-reads `jobs.json` from disk three times per keystroke on main.
- **Suggested fix:** Compute the plan once in `load()` on a detached task and cache it on the view model. Recompute only the cron subset when the selection changes.

### S12-F4 · P3 · SOURCE · NEW
- **Claim:** `CatalogService.loadCatalog` reads (and on refresh writes) the catalog cache through the transport on the main actor. `CatalogService` is an un-annotated struct in the MainActor-default app target, and `CatalogViewModel` (`@MainActor`) awaits it directly.
- **Scarf:** `Core/Services/CatalogService.swift:51,126-161,203-205`; `Features/Templates/ViewModels/CatalogViewModel.swift:118`.
- **Failure scenario:** Opening Browse Catalog on an SSH window does `fileExists` + `readFile` (+ mkdir + write on refresh) over SSH on the main thread. This is a brief one-time hitch.
- **Suggested fix:** Mark the cache I/O `nonisolated`, or run it in a detached task.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes cron create --name … [--deliver] [--repeat] [--paused] [--skill …] -- <schedule> [prompt]` | argv | FleetApplyPlan.swift:473-532; ProjectTemplateInstaller.swift:374-396 | `hermes cron create --help` (LIVE); hermes_cli/cron.py:698-721 (exit 1 on failure) | OK |
| `hermes cron pause <id>` (pre-v0.21.1 fallback) | argv | ProjectTemplateInstaller.swift:403-411 | hermes_cli/cron.py:766-794 | OK |
| `hermes cron remove <id>` (uninstall) | argv | ProjectTemplateUninstaller.swift:644-653 | hermes_cli/cron.py:766-794, 890-899 | OK |
| Cron `--skill templates/<slug>/<name>` resolution | cron skill ref | ProjectTemplateInstaller.swift:325-335 | tools/skills_tool.py:343-361; agent/skill_utils.py:78-89, 588-596; cron/scheduler_prompt.py:188-196 | OK |
| Cron name stored verbatim / attribution tags | cron name | ProjectCronAttribution.swift:34-41 | cron/jobs.py:1804-1811 | OK |
| `~/.hermes/cron/jobs.json` read (`{"jobs":[…]}`, `expr`/`run_at`/`display`) | file | ProjectTemplateUninstaller.swift:429-444; ProjectTemplateExporter.swift:493-513 | cron/jobs.py:769-829, 1359, 1478 | OK |
| Export schedule round-trip (expr / run_at / "every Nm") | format | ProjectTemplateExporter.swift:494-498 | cron/jobs.py:768-829 | OK |
| `~/.hermes/skills/templates/<slug>/<name>/**` write/delete | file | ProjectTemplateService.swift:171-192; ProjectTemplateInstaller.swift:204-216; Uninstaller:596-621 | agent/skill_utils.py:790-800 (discovery) | OK local / FINDING-F1 remote |
| `~/.hermes/memories/MEMORY.md` entry append/strip (`\n§\n`, hashed markers) | file | ProjectTemplateService.swift:300-365; Installer:239-291; Uninstaller:1169-1297 | tools/memory_tool_store.py:23, 133-163, 509-527; tools/threat_patterns.py:31; tools/memory_tool.py:38-40 | OK |
| `~/.hermes/.env` SCARF_* block (install/config/uninstall) | file | KeychainEnvMirror.swift:48-160 (called Installer:57-61, ConfigEditorVM, Uninstaller:539-543) | cron/scheduler.py:2333-2341, 2510 (reload per tick) | OK |
| `hermes mcp add scarf-projects --command <path>` + stdin answers + stdout outcome parse | argv/stdin/stdout | ProjectsMCPRegistrar.swift:230-257; HermesFileService.swift:485-491, 596-613; HermesMCPAdd.swift:263-287, 362-395 | `hermes mcp add --help` (LIVE); hermes_cli/mcp_config.py:193-200, 579-608, 611-681 | OK |
| `mcp_servers.scarf-projects.command` read / in-place re-point | config key | ProjectsMCPRegistrar.swift:218-298 | hermes_cli/mcp_config.py:648-655 (shape `command`/`args`) | OK |
| MCP registration profile scoping | config/env | ProjectsMCPRegistrar.swift:235-239; scarf-projects-mcp/main.swift:96 | tools/mcp_tool_config.py:74,111-119 | FINDING-F2 |
| MCP `initialize` (protocolVersion 2025-06-18, capabilities {tools}) | MCP | ProjectMCPServer.swift:18, 35-49 | tools/mcp_tool_transport.py:150-207 (auto mode, completes handshake even on version refusal); tools/mcp_tool.py:75-80 | OK |
| MCP `ping`, `tools/list`, `tools/call` (`isError` result), notifications unanswered | MCP | ProjectMCPServer.swift:31-104; StdioLoop.swift | tools/mcp_tool_schema.py:255-265 (resources/prompts stubs gated on capability) | OK |
| Stdio framing (NDJSON, stderr diagnostics) | MCP transport | StdioLoop.swift:22-80; JSONRPC.swift:84-96 | tools/mcp_tool_transport.py:319-330 | OK |
| ACP `initialize` / `session/new {cwd: projectRoot}` / `session/prompt` | ACP | MiniAppAgentSession.swift:179-198, 150-157 | acp_adapter/server.py:759-770 (cited; transport owned by S01) | OK |
| ACP `session/request_permission` → `{"outcome":{"outcome":"cancelled"}}` | ACP | MiniAppAgentSession.swift:302-309; ACPClient.swift:814-825 | acp_adapter/permissions.py:67-74 (non-Allowed → "deny") | OK |
| Kanban tasks query for mini-app | service | ScarfMiniAppBridge.swift:486-503 | (S13) | TRACKED-by-section S13 |
| `~/.hermes/scarf/projects.json`, `.scarf/project.json`, lock, config.json, manifest.json | Scarf file | Installer:418-472, 505-554; Uninstaller:736-814 | — (Scarf-owned) | OK |
| `~/.hermes/scarf/miniapp_grants.json` (signed) | Scarf file | MiniAppGrantStore.swift:204, 259-286; MiniAppGrantSigner.swift | — | OK |
| `~/.hermes/scarf/catalog_cache.json` | Scarf file | CatalogService.swift:117-161 | — | FINDING-F4 (threading only) |
| Mini-app asset serving (local FileManager, anchored) | Scarf file | MiniAppAssetResolver.swift; MiniAppSchemeHandler.swift:63-69 | — | OK |
| Export staging/zip on the Mac, source reads via transport | file | ProjectTemplateExporter.swift:123-290; TemplateExportSheet.swift:253-259 | — | OK (charter: lands on Mac) / FINDING-F3 (main-actor I/O) |
| `unzip -Zt` / `unzip` / `zip` with timeouts | subprocess | ProjectTemplateService.swift:413-613; Exporter:518-567 | — | OK |
| ProjectScaffolder (dir + `.scarf/` via transport) | file | ProjectScaffolder.swift:63-163 | — | OK |
| MiniAppPermission model | model | MiniAppPermission.swift | — | OK (no Hermes touchpoint) |

## Not audited / couldn't verify
- **MCP SDK negotiation, live:** the `mcp` Python package is not installed in the v0215 venv on this machine (`.venv/lib/python3.11/site-packages` has no `mcp`), so the SDK's supported-version set couldn't be read. Hermes's auto mode completes the handshake at its offered version even when the SDK refuses the server's (`tools/mcp_tool_transport.py:160-170, 190-210`), so 2025-06-18 is accepted either way. Status: SOURCE, not LIVE.
- **Template upgrade:** no upgrade path exists for installed templates; only install/uninstall.
- **Other sections' code:** HermesMCPAdd / the YAML patcher (S09), cron argv builder capabilities (S08) and ACPClient transport (S01) were followed only as far as this section's calls. Their internals are those sections' to audit.
- **Observation, not a finding:** a template memory block that pushes MEMORY.md past `memory.memory_char_limit` (default 2200, `hermes_cli/config_defaults.py:1296`) makes Hermes refuse later agent `memory add` calls until the agent consolidates (`tools/memory_tool_store.py:157-163, 287-292`). Scarf doesn't warn at install. No shipped template uses `memory.append`.
- **Observation, not a finding:** an install that fails mid-way leaves no lock file, so the orphaned skills, cron jobs and memory can't be uninstalled via the lock. This is documented as a v1 limitation (no rollback), `ProjectTemplateInstaller.swift:5-10`.
- **Observation, not a finding:** the `project_set_config` `value` input schema has no `type`. Provider tolerance for this is untested.
