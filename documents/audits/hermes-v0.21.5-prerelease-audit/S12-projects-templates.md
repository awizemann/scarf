# S12-projects-templates — verdict: WORKS-WITH-ISSUES

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Catalog browse (fetch/cache/fallback, cache via transport) | WORKS | — |
| 2 | Template install: files, skills → `<skills>/templates/<slug>/`, MEMORY.md entry, `hermes cron create … --paused -- <sched> <prompt>`, projects.json row, .env mirror (local + SSH) | WORKS | — |
| 3 | Template config edit / secrets re-mirror | WORKS | — |
| 4 | Template uninstall: `.env` strip, files, skills namespace dir, `hermes cron remove <id>` (exit 1 judged as leftover), memory block strip, registry row, grants | WORKS | — |
| 5 | Export `.scarftemplate` (reads project/skills/cron over transport, zips locally with `/usr/bin/zip`, NSSavePanel → lands on Mac) | WORKS | — |
| 6 | scarf-projects MCP server registration (`hermes mcp add` bare + in-place `--hermes-home` pin; re-pin other profiles; local only) + stdio server (MCP 2025-06-18) | WORKS | — |
| 7 | Mini-app open: grant sheet → WKWebView + `scarf-miniapp://` handler + bridge; `scarf.prompt` via isolated `hermes acp` session | WORKS local / DEGRADED remote | F1 |
| 8 | Bundled built-in skills bootstrap (`SkillBootstrapService`, off-manifest, followed) | WORKS | — |

## Findings
### S12-projects-templates-F1 · P2 · SOURCE · NEW
- Claim: On a remote (SSH) server window, the cockpit lists a project's mini-apps and offers "Open", but the asset scheme handler always judges the base dir as a LOCAL path, so the mini-app never loads (403 plain-text body) after the user has gone through the grant sheet.
- Scarf: scarf/scarf/Features/Projects/Views/ProjectCockpitView.swift:369-377 (Open offered for any context; manifests listed via transport, MiniAppService.swift:78/106); scarf/scarf/Features/Projects/MiniApp/MiniAppHostView.swift:32-37 (baseDir = remote project path); scarf/scarf/Features/Projects/MiniApp/MiniAppSchemeHandler.swift:63-68 (`anchor(... context: .local)`), :97-108 (refusal → 403); Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppAssetResolver.swift:210-235 (ssh → `.notLocal`; local judgement of a remote path fails root policy / physical-path check).
- Hermes @v2026.9.24: n/a (Scarf-side presentation).
- Failure scenario: remote project with `.scarf/miniapps/<id>/` → Mini-apps tab shows it → Open → grant sheet (writes remote grants file) → web view shows a raw refusal text / blank page. Honest result would be "mini-apps run on local projects only" with the button disabled.
- Suggested fix: disable/hide Open (with a note) when `serverContext.isRemote`, or stage assets locally.

No other defects found. Checked specifically: cron create argv matches `hermes cron create --help` (LIVE: `--name/--deliver/--failure-deliver/--repeat/--skill/--workdir/--paused` all present, positional `schedule [prompt]` after `--`); `cron_create` returns 1 on `success: False` (hermes_cli/cron.py:698-712) and Scarf aborts on non-zero (ProjectTemplateInstaller.swift:393-396); `cron remove` returns 1 on failure (hermes_cli/cron.py:766-787, 895) and Scarf reports a leftover (ProjectTemplateUninstaller.swift:795-803); memory path `<home>/memories/MEMORY.md` (tools/memory_tool.py:40); skills root `<home>/skills` with nested lookups (tools/skills_tool.py:60-70); MCP stdio env filtering motivates the `--hermes-home` pin (tools/mcp_tool_config.py cited in code); `hermes mcp add` interactive prompts (hermes_cli/mcp_config.py:611-688) are answered by the shared `HermesMCPAdd` planner (S-MCP section owns it).

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| Packages/ScarfCore/Sources/ScarfCore/Models/MiniAppManifest.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/Sources/ScarfCore/Models/MiniAppPermission.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppAssetResolver.swift | no | FINDING-F1 (contributing) |
| Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppBridge.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantSigner.swift | no (Scarf file under ~/.hermes/scarf) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantStore.swift | no (~/.hermes/scarf/miniapp_grants.json, Scarf-owned) | OK |
| Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppOpenURLPolicy.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppRateLimiter.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppService.swift | no | OK |
| Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppStore.swift | no | OK |
| Packages/ScarfCore/Sources/ScarfProjectsMCPKit/ProjectMCPToolCatalog.swift | yes (MCP tools/list) | OK |
| Packages/ScarfCore/Sources/ScarfProjectsMCPKit/ProjectMCPTools.swift | yes (projects.json, Scarf-owned) | OK |
| Packages/ScarfCore/Sources/ScarfProjectsMCPKit/StdioLoop.swift | yes (MCP stdio framing) | OK |
| Packages/ScarfCore/Sources/scarf-projects-mcp/main.swift | yes (--hermes-home) | OK |
| scarf/Core/Models/ProjectTemplate.swift | yes (paths) | OK |
| scarf/Core/Models/TemplateConfig.swift | no | NO-TOUCHPOINT |
| scarf/Core/Services/CatalogService.swift | yes (~/.hermes/scarf cache) | OK |
| scarf/Core/Services/InstalledTemplatesIndex.swift | no | OK |
| scarf/Core/Services/ProjectScaffolder.swift | no (projects.json) | OK |
| scarf/Core/Services/ProjectTemplateExporter.swift | yes (cron jobs read, skills read) | OK |
| scarf/Core/Services/ProjectTemplateInstaller.swift | yes (cron create/pause, skills, MEMORY.md, .env) | OK |
| scarf/Core/Services/ProjectTemplateService.swift | yes (skills/memory paths, unzip) | OK |
| scarf/Core/Services/ProjectTemplateUninstaller.swift | yes (cron remove, jobs.json, skills, MEMORY.md, .env) | OK |
| scarf/Core/Services/ProjectUpgradeService.swift | no | OK |
| scarf/Core/Services/ProjectsMCPRegistrar.swift | yes (mcp add, config.yaml mcp_servers) | OK |
| scarf/Core/Services/TemplateURLRouter.swift | no | NO-TOUCHPOINT |
| scarf/Features/Projects/MiniApp/MiniAppAgentSession.swift | yes (ACP session/new, prompt, permission cancel) | OK |
| scarf/Features/Projects/MiniApp/MiniAppHostView.swift | no | FINDING-F1 |
| scarf/Features/Projects/MiniApp/MiniAppInspectorSurface.swift | no | NO-TOUCHPOINT |
| scarf/Features/Projects/MiniApp/MiniAppLaunchView.swift | no | FINDING-F1 (Open offered on remote) |
| scarf/Features/Projects/MiniApp/MiniAppSchemeHandler.swift | no | FINDING-F1 |
| scarf/Features/Projects/MiniApp/ScarfMiniAppBridge.swift | indirect (ACP via session) | OK |
| scarf/Features/Templates/ViewModels/CatalogViewModel.swift | no | OK |
| scarf/Features/Templates/ViewModels/TemplateConfigEditorViewModel.swift | yes (.env mirror) | OK |
| scarf/Features/Templates/ViewModels/TemplateConfigViewModel.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/ViewModels/TemplateExporterViewModel.swift | no (off-main) | OK |
| scarf/Features/Templates/ViewModels/TemplateInstallerViewModel.swift | no (off-main) | OK |
| scarf/Features/Templates/ViewModels/TemplateUninstallerViewModel.swift | no (off-main) | OK |
| scarf/Features/Templates/Views/CatalogCategoryFilter.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/CatalogDetailView.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/CatalogRowView.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/CatalogView.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/ConfigEditorSheet.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/TemplateConfigSheet.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/TemplateExportSheet.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/TemplateInstallSheet.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/TemplateMarkdown.swift | no | NO-TOUCHPOINT |
| scarf/Features/Templates/Views/TemplateUninstallSheet.swift | no | NO-TOUCHPOINT |

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes cron create --name … [--deliver] [--skill] --paused -- sched prompt` | argv | ProjectTemplateInstaller.swift:365-396; FleetApplyPlan.swift:479-530 | hermes_cli/cron.py:698-722 (LIVE --help) | OK |
| `hermes cron pause <id>` (pre-0.21.1 fallback only) | argv | ProjectTemplateInstaller.swift:407 | hermes_cli/cron.py:766-794 | OK |
| `hermes cron remove <id>` | argv | ProjectTemplateUninstaller.swift:795-803 | hermes_cli/cron.py:766-787,895 | OK |
| `<home>/cron/jobs.json` read (resolve names→ids, export) | file | ProjectTemplateUninstaller.swift:400-470; ProjectTemplateExporter.swift:~115 | cron/jobs.py (workdir resolved) | OK |
| `<home>/skills/templates/<slug>/<name>/` write/remove; `--skill templates/<slug>/<name>` | file/argv | ProjectTemplateService.swift:171-190; ProjectTemplateInstaller.swift:323-332 | tools/skills_tool.py:60-70,345-361 | OK |
| `<home>/memories/MEMORY.md` `§` entry append/strip | file | ProjectTemplateService.swift:274,335-360 | tools/memory_tool.py:40 | OK |
| `<home>/.env` project block mirror/strip | file | ProjectTemplateInstaller.swift:50-61; ProjectTemplateUninstaller.swift:641-653 | tools/skills_tool.py load_env | OK |
| `hermes mcp add scarf-projects --command <bin>` | argv | ProjectsMCPRegistrar.swift:272-275 (HermesFileService.swift:596) | hermes_cli/mcp_config.py:611-688 | OK |
| `config.yaml mcp_servers.scarf-projects.{command,args}` in-place patch | config | ProjectsMCPRegistrar.swift:300-362, 373-405 | tools/mcp_tool_config.py | OK |
| MCP initialize/tools/list/tools/call (2025-06-18) | MCP | ScarfProjectsMCPKit/ProjectMCPServer.swift:18-90; StdioLoop.swift | mcp SDK client | OK |
| `hermes acp` session/new(cwd=project), session/prompt, permission cancel | ACP | MiniAppAgentSession.swift:179-198, 292-313 | acp_adapter/server.py:759-770 | OK |
| `~/.hermes/scarf/{projects.json,miniapp_grants.json,catalog cache}` | Scarf-owned files | ProjectMCPTools.swift; MiniAppGrantStore.swift:204-286; CatalogService.swift:131-167 | — | OK |
| Bundled skills → `<home>/skills/<category>/<name>` | file | SkillBootstrapService.swift:44-100 | tools/skills_tool.py | OK |

## Not audited / couldn't verify
- `HermesMCPAdd` prompt-answer plan and `HermesFileService.setMCPServerArgs/Command` patcher internals (owned by MCP/config sections); assumed correct.
- `ACPClient` wire handling (chat section).
- `KeychainEnvMirror` block format (secrets section).
- Did not run any mutating command; no live cron/mcp round-trip.
