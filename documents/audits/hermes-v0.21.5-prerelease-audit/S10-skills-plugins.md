# S10-skills-plugins — verdict: WORKS

All argv were confirmed with `hermes <verb> <sub> --help` against the installed 0.21.5 binary (LIVE). The Hermes handlers and output emitters were traced at `~/.hermes/hermes-agent-v0215` (v2026.9.24).

I found no new defects. Every primary journey uses a real verb and real flags, judges success from Hermes's own success/refusal lines instead of the exit code wherever Hermes exits 0 on failure, and parses the current output shape.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Installed skills scan + detail (frontmatter, required config, pinned/disabled badges, edit/save) | WORKS | — |
| 2 | Hub browse / search (all sources + per-source) | WORKS | — |
| 3 | Hub install (identifier) + install from URL (`--category`/`--name`) | WORKS | — |
| 4 | Uninstall hub skill | WORKS | — |
| 5 | Check for updates / Update all / force-update one | WORKS | — |
| 6 | Re-scan (skills audit), project-skill trust/untrust | WORKS | — |
| 7 | Plugins list / enable / disable / install / update / remove / compat | WORKS | — |
| 8 | Curator status / run / pause / resume / pin / unpin / archive / restore / prune / ledger / purge / rollback / adopt | WORKS | — |
| 9 | Tools list + toolset toggle per platform | WORKS | — |
| 10 | Approvals suggest (mine + apply one) | WORKS | — |
| 11 | Computer-use readiness (Health card) | WORKS | — |
| 12 | iOS Skills (Installed/Hub/Updates), Plugins, Curator | WORKS | Shares the ScarfCore view models. iOS uninstall goes through `uninstallHubSkill(HermesSkill)`, so it sends the bare name. |

## Findings
None new.

These looked like issues at first but did not hold up, so they are not reported:
- **Hub browse identifiers.** The browse table is wrapped at Rich's 80-column default, and `_ident_col` uses `overflow="fold"` (hermes_cli/skills_hub.py:64-68). `parseHubList` joins identifier continuation cells with no separator, so identifiers come through correctly.
- **`skills search`.** `--json` prints a bare array (skills_hub.py:325-329), and Scarf decodes it from stdout only (SkillsViewModel.swift:~540).
- **`skills update` "Updated N skill(s)."** This line counts attempts, not successes (skills_hub.py:906). Scarf keys success on the `Installed:` lines (skills_hub.py:750) instead, and handles the `Not installed:` relabel at :730.
- **`plugins list --json` on the Mac.** The Mac path parses combined stdout+stderr, so any stderr output would break the decode and drop to the directory walk. Stderr is empty in normal runs: the only stderr log handlers are opt-in (`HERMES_PLUGINS_DEBUG`, plugins.py:88-99; verbose mode, hermes_logging.py:268-275).
- **Curator exit codes.** Curator verbs return proper non-zero codes, which main.py:3616-3618 turns into the exit status. Pin/unpin of an unmanaged skill exits 0 with a note (curator.py:229-231), and Scarf shows that note.
- **Project trust after trusting.** Hermes stores the `Path.resolve()`d root (main_agent_cmds.py:200, :237). A project path containing a symlink would re-read as untrusted. That needs an unusual path, so it is out of scope.
- **Skill `enabled` badge.** Scarf matches `skills.disabled` against the directory name, while Hermes also matches the frontmatter name (prompt_builder.py:1439). The two only differ for a hand-authored skill whose frontmatter name differs from its directory, which is rare.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| ScarfCore/Models/CuratorError.swift | no | NO-TOUCHPOINT |
| ScarfCore/Models/HermesCuratorArchive.swift | yes (ledger / purge / rollback result models) | OK |
| ScarfCore/Models/HermesCuratorReport.swift | yes (`curator status` parser + `.curator_state`) | OK |
| ScarfCore/Models/HermesSkill.swift | no (model) | NO-TOUCHPOINT |
| ScarfCore/Models/HermesSkillBundle.swift | yes (`skill-bundles/*.yaml` schema) | OK |
| ScarfCore/Models/HermesToolsList.swift | yes (`tools list` rows) | OK |
| ScarfCore/Parsing/HermesApprovalsSuggestParser.swift | yes | OK |
| ScarfCore/Parsing/HermesComputerUseStatus.swift | yes | OK |
| ScarfCore/Parsing/HermesPluginCompat.swift | yes | OK |
| ScarfCore/Parsing/HermesPluginList.swift | yes | OK |
| ScarfCore/Parsing/HermesSkillsHubParser.swift | yes | OK |
| ScarfCore/Parsing/SkillFrontmatterParser.swift | yes (`metadata.hermes.config`, `related_skills`) | OK |
| ScarfCore/Services/CuratorService.swift | yes | OK |
| ScarfCore/Services/HermesPluginDirectoryScanner.swift | yes (pre-0.16 fallback: `plugins/`, `plugins.enabled`/`disabled`) | OK |
| ScarfCore/Services/ProjectSkillsScanner.swift | yes (`skills trust`, `skills.trusted_project_dirs`) | OK |
| ScarfCore/Services/SkillBundlesScanner.swift | yes (`<home>/skill-bundles`) | OK |
| ScarfCore/Services/SkillInstallValidator.swift | no (URL validation on the Scarf side) | NO-TOUCHPOINT |
| ScarfCore/Services/SkillPrereqService.swift | host `which` only | OK |
| ScarfCore/Services/SkillSnapshotService.swift | no (local "seen" store) | NO-TOUCHPOINT |
| ScarfCore/Services/SkillsScanner.swift | yes (`skills/` walk; mirrors `EXCLUDED_SKILL_DIRS` / `SKILL_SUPPORT_DIRS` / `_org`) | OK |
| ScarfCore/ViewModels/CuratorViewModel.swift | yes | OK |
| ScarfCore/ViewModels/ProjectSkillsViewModel.swift | yes | OK |
| ScarfCore/ViewModels/SkillsViewModel.swift | yes | OK |
| Scarf iOS/Curator/CuratorView.swift | via VM | OK |
| Scarf iOS/Plugins/PluginsView.swift | yes (`plugins list --json`, stdout only) | OK |
| Scarf iOS/Skills/Hub/HubBrowseView.swift | via VM | OK |
| Scarf iOS/Skills/Installed/InstalledSkillsListView.swift | via VM | OK |
| Scarf iOS/Skills/Installed/SkillDetailView.swift | via VM (uninstall by bare name) | OK |
| Scarf iOS/Skills/Installed/SkillEditorSheet.swift | via VM (guarded write) | OK |
| Scarf iOS/Skills/SkillsView.swift | via VM | OK |
| Scarf iOS/Skills/Updates/UpdatesView.swift | via VM | OK |
| scarf/Core/Services/SkillBootstrapService.swift | yes (writes `skills/scarf/<name>/`, which Hermes finds via `os.walk`) | OK |
| scarf/Features/Curator/Views/CuratorArchivedSection.swift | via VM | OK |
| scarf/Features/Curator/Views/CuratorLedgerSection.swift | via VM | OK |
| scarf/Features/Curator/Views/CuratorPruneConfirmSheet.swift | via VM | OK |
| scarf/Features/Curator/Views/CuratorPurgeConfirmSheet.swift | via VM | OK |
| scarf/Features/Curator/Views/CuratorRestoreSheet.swift | via VM | OK |
| scarf/Features/Curator/Views/CuratorView.swift | via VM (prune days 30/60/90/180) | OK |
| scarf/Features/Plugins/ViewModels/PluginsViewModel.swift | yes | OK |
| scarf/Features/Plugins/Views/PluginsView.swift | via VM | OK |
| scarf/Features/Skills/Views/InstallFromURLSheet.swift | via VM | OK |
| scarf/Features/Skills/Views/SkillsView.swift | via VM + npx prereq probe | OK |
| scarf/Features/Tools/ViewModels/ToolsViewModel.swift | yes | OK |
| scarf/Features/Tools/Views/ToolsView.swift | via VM | OK |
| Resources/BuiltinSkills.bundle/scarf-miniapp-author/SKILL.md | yes (frontmatter `name`/`description`/`metadata.hermes`) | OK |
| Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md | yes (same) | OK |
| HermesFileService.swift 416-429 | yes (`loadSkills` → SkillsScanner) | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes @v2026.9.24 | Status |
|---|---|---|---|---|
| `skills browse --size 40 [--source S]` | argv + Rich table | SkillsViewModel.swift:447, :581; HermesSkillsHubParser.parseHubList | skills_hub.py:381-433 | OK (LIVE) |
| `skills search --limit 40 --source S --json -- q` | argv + JSON | SkillsViewModel.swift:539-541 | skills_hub.py:319-329 | OK (LIVE) |
| `skills install --yes [--category] [--name] -- id` | argv + markers `Installed:` / refusals | SkillsViewModel.swift:765-771, :1026 | skills_hub.py:730, :750, :135 | OK (LIVE) |
| `skills uninstall [--yes] -- name` | argv + `Uninstalled` / `Error:` | SkillsViewModel.swift:734-739 | skills_hub.py:941-949; skills_hub_install.py:211, :222 | OK (LIVE) |
| `skills check` | argv + table + closing line | SkillsViewModel.swift:844-866 | skills_hub.py:831-849 | OK |
| `skills update` / `update --force -- name` | argv + report | SkillsViewModel.swift:777, :894 | skills_hub.py:865-910 | OK (LIVE) |
| `skills audit` | argv + markers | SkillsViewModel.swift:703 | skills_hub.py:921-927 | OK |
| `skills trust\|untrust -- root` | argv + config key `skills.trusted_project_dirs` | ProjectSkillsScanner.swift:152 | main_agent_cmds.py:184-240 | OK |
| `skills.disabled` (read) | config key | SkillsViewModel.swift:~245 | skill_utils.py:300-312 | OK |
| `skills.config.<key>` + `metadata.hermes.config` | config/frontmatter | SkillsViewModel.computeMissingConfig; SkillFrontmatterParser | skill_utils.py:666-689 | OK |
| `skills/.usage.json` pinned | file | SkillsViewModel.readPinnedSkillNames | tools/skill_usage.py (set_pinned) | OK |
| `skill-bundles/*.yaml` | file | SkillBundlesScanner.swift | agent/skill_bundles.py:27-30 | OK |
| `curator status` + `.curator_state` | argv + text | CuratorService.swift:47; HermesCuratorReport.swift | curator.py:75-142 | OK |
| `curator run` / `pause` / `resume` | argv, exit code | CuratorService.swift:98-110 | curator.py:145-197 | OK (LIVE) |
| `curator pin` / `unpin` / `restore` / `archive -- name` | argv, exit code | CuratorService.swift:145-184 | curator.py:218-321 | OK (LIVE) |
| `curator prune --days N (--dry-run\|-y)` | argv + text | CuratorService.swift:196-200 | curator.py:333-368 | OK (LIVE) |
| `curator ledger [--skill] --limit N` | argv + fixed columns | CuratorService.swift:210 | curator.py:387-416 | OK (LIVE) |
| `curator purge [--days] (--dry-run\|-y)` | argv + text | CuratorService.swift:234 | curator.py:419-468 | OK (LIVE) |
| `curator rollback <id> -y` | argv + text | CuratorService.swift:256 | curator.py:470-496 | OK (LIVE) |
| `curator adopt <name> --yes` / `--all-unmanaged --yes [--dry-run]` | argv | CuratorService.swift:280, :292 | curator.py:258-294 | OK (LIVE) |
| `curator list-archived` / `list-unmanaged` | argv + text | CuratorService.swift:58, :73 | curator.py:548-553, :240-255 | OK |
| `plugins list --json` | argv + JSON | PluginsViewModel.swift:156; iOS PluginsView.swift:109 | plugins_cmd.py:1672-1703 | OK (LIVE) |
| `plugins compat --json` (exit 1 = findings) | argv + JSON | PluginsViewModel.swift:191; HermesPluginCompat.swift | plugins_cmd.py:2429-2445 | OK |
| `plugins install (--enable\|--no-enable) -- id` | argv | PluginsViewModel.swift:266 | plugins_cmd.py:916+ (`_fail` → exit 1) | OK (LIVE) |
| `plugins enable [--(no-)allow-tool-override] -- n` / `disable -- n` | argv + markers | PluginsViewModel.swift:388-430 | plugins_cmd.py | OK (LIVE) |
| `plugins update -- n` / `remove -- n` | argv | HermesCLIOutcome.swift:2186; PluginsViewModel.swift:358 | plugins_cmd.py:1150-1165, :85-88 | OK (LIVE) |
| `tools list --platform P` | argv + ✓/✗ rows | ToolsViewModel.swift:185 | tools_config_mcp.py:186-200 | OK (LIVE) |
| `tools enable\|disable T --platform P` | argv | HermesCLIOutcome.swift:1589 | tools_config_mcp.py | OK (LIVE) |
| `approvals suggest --json` / `--apply N --json` | argv + JSON | HermesApprovalsSuggestParser.swift:48, :61 | approvals_suggest.py:316-366 | OK (LIVE) |
| `computer-use permissions status --json` | argv + JSON | HealthViewModel.swift:254 | tools/computer_use/permissions.py:85-107 | OK (LIVE) |
| `which <bin>` (npx prereq) | host argv | SkillPrereqService.swift:50 | n/a | OK |

## Not audited / couldn't verify
- I did not run any mutating verb live. Success and failure lines are verified from source only.
- Rich column squeeze under SSH: I assumed Rich's non-TTY width is 80. A remote with `COLUMNS` set changes wrapping, and the fold-join logic handles that either way.
- `mcp list` (ToolsViewModel.swift:191) is display-only raw text and belongs to the MCP section.
