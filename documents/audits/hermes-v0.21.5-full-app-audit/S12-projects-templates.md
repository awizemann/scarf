# S12-projects-templates — verdict: WORKS-WITH-ISSUES

Primary Hermes contracts in this section hold at v2026.9.24: the `hermes cron create` argv (incl. `--paused`, `--skill=`, `--`), `hermes cron remove <id>` exit-code judging, `hermes mcp add` for the projects server, the scarf-projects-mcp handshake (2025-06-18 is in the mcp 2.0.0 client's handshake set), skill placement under `skills/templates/<slug>/<name>` (discoverable, resolvable by bare name), and `.env` reload per cron tick. What's broken is at the edges: a schemaVersion mismatch between the exporter and the installer, a remote-only export gap, the MEMORY.md entry format, and one trust premise in the mini-app session that no longer holds at the tag.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Browse catalog (fetch/cache/stale) | WORKS | — (no Hermes touchpoint; cache is Scarf-owned) |
| 2 | Install template (files, skills, cron, memory, config + secrets → .env, registry, lock) | DEGRADED | F1, F3, F5 |
| 3 | Template config editor (load cached manifest/config, save, re-mirror .env) | WORKS | F5 (rare secrets) |
| 4 | "Upgrade project" (ProjectUpgradeService structure pass) | WORKS | — (Kanban tenant mint goes to S13's KanbanTenantResolver) |
| 5 | Uninstall template (files, skills ns, `cron remove`, memory strip, keychain, registry, grants) | DEGRADED | F4 |
| 6 | Export template (reads via transport, stages + zips on the Mac, NSSavePanel) | DEGRADED | F1, F2 (charter "lands on the Mac": OK) |
| 7 | ProjectsMCPRegistrar (register/re-point `scarf-projects` via `hermes mcp add` / YAML patch; local only) | WORKS | — |
| 8 | scarf-projects-mcp server (stdio JSON-RPC, initialize/tools/list/tools/call) vs Hermes MCP client | WORKS | — |
| 9 | MiniApp agent session (`scarf.prompt` → dedicated `hermes acp` session) | WORKS (functionally) | F6 |
| 10 | MiniApp grants / assets / permissions | WORKS | — (Scarf-only files; security items TRACKED in P7/P8 reports) |

## Findings

### S12-F1 · P2 · SOURCE · NEW
- Claim: A bundle that ships slash commands has to be `schemaVersion: 3`. Scarf's own exporter writes 3 and the author skill requires 3, but the installer rejects anything that isn't 1 or 2. So every exported project that has slash commands (and every v3 catalog bundle) fails to install.
- Scarf: `scarf/scarf/Core/Services/ProjectTemplateService.swift:66-68` (`guard manifest.schemaVersion == 1 || manifest.schemaVersion == 2`) vs `scarf/scarf/Core/Services/ProjectTemplateExporter.swift:241-245` (`if !plan.slashCommandNames.isEmpty { return 3 }`). The author skill says the same thing: `scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md:341` ("MUST be schemaVersion 3"). The catalog validator accepts 3 (`tools/test_build_catalog.py:686-716`). `buildPlan` even has a slash-command branch for "schemaVersion 3+" (`ProjectTemplateService.swift:143-159`) that can never run.
- Hermes @v2026.9.24: n/a (Scarf-internal contract).
- Failure scenario: user exports a project that has `.scarf/slash-commands/*.md` → gets a `.scarftemplate` → opens it in Scarf (same or another Mac) → "Template uses schemaVersion 3, which this version of Scarf doesn't understand." `git log -S` shows the guard hasn't changed since it was added in 64b7d3be (v2.3), before slash commands existed. No test round-trips a v3 bundle.
- Suggested fix: accept `schemaVersion` 1…3 in `inspect()`, and add an export→inspect round-trip test that includes a slash command.

### S12-F2 · P2 · SOURCE · NEW
- Claim: Exporting a project on a remote (SSH) server silently drops its config schema. `readCachedSchema` looks for `<project>/.scarf/manifest.json` with `FileManager` on the Mac's own disk, not through the transport.
- Scarf: `scarf/scarf/Core/Services/ProjectTemplateExporter.swift:231-233` → `:311-321` (`FileManager.default.fileExists(atPath: manifestPath)` / `Data(contentsOf:)`). Everything else the exporter reads goes through `transport.readFile` (`:147-149`, `:287-296`). The export sheet is offered for remote projects too (`scarf/scarf/Features/Projects/Views/ProjectsView.swift:143-146`, built from `serverContext`).
- Hermes: n/a (remote path divergence).
- Failure scenario: a project installed from a schemaful template on an SSH host (e.g. site-status-checker, schemaVersion 2) → Export → the local path doesn't exist, so `forwardedSchema = nil` → the bundle comes out as schemaVersion 1 with no `config` block and no `contents.config`. Installers get no configuration form, and cron prompts that read `.scarf/config.json` find nothing. The export still reports success.
- Suggested fix: read `manifest.json` through `transport` (with the same absent-vs-unreadable handling the rest of the exporter uses).

### S12-F3 · P2 · SOURCE · NEW
- Claim: The template's MEMORY.md appendix is added without Hermes's entry delimiter (`\n§\n`). Hermes therefore reads it as part of whatever entry was last in the file. Its memory `remove`/`replace` operations act on whole entries, so editing either the user's fact or the template block destroys the other. Also, if the template id contains `system`, `secret`, `hidden`, `override` or `ignore`, Hermes's load-time threat scan blocks that combined entry, including the user's own fact.
- Scarf: `scarf/scarf/Core/Services/ProjectTemplateService.swift:290-298` (`"\n\n\(begin) v…\n\(body)\n\(end)\n"`), appended as `existing + appendix` at `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:234`.
- Hermes @v2026.9.24: `tools/memory_tool_store.py:23` (`ENTRY_DELIMITER = "\n§\n"`), `:510-512` (entries = split on the delimiter), `:298-316` (`replace`/`remove` replace or drop the WHOLE matched entry), `:133-165` (load-time `_sanitize` swaps an entry with a threat hit for `[BLOCKED: …]` in the prompt snapshot), `tools/threat_patterns.py:31` (`<!--[^>]{0,512}(?:ignore|override|system|secret|hidden)[^>]{0,512}-->`).
- Failure scenario: MEMORY.md is `fact A\n§\nfact B`. Installing a template with `memory.append` gives Hermes the entries `[fact A, "fact B\n\n<!-- scarf-template:…:begin --> … <!-- …:end -->"]`. Later the agent runs `memory(remove, "fact B")`, and the template block (with both markers) goes with it, so uninstall finds nothing to strip. Or the agent rewrites the template text, and fact B is lost. Uninstall itself still works while the markers survive, because the strip is marker-based.
- Suggested fix: add the appendix as its own entry: prefix it with `\n§\n` when the file isn't empty, have the strip remove that delimiter too, and keep marker text free of the threat-pattern words (or leave the id out of the comment).

### S12-F4 · P2 · SOURCE · NEW
- Claim: The uninstall shows success even when `hermes cron remove <id>` fails. The failure is only logged and the job stays scheduled. Separately, if the cron list can't be read at plan time, every template job is filed as "already gone".
- Scarf: `scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift:470-479` (non-zero exit → `logger.warning`, keeps going); the plan's split at `:151-163` (a job name missing from `loadCronJobs()` → `cronGone`); `scarf/scarf/Features/Templates/ViewModels/TemplateUninstallerViewModel.swift:89-95` (`.succeeded` whenever `uninstall` doesn't throw).
- Hermes @v2026.9.24: `hermes_cli/cron.py:766-794` (`_job_action("remove")` returns 1 on failure), exit code propagated via `forward_return=True` (`hermes_cli/main.py:1925`, `:3614-3617`). Exit-code judging is correct, but the result never reaches the UI.
- Failure scenario: an SSH blip, or a gateway-lifecycle refusal, during `cron remove` → the sheet reports the template uninstalled → the `[tmpl:…]` job is still in `jobs.json`. If the user had resumed it, it keeps firing against a deleted project directory, and nothing tells them to clean it up.
- Suggested fix: collect the cron (and skills/memory) step failures and show them in the success banner as "removed, except: …", keeping the continue-on-error behaviour.

### S12-F5 · P3 · SOURCE (+ library probe) · NEW
- Claim: Template secrets mirrored into `~/.hermes/.env` use shell-style escaping for single quotes (`'foo'\''bar'`), which python-dotenv can't parse, so the variable is dropped entirely. `${…}` inside a single-quoted value is still interpolated by Hermes's loader. The comment claiming single quotes keep `$` literal is wrong for Hermes.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SecretsEnvBlock.swift:90-101` (`escape`), reached from `KeychainEnvMirror.mirror` in install (`ProjectTemplateInstaller.swift:53-57`) and in the config editor save (`TemplateConfigEditorViewModel.swift:116-120`).
- Hermes @v2026.9.24: `hermes_cli/env_loader.py:265-310` (`DotEnv(... interpolate=False).parse()`, then `parse_variables(value)` resolved for EVERY value regardless of quote style); python-dotenv 1.2.2 `parser.py:25` (`'((?:\\'|[^'])*)'`: only `\'` escapes inside single quotes), `main.py:91-95` (erroring bindings are skipped).
- Evidence: parsing `A='foo'\''bar'` and `B='x${HOME}y'` with Hermes's venv dotenv returns `[('B','x${HOME}y'), …]`, i.e. A is dropped with "could not parse statement". B is then expanded to the home path by `env_loader`'s `parse_variables` pass.
- Failure scenario: a template API token or password containing `'` → `$SCARF_<SLUG>_<FIELD>` is missing when the cron job runs.
- Suggested fix: escape as `\'` inside single quotes (dotenv grammar), or use double quotes the way `HermesEnvService.formatLine` does (`HermesEnvService.swift:266-275`), and escape `${` as well.

### S12-F6 · P2 · SOURCE · NEW (contradicts decision note)
- Claim: `MiniAppAgentSession` relies on the idea that Hermes loads project context files (AGENTS.md/CLAUDE.md/.cursorrules) from the `hermes acp` process cwd, so leaving that cwd off the project keeps them out of the web-driven mini-app agent. At the tag that's no longer true. Hermes pins the ACP session cwd for each turn and builds the system prompt inside that turn, so the project's context files are loaded from `projectRoot` (the session cwd Scarf passes).
- Scarf: `scarf/scarf/Features/Projects/MiniApp/MiniAppAgentSession.swift:14-36, 55-60, 191` (`newSession(cwd: projectRoot)`); the premise is recorded in `.memory/decisions/project-context-file-injection-release-note-awareness-not-a.md:38` (t-0b850b5b).
- Hermes @v2026.9.24: `acp_adapter/server.py:759-770` (`set_session_vars(... cwd=state.cwd ...)` for every turn) → `gateway/session_context.py:143` (`set_session_cwd`) → `agent/runtime_cwd.py:84-110` (`resolve_context_cwd` = the session override) → `agent/system_prompt.py:708-719` (`build_context_files_prompt(cwd=resolve_context_cwd())`, ACP never sets `_context_cwd_is_launch_artifact`) → `agent/prompt_builder.py:1733-1752` (loads .hermes.md/AGENTS.md/CLAUDE.md/.cursorrules from that cwd). The prompt is built in the turn: `agent/turn_context.py:1086`, `agent/conversation_loop.py:719,779`.
- Failure scenario: a project cloned from an untrusted source contains a hostile `CLAUDE.md`, and its mini-app (possibly agent-generated) calls `scarf.prompt` → that file is injected into the unsupervised, web-driven agent's system prompt, which is exactly what t-0b850b5b meant to prevent. Tool permission prompts are still auto-denied (`:308-315`), which limits the damage.
- Suggested fix: re-decide t-0b850b5b against the tag. Options: accept it and fix the doc/decision note, or pass a neutral session cwd (and do file access through the bridge) if isolation is still wanted.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes cron create --name= [--deliver=] [--failure-deliver=] [--repeat=] [--paused] [--skill=]… [--workdir=] -- <schedule> [prompt]` | argv | FleetApplyPlan.swift:473-523 (called from ProjectTemplateInstaller.swift:319-339) | hermes_cli/cron.py:698-722; subcommands/cron.py; `--help` LIVE | OK |
| `cron create` exit judging (non-zero → throw) | exit code | ProjectTemplateInstaller.swift:336-339 | cron.py:709-711 + main.py:1925 forward_return, :3614-3617 | OK |
| `hermes cron pause <id>` (fallback for hosts without --paused) | argv | ProjectTemplateInstaller.swift:346-354 | cron.py:766-794 | OK |
| `hermes cron remove <id>` | argv | ProjectTemplateUninstaller.swift:474-479 | cron.py:766-794, :893 | FINDING-F4 (UI) |
| `~/.hermes/cron/jobs.json` read (name → id) | file | ProjectTemplateUninstaller.swift:154; ProjectTemplateExporter.swift:94 | cron/jobs.py:498-508 (name stored stripped, as given) | OK (reader owned by S08) |
| Template job name `[tmpl:<id>] <name>` | cron data | ProjectTemplateService.swift:189-198 | cron/jobs.py:1804 | OK |
| Skills to `<home>/skills/templates/<slug>/<name>/**` | file | ProjectTemplateService.swift:161-184; Installer :192-204 | agent/skill_utils.py:23-89 (`templates` is a support dir only below a SKILL.md); tools/skill_manager_tool.py:228-255 (bare-name resolution) | OK |
| Skills namespace removal | file | ProjectTemplateUninstaller.swift:447-468 | — | OK |
| MEMORY.md appendix at `<home>/memories/MEMORY.md` | file | ProjectTemplateService.swift:290-298; Installer :227-241 | tools/memory_tool_store.py:23, :133-165, :298-316, :510-512 | FINDING-F3 |
| MEMORY.md block strip | file | ProjectTemplateUninstaller.swift:983-1040 | same | OK (marker-based) |
| `~/.hermes/.env` secrets block (`SCARF_<SLUG>_<FIELD>`) | file | SecretsEnvBlock.swift:75-101 via KeychainEnvMirror | hermes_cli/env_loader.py:265-310; cron/scheduler.py:1492-1494 (reload per job); tools/environments/local.py:244-277 (SCARF_* not scrubbed) | FINDING-F5 (quoting only) |
| `{{PROJECT_DIR}}` / `{{TEMPLATE_ID}}` / `{{TEMPLATE_SLUG}}` prompt tokens | cron prompt | ProjectTemplateInstaller.swift:423-432 | — | OK |
| `<home>/scarf/projects.json` register/remove | Scarf file | Installer :373-403; Uninstaller :535-620 | — (Hermes never reads it) | OK |
| `<project>/.scarf/{config,manifest,template.lock,dashboard}.json`, slash-commands | project files | Installer :144-188, :436-485 | — | OK |
| Template manifest schemaVersion gate | Scarf contract | ProjectTemplateService.swift:66-68 vs Exporter :241-245 | — | FINDING-F1 |
| Export: cached schema read | file (remote) | ProjectTemplateExporter.swift:311-321 | — | FINDING-F2 |
| Export output via NSSavePanel + local `/usr/bin/zip` (timeout 120 s) | charter | TemplateExportSheet.swift:254-258; Exporter :329-396 | — | OK |
| Template unzip bounds `unzip -Zt` / unzip (timeouts) | subprocess | ProjectTemplateService.swift:346-390 | — | OK |
| `hermes mcp add scarf-projects --command <bundle>/Contents/Helpers/scarf-projects-mcp` | argv | ProjectsMCPRegistrar.swift:230-257 → HermesFileService.swift:558-575 → HermesMCPAdd.swift:263-287 | `hermes mcp add --help` LIVE | OK (stdin plan owned by S09) |
| `mcp_servers.scarf-projects.command` read + in-place re-point | config key | ProjectsMCPRegistrar.swift:219, :272-293 | tools/mcp_tool_config.py (stdio `command`) | OK (patcher owned by S09) |
| Registrar local-only (skips SSH) | scope | ProjectsMCPRegistrar.swift:200-202 | — | OK |
| MCP `initialize` → `protocolVersion: 2025-06-18`, `capabilities.tools` | MCP | ProjectMCPServer.swift:18, :35-49 | tools/mcp_tool_transport.py:143-189 (legacy handshake first); mcp_types/version.py HANDSHAKE_PROTOCOL_VERSIONS includes 2025-06-18; pyproject.toml:294 mcp==2.0.0 | OK |
| MCP `notifications/initialized` (no reply), `ping`, `tools/list`, `tools/call` (`isError`) | MCP | ProjectMCPServer.swift:31-104; JSONRPC.swift:46-54 | tools/mcp_tool.py:396 (prompts/resources only when advertised) | OK |
| MCP stdio NDJSON framing, stdout-only protocol | MCP | StdioLoop.swift:22-125 | mcp.client.stdio | OK |
| MCP server env: HOME only (no HERMES_HOME) → resolves active_profile | env | scarf-projects-mcp/main.swift:96 | tools/mcp_tool_config.py:74, :111-119 | OK (documented in --help) |
| Tool catalog schemas (`type: object`) | MCP | ProjectMCPToolCatalog.swift:194-222 | — | OK |
| MiniApp `hermes acp` spawn (no projectCwd) + `session/new {cwd: projectRoot}` | ACP | MiniAppAgentSession.swift:185-204 | acp_adapter/session.py:176-182, :457-514 | OK (protocol) / FINDING-F6 (context premise) |
| MiniApp `session/prompt` + streamed `agent_message_chunk` → reply | ACP | MiniAppAgentSession.swift:143-165, :269-307 | acp_adapter/server.py:747-808 | OK |
| MiniApp permission auto-deny (`cancelPermission`) | ACP | MiniAppAgentSession.swift:308-315 | acp_adapter/permissions.py | OK (client owned by S01) |
| MiniApp `query:kanban.tasks` → KanbanService.list | CLI (delegated) | ScarfMiniAppBridge.swift:488-499 | — | OK (owned by S13) |
| `<home>/scarf/miniapp_grants.json`, grant HMAC, asset resolver, permissions | Scarf files | MiniAppGrantStore/Signer/AssetResolver/MiniAppPermission.swift | — | TRACKED (P7/P8 security; no Hermes touchpoint) |
| Catalog fetch/cache `<home>/scarf/catalog_cache.json` | Scarf file/HTTP | CatalogService.swift:59, :126-229 | — | OK |
| TemplateConfigEditor load/save config.json | project file | TemplateConfigEditorViewModel.swift:51-131 | — | OK (off-main via Task.detached) |

## Not audited / couldn't verify
- The `hermes mcp add` stdin prompt plan (`HermesMCPAdd.defaultsTail` / overwrite prefix) and the MCP YAML re-point patcher: S09 owns them. The registrar depends on them but was not re-traced here.
- The `HermesCronJob` / `jobs.json` parser and `loadCronJobs` failure semantics (S08). F4's "plan misfiles jobs as already gone" part assumes `loadCronJobs` returns `[]` on a read failure.
- `ACPClient.sendPrompt` / the event-stream internals and how `stopReason` / error turns are surfaced (S01/S02). The mini-app returns whatever text streamed, including Hermes's `"Error: …"` final response, as a successful reply, same as chat.
- The iOS side: no iOS counterparts are listed for this section's files.
- The Kanban tenant mint in ProjectUpgradeService / the template `kanbanTenant` (S13).
- Remote install with the default `~/projects` parent: `{{PROJECT_DIR}}` becomes a `~`-prefixed path in cron prompts. The agent's tools most likely expand it, but this wasn't traced end to end (path handling belongs to S11/S15).
- Not a defect: the template installer doesn't pass `--workdir` (supported at the tag; `hermes cron create --help` LIVE), so template cron jobs still run without the project's AGENTS.md or cwd. The installer comment "Hermes doesn't set a CWD for cron runs" is outdated. Worth a feature follow-up.
