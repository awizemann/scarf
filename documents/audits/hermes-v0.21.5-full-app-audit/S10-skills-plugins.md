# S10-skills-plugins — verdict: WORKS-WITH-ISSUES

Hermes reference: `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (0.21.5). Hermes paths below are relative to that worktree.
The CLI-verdict layer (install/uninstall/update/audit/check markers, plugins enable/disable/install/update, tools toggle, curator verbs) re-verified line by line against the tag and holds. The defects are in the **filesystem readers** (installed-skills scanner, pin source, iOS plugin state), one iOS argv twin, and the built-in skill frontmatter.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Installed skills scan (Mac + iOS, local + SSH) | DEGRADED | F1, F3 |
| 2 | Skill detail / file view / guarded edit | WORKS | — |
| 3 | Hub browse / search (table + `--json`) | WORKS | — |
| 4 | Hub install / install from URL (verdict) | WORKS (verdict); result invisible in Installed for flat/nested installs | F1 |
| 5 | Hub uninstall | WORKS on Mac / BROKEN on iOS | F2 |
| 6 | Update check / Update All / force-update one | WORKS | — |
| 7 | Re-scan (`skills audit`) | WORKS | — |
| 8 | Project skills scan + trust/untrust | WORKS | — |
| 9 | Built-in Scarf skills bootstrap (`skills/scarf/<name>/`) | WORKS locally (macOS); BROKEN on a Linux remote | F5 |
| 10 | Plugins list / enable / disable / install / update / remove (Mac) | WORKS | — |
| 11 | Plugins list (iOS, read-only) | DEGRADED | F4 |
| 12 | Curator status / run / pause / resume / pin / archive / prune / purge / ledger / rollback / adopt / report | WORKS | — |
| 13 | Tools list + toolset enable/disable per platform | WORKS | — |
| 14 | Approvals suggest / apply (parser + argv) | WORKS | — |
| 15 | Skill bundles (read `skill-bundles/*.yaml`) | WORKS | — |

## Findings

### S10-F1 · P1 · SOURCE (+ live filesystem evidence) · NEW
- **Claim:** `SkillsScanner` only understands the fixed layout `skills/<category>/<skill>/`. Hermes discovers `SKILL.md` recursively at any depth. So flat skills (`skills/<name>/SKILL.md`) and nested official skills (`skills/<a>/<b>/<name>/SKILL.md`) never appear in Installed. Their support folders show up as fake "skills" instead.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SkillsScanner.swift:27-83` walks exactly two levels. It treats every top-level directory as a category and every child directory as a skill, with no `SKILL.md` check, and drops any "category" with no child directories (`:81`). `scarf/scarf/Core/Services/HermesFileService.swift:385-387` (`loadSkills`) delegates to it. `scarf/scarf/Core/Services/SkillBootstrapService.swift:271-281` already admits the scanner only recognizes the two-level layout and works around it for Scarf's own skills only. `scarf/scarf/Features/Skills/Views/InstallFromURLSheet.swift:81` placeholder says the category "defaults to `local`" (it defaults to flat).
- **Hermes @v2026.9.24:**
  - `agent/skill_utils.py:783-800` (`iter_skill_index_files`: `os.walk`, any depth) and `tools/skills_tool.py:184-215` (`_find_all_skills`).
  - Flat is the default for hub installs: `hermes_cli/skills_hub.py:700-706`. A category is only prompted for a URL install without `--yes`, and only official skills derive one. Scarf always passes `--yes` and no category. The install path is `f"{category}/{name}" if category else name` (`tools/skills_hub_install.py:155`), and `_prompt_for_category` says "press Enter to install flat" (`hermes_cli/skills_hub.py:300-312`).
  - Official skills keep every segment between `official` and the slug as a nested category (`hermes_cli/skills_hub.py:704-706`), e.g. `mlops/research/dspy`.
- **Failure scenario:**
  - The user installs a skill from Scarf's Hub (any source except `official`: skills-sh, github, clawhub, lobehub, browse-sh, provider taps) or from a URL without a category. Scarf reports "Installed foo". Hermes writes `~/.hermes/skills/foo/SKILL.md`.
  - On reload, Installed either omits `foo` entirely (no subdirectories) or shows a category "foo" containing pseudo-skills named `references` / `scripts` / `templates`. Uninstalling one of those gets an honest refusal.
  - Official nested installs (`mlops/research/dspy`) render as a pseudo-skill "research" under "mlops", and `dspy` itself is invisible.
  - The agent loads all of these fine. Only Scarf's view is wrong.
- **Evidence:** The user's own host (`~/.hermes/skills`, read-only listing) holds 25 flat skills (e.g. `agents-sdk/SKILL.md` + `agents-sdk/references/`) and 16 depth-3 skills (lock file: `mlops/research/dspy`, `mlops/evaluation/weights-and-biases`, `mlops/inference/serving-llms-vllm`, …). All 41 are misrepresented. Bundled Hermes skills are all depth 2, which is why this passes casual testing.
- **Suggested fix:** Walk recursively like `iter_skill_index_files`. A directory containing `SKILL.md` is a skill; stop descending into it. Category = the path between `skills/` and the skill dir (empty = flat). Skip `EXCLUDED_SKILL_DIRS` and dot-dirs. Correct the URL-sheet placeholder.

### S10-F5 · P1 · SOURCE · NEW
- **Claim:** Both built-in Scarf skills declare `platforms: [macos]`, but Scarf bootstraps them onto remote (typically Linux) Hermes hosts. There, Hermes hides them from the skill index and `skill_view` refuses them. The new-project wizard's template-author hand-off and mini-app authoring therefore cannot use the skill on a Linux server.
- **Scarf:**
  - `scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md:7` and `scarf/scarf/Resources/BuiltinSkills.bundle/scarf-miniapp-author/SKILL.md:7` (`platforms: [macos]`).
  - Remote bootstrap call sites: `scarf/scarf/Navigation/AppCoordinator.swift:284` and `scarf/scarf/Features/Projects/ViewModels/NewProjectViewModel.swift:169` (`SkillBootstrapService(context: context)`).
- **Hermes @v2026.9.24:**
  - `agent/skill_utils.py:21,128-145` (`PLATFORM_MAP["macos"] = "darwin"`, matched against the host's `sys.platform`).
  - `tools/skills_tool.py:207` (filtered out of `skills_list`) and `:604-605` (`skill_view` → "Skill '…' is not supported on this platform.").
  - `agent/prompt_builder.py:1221` (excluded from the system-prompt skill index).
- **Failure scenario:** The user runs New Project on an SSH server running Linux. Scarf copies `scarf-template-author` to the remote `~/.hermes/skills/scarf/` and hands off to chat telling the agent to use it. The agent's index doesn't list it and an explicit `skill_view` fails with "not supported on this platform". The user sees the agent improvise or refuse instead of running the interview. The same applies to scarf-miniapp-author (Upgrade Project / mini-app authoring).
- **Suggested fix:** Drop `platforms:` from both skills. They drive `hermes` and write files, and nothing in them is macOS-specific on the Hermes host. If a gate is wanted, use `[macos, linux]`.

### S10-F2 · P2 · SOURCE · NEW (iOS twin of archived t-ec6d2e6d)
- **Claim:** iOS Uninstall passes `skill.id` (`<category>/<name>`) to `hermes skills uninstall`, which only accepts the bare lock-file name. Every uninstall from iOS is refused. The Mac fix never reached iOS.
- **Scarf:** `scarf/Scarf iOS/Skills/Installed/SkillDetailView.swift:283` (`vm.uninstallHubSkill(skill.id)`). The Mac version is correct at `scarf/scarf/Features/Skills/Views/SkillsView.swift:468-472` (`skill.name`, with a comment citing t-ec6d2e6d).
- **Hermes @v2026.9.24:** `tools/skills_hub_install.py:205-210` (`lock.get_installed(skill_name)` → `"'<x>' is not a hub-installed skill (may be a builtin)"`), printed via `_report_pair` → `Error:` (`hermes_cli/skills_hub.py:144-150`, `:943-952`) at exit 0.
- **Failure scenario:** On iOS, tapping ⋯ → Uninstall on a hub skill shows "Uninstall failed — Error: 'creative/pixel-art' is not a hub-installed skill…" and nothing is removed. Scarf reports the failure honestly (the `Error:` marker), so this is a broken action, not a silent success.
- **Suggested fix:** Pass `skill.name` (same as Mac).

### S10-F4 · P2 · SOURCE · NEW
- **Claim:** The iOS Plugins pane derives Enabled/Disabled from a `.disabled` marker file that Hermes never writes. Every user plugin, including ones Hermes does not load, shows "Enabled". It also walks only depth 0, so category folders show as plugins and nested plugins are missed. The Mac pane fixed exactly this.
- **Scarf:** `scarf/Scarf iOS/Plugins/PluginsView.swift:85-104` (`transport.fileExists(path + "/.disabled")`, `name: entry`). Compare the Mac pane: `scarf/scarf/Features/Plugins/ViewModels/PluginsViewModel.swift:6-18,142-276` (`plugins list --json`, or config `plugins.enabled`/`plugins.disabled` plus the one-level recursion).
- **Hermes @v2026.9.24:**
  - `hermes_cli/plugins_cmd.py:1638-1651` (`_plugin_status`: state comes from config.yaml `plugins.enabled`/`plugins.disabled`, else "not enabled").
  - `:1672-1702` (`cmd_list --json` carries `status`).
  - `cmd_install` without `--enable` leaves it "not enabled" (`:989-996`).
- **Failure scenario:** The user installs a plugin with `--no-enable` (or answers N). iOS shows it green "Enabled" while Hermes does not load it. A plugin in `plugins.disabled` also shows "Enabled". Read-only surface, but the state shown is wrong.
- **Suggested fix:** Reuse the Mac path. Call `plugins list --json` on hosts with `hasPluginsListJSON`, otherwise `HermesPluginList.parseConfigActivationLists` + `status(name:key:…)`.

### S10-F3 · P3 · SOURCE · NEW
- **Claim:** The Skills list's "Pinned by curator" badge can never appear. `readPinnedSkillNames` reads `pinned` / `pinned_skills` from `skills/.curator_state`, but Hermes keeps pins per skill in `skills/.usage.json` (`"pinned": true`). `.curator_state` only holds scheduler keys. No caller passes `pinnedNames`.
- **Scarf:**
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/SkillsViewModel.swift:215,232-242`.
  - Badge rendering: `scarf/scarf/Features/Skills/Views/SkillsView.swift:287-291`, `scarf/Scarf iOS/Skills/Installed/InstalledSkillsListView.swift:51-54`, `scarf/Scarf iOS/Skills/Installed/SkillDetailView.swift:48-60`.
  - `load(pinnedNames:)` has no callers that pass a value (grep).
- **Hermes @v2026.9.24:**
  - `agent/curator.py:43-56` (`load_state` keeps only `last_run_at`, `last_run_duration_seconds`, `last_run_summary`, `last_run_summary_shown_at`, `last_report_path`, `paused`, `run_count` and `_`-prefixed keys).
  - `tools/skill_usage.py:1-5,345-350` (the `pinned` field lives in the `.usage.json` record).
  - `hermes_cli/curator.py:106,121-122` (`curator status` prints `pinned (N): …`, which `HermesCuratorStatusParser` already parses correctly for the Curator screen).
- **Failure scenario:** The user pins a skill with `hermes curator pin x` (exit 0, "pinned 'x'"). The Curator screen lists it as pinned, but the Skills list and the iOS detail never show the pin badge. Live: this host's `.curator_state` has exactly the seven scheduler keys and no `pinned`.
- **Suggested fix:** Read `pinned` from `skills/.usage.json` records, or pass `CuratorViewModel.status.pinnedNames` into `load(pinnedNames:)`.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `~/.hermes/skills/<cat>/<name>/` walk | file | SkillsScanner.swift:27-83; HermesFileService.swift:385-387 | agent/skill_utils.py:783-800; tools/skills_tool.py:184-215 | FINDING-F1 |
| `skill.yaml` `required_config` | file | SkillsScanner.swift:103-108; SkillFrontmatterParser.swift:26-45 | (legacy; not read by Hermes at tag) | OK (display-only, harmless) |
| SKILL.md frontmatter `allowed_tools`/`related_skills`/`dependencies` | file | SkillFrontmatterParser.swift:55-72 | tools/skills_tool.py:615+ (metadata.hermes.* then top-level) | OK (display chips) |
| `config.yaml skills.disabled` (read) | config | SkillsViewModel.swift:250-301 | agent/skill_utils.py:300-311 | OK (the `hermes-agent` essential drop is mirrored at :209) |
| `skills/.curator_state` pinned | file | SkillsViewModel.swift:232-242 | agent/curator.py:43-56; tools/skill_usage.py:345-350 | FINDING-F3 |
| `skills browse --size 40 [--source S]` + 6-col table parse | argv | SkillsViewModel.swift:412-428, 488-503; HermesSkillsHubParser.swift:48-124 | hermes_cli/subcommands/skills.py:38-44; hermes_cli/skills_hub.py:64-69,382-415 | OK |
| `skills search --limit 40 --source S [--json] -- Q` | argv | SkillsViewModel.swift:456-484; HermesSkillsHubParser.swift:149-196 | subcommands/skills.py:46-52; skills_hub.py:319-328 | OK (LIVE help) |
| `skills install --yes [--category] [--name] -- ID` + `Installed:`/refusal markers | argv | SkillsViewModel.swift:537-572,694-705,946-961; HermesCLIOutcome.swift:301-331 | subcommands/skills.py:54-63; skills_hub.py:673-755 (`Installed:` :750, `Not installed:` :730) | OK |
| `skills uninstall [--yes] -- NAME` (Mac) | argv | SkillsViewModel.swift:664-716; SkillsView.swift:472 | subcommands/skills.py:87-90; skills_hub.py:943-952; tools/skills_hub_install.py:205-222 | OK (LIVE help) |
| `skills uninstall` from iOS with `skill.id` | argv | Scarf iOS/Skills/Installed/SkillDetailView.swift:283 | tools/skills_hub_install.py:205-210 | FINDING-F2 |
| `skills check` table + closing-line gate | argv | SkillsViewModel.swift:731-752; HermesSkillsHubParser.swift:229-247 | skills_hub.py:831-849 | OK |
| `skills update` / `update --force -- NAME` + report parse | argv | SkillsViewModel.swift:709,777-808,1066-1152; HermesSkillsHubParser.swift:275-357 | subcommands/skills.py:79-83; skills_hub.py:865-910 | OK |
| `skills audit` | argv | SkillsViewModel.swift:634-657,934-944 | skills_hub.py:913-927 | OK |
| SKILL.md read/write (guarded) | file | SkillsViewModel.swift:1261-1409 | n/a (user file) | OK |
| `~/.hermes/skill-bundles/*.yaml` | file | SkillBundlesScanner.swift:21-46; HermesSkillBundle.swift | agent/skill_bundles.py:27-79 | OK |
| project `.hermes/skills`, `.agents/skills` | file | ProjectSkillsScanner.swift | agent/skill_utils.py (PROJECT_SKILLS_SUBDIRS) | OK |
| `skills.trusted_project_dirs` (read) | config | ProjectSkillsScanner.swift (parseTrustedProjectDirs) | agent/skill_utils.py:477-490 | OK (lexical compare vs Hermes `resolve()`; only matters for symlinked roots) |
| `skills trust|untrust -- ROOT` + markers | argv | ProjectSkillsScanner.swift (trustArgs); ProjectSkillsViewModel.swift | subcommands/skills.py:28-35; hermes_cli/main_agent_cmds.py:184-240 | OK |
| Built-in skills → `skills/scarf/<name>/` | file | SkillBootstrapService.swift:44-100,293-330 | agent/skill_utils.py:783-800 | OK (location) |
| Built-in skill frontmatter `platforms: [macos]` | file | BuiltinSkills.bundle/*/SKILL.md:7 | agent/skill_utils.py:128-145; tools/skills_tool.py:604-605 | FINDING-F5 |
| URL-install sheet name/category validation | argv | SkillInstallValidator.swift; InstallFromURLSheet.swift:39-48,114-119 | tools/skills_hub_install.py:149-155 | OK (placeholder text: see F1) |
| `plugins list --json` | argv | PluginsViewModel.swift:156-180; HermesPluginList.swift (parseJSON) | subcommands/plugins.py:71-81; plugins_cmd.py:1672-1702 | OK (LIVE help) |
| `plugins.enabled`/`plugins.disabled` (fallback read) | config | PluginsViewModel.swift:229-276; HermesPluginList.swift (parseConfigActivationLists) | plugins_cmd.py:1638-1651 | OK |
| `plugins compat --json` | argv | PluginsViewModel.swift:189-192 | subcommands/plugins.py:115-124; plugins_cmd.py:2429-2443 | OK |
| `plugins install --enable/--no-enable -- ID` + outcome parse / consent | argv | PluginsViewModel.swift:350-413; HermesPluginList.swift (HermesPluginInstallOutcome.parse) | subcommands/plugins.py:18-43; plugins_cmd.py:916-1000,1408-1440 | OK |
| `plugins enable [--(no-)allow-tool-override] -- NAME` | argv | PluginsViewModel.swift:477-511 | subcommands/plugins.py:83-92; plugins_cmd.py:1329-1380 | OK |
| `plugins disable -- NAME` | argv | PluginsViewModel.swift:520-547 | subcommands/plugins.py:94-96; plugins_cmd.py:1524+ | OK |
| `plugins update` / `plugins remove -- NAME` | argv | PluginsViewModel.swift:436-459 | subcommands/plugins.py:63-69; plugins_cmd.py:1052,1150 | OK |
| plugin manifests `plugin.yaml/.yml/.json` (tool_override badge) | file | PluginsViewModel.swift:287-320 | plugins_cmd.py (_read_manifest) | OK |
| iOS plugins `.disabled` marker + depth-0 walk | file | Scarf iOS/Plugins/PluginsView.swift:85-104 | plugins_cmd.py:1638-1651 | FINDING-F4 |
| `curator status` text parse + `.curator_state` | argv/file | CuratorService.swift:37-50; HermesCuratorReport.swift:158-395; CuratorViewModel.swift:97-133 | hermes_cli/curator.py:76-139; agent/curator.py:37-56 | OK |
| `curator run` (sync default) + prune-only note | argv | CuratorService.swift:94-100; CuratorViewModel.swift:285-292 | curator.py:142-186,610-624 | OK (LIVE help) |
| `curator pause|resume` | argv | CuratorService.swift:102-110 | curator.py:189-197 | OK |
| `curator pin|unpin|restore|archive -- NAME` | argv | CuratorService.swift:143-185 | curator.py:225-248,297-322,626-641 | OK |
| `curator prune --days N (--dry-run|-y)` + parse | argv | CuratorService.swift:195-202,461-482 | curator.py:333-367 | OK |
| `curator ledger [--skill] --limit` + parse | argv | CuratorService.swift:210-217,504-554 | curator.py:385-410 | OK |
| `curator purge [--days] (--dry-run|-y)` + parse | argv | CuratorService.swift:235-245,574-621 | curator.py:413-457 | OK |
| `curator rollback ID -y` + parse | argv | CuratorService.swift:256-270,665-712 | curator.py:465-487 | OK |
| `curator adopt NAME --yes` / `--all-unmanaged --yes [--dry-run]` | argv | CuratorService.swift:278-297 | curator.py:251-294 | OK |
| `curator list-archived` / `list-unmanaged` parse | argv | CuratorService.swift:55-73,354-451 | curator.py:236-248,552-557 | OK |
| curator REPORT.md at `last_report_path` | file | CuratorViewModel.swift:114-119 | agent/curator.py:680-718,957 | OK |
| `tools list --platform P` + ✓/✗ parse | argv | ToolsViewModel.swift:179-182; HermesToolsList.swift:17-49 | subcommands/tools.py:21-23; tools_config_mcp.py:187-201,251-253 | OK |
| `tools enable|disable NAME --platform P` + verdict | argv | ToolsViewModel.swift:61-96; HermesCLIOutcome.swift:1568-1583,286-297 | subcommands/tools.py:25-36; tools_config_mcp.py:256-289 | OK |
| `mcp list` (raw display) | argv | ToolsViewModel.swift:184-188 | (S09 owns mcp) | OK |
| `approvals suggest --json [--days] [--min-count]` / `--apply N --json` | argv | HermesApprovalsSuggestParser.swift; SettingsViewModel.swift:1648-1680 | subcommands/approvals.py:22-43; approvals_suggest.py:316-366 | OK (managed-host `save_config` refusal on apply belongs to S05) |

## Not audited / couldn't verify
- Rich rendering of `skills browse` at the non-TTY default width (80 cols). The fixed widths sum above 80, so Rich shrinks and folds columns. The parser's continuation-row merge (Description joined with a space, Identifier concatenated) matches Rich's fold/word-wrap rules, but I did not run a live browse (it performs network fetches). UNVERIFIABLE live, OK by source.
- Whether any Hermes code path logs to stderr during `plugins list --json` (combined output: a trailing stderr line would fail the decode and drop the pane to the directory-walk fallback). No such print was found in `cmd_list`, but plugin discovery can log. PLAUSIBLE-OK.
- Disabled/enabled state is keyed by directory name in Scarf and by frontmatter `name` in Hermes (`tools/skills_tool.py:209`). They differ only for hand-made skills whose frontmatter name ≠ folder. Not reported (rare).
- Skill enable/disable toggling: Scarf has no write path (read-only badge), so nothing to verify.
- Remote profile HERMES_HOME: all paths come from `context.paths` (profile-scoped home). Not traced beyond that, since S15 owns transport.
