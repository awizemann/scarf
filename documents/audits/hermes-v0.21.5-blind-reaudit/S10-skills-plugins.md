# S10-skills-plugins — verdict: WORKS-WITH-ISSUES

Hermes reference: `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (0.21.5), `hermes --version` confirmed.
Most of this section has clearly been through several audit passes already: every skills / curator / tools
argv matches the tagged argparse, exit-0 refusals are judged by output throughout, and the table/JSON
parsers match the current emitters. Four real defects remain: one P2 misreport, one P2 degraded search,
and two P3 display/copy problems.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Installed skills scan (walk, enabled/disabled from `skills.disabled`, pinned from `.usage.json`, bundles from `skill-bundles/*.yaml`) | WORKS | — |
| 2 | Skill detail (file view/edit, frontmatter chips, required-config warning) | DEGRADED | F3 |
| 3 | Hub browse (`skills browse --size 40 [--source]`, 6-col Rich table, folded Identifier) | WORKS | — |
| 4 | Hub search — specific source (`skills search --limit 40 --source S --json -- q`) | WORKS | — |
| 5 | Hub search — "All Sources" (client-side filter of cached browse page) | DEGRADED | F2 |
| 6 | Hub install / install-from-URL (`skills install --yes [--category] [--name] -- id`) | WORKS | F4 (copy only) |
| 7 | Uninstall (`skills uninstall --yes -- <bare name>`) | WORKS | F4 (iOS copy only) |
| 8 | Update check / update all / force update (`skills check`, `skills update`, `skills update --force -- n`) | WORKS | — |
| 9 | Re-scan (`skills audit`) | WORKS | — |
| 10 | Project skills scan + trust/untrust (`skills trust|untrust -- root`) | WORKS | — |
| 11 | Built-in Scarf skills bootstrap (`skills/scarf/<name>/SKILL.md`) | WORKS | — |
| 12 | Plugins list (`plugins list --json`) + compat (`plugins compat --json`) | WORKS | F3 (tool-override badge) |
| 13 | Plugins enable/disable (incl. non-TTY capability consent) | WORKS | — |
| 14 | Plugins install (`--enable/--no-enable -- id`) / remove | WORKS | — |
| 15 | Plugins update (`plugins update -- name`) | BROKEN for catalog-installed plugins | F1 |
| 16 | Curator status/run/pause/resume/pin/unpin/restore/archive/prune/ledger/purge/rollback/adopt | WORKS | — |
| 17 | Tools list + toolset enable/disable (`tools list|enable|disable … --platform p`) | WORKS | — |
| 18 | Approvals suggest / apply (`approvals suggest --json`, `--apply N --json`) | WORKS | — |
| 19 | Computer-use permissions status parser (`computer-use permissions status --json`) | WORKS | — |

## Findings

### S10-F1 · P2 · SOURCE · NEW
- Claim: `plugins update` of a curated-catalog plugin succeeds, but Scarf reports it as **failed**, because the catalog update path prints different success lines from the ones Scarf's verdict accepts.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift:2166-2170` (`isSuccessLine` needs the line to end in `"updated."` or `"is already up to date."`, markers at `:798-801`); used by `scarf/scarf/Features/Plugins/ViewModels/PluginsViewModel.swift` `update(_:)` (`HermesPluginsUpdateVerdict.judge`, `argv` `["plugins","update","--",name]`).
- Hermes @v2026.9.24: `hermes_cli/plugins_cmd.py:1058-1061`. `cmd_update` sends any plugin that has a catalog sidecar to `catalog.cmd_update_catalog` and returns. That function prints `✓ Plugin <name> updated to <sha8>.` or `✓ Plugin <name> is already at catalog pin <sha8>.` (`hermes_cli/plugins_cmd_catalog.py:405-406`) and exits 0. Only the git-pull path prints `updated.` / `is already up to date.` (`plugins_cmd.py:1089-1093`).
- Failure scenario: the user installs a plugin by bare catalog name (`hermes plugins install <name>`, from the CLI or from Scarf's Install sheet, which accepts bare names; `looks_like_catalog_name`, `plugins_cmd_catalog.py:32-36`) and later clicks **Update**. Hermes re-pins it (or finds nothing to change), prints the ✓ line, and exits 0. Scarf finds no accepted success line, so `succeeded=false` and the banner shows a failure. The quoted detail is `lines.last`, which is the ✓ success line itself or the dependency-install output. This is a false negative. The update did land.
- Evidence: `verb = "updated to" if result.changed else "is already at catalog pin"` (plugins_cmd_catalog.py:405).
- Suggested fix: accept the catalog lines as well, e.g. a success line with prefix `Plugin ` that contains ` updated to ` or ` is already at catalog pin `. Keep `capabilities NOT granted` and the non-TTY `update NOT applied` (a `_fail`, exit 1) as refusals.

### S10-F2 · P2 · SOURCE · NEW (the design is intentional, per issue #79 cited in code, but its premise no longer holds at the tag)
- Claim: Hub search with the default **All Sources** only filters the 40 rows of the first browse page, so almost the whole hub can't be searched.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/SkillsViewModel.swift:463-476` (all-sources search → `applyClientSideFilter` over `lastBrowseResults`); the pool comes from `["skills","browse","--size","40"]` at `:437` / `:542`; the filter is at `:577-591`.
- Hermes @v2026.9.24: `do_browse` renders exactly one page of `page_size` rows (`hermes_cli/skills_hub.py:418-435`, `_rank_and_page` at `:349-362`) out of a catalog served from `hermes-index` with a 1,000,000-row limit (`:30-32`). The #79 rationale (that all-source CLI search misses skills browse can see) is now handled inside Hermes: `parallel_search_sources` falls back to the external registries when the index misses a non-empty query (`tools/skills_hub_search.py:234-257`, `_index_miss_fallback_sources` at `:156`).
- Failure scenario: the user opens the Hub (source "all") and types `pdf`. Only matches among the 40 official-first browse rows appear, and anything else shows "No matches", even though `hermes skills search pdf` finds it.
- Suggested fix: for "all", use the CLI search path too (`skills search --json --source all -- q`, which is now index-aware), or at least browse with `--size 100` and say that only the first page is being filtered.

### S10-F3 · P3 · SOURCE · NEW
- Claim: the skill-detail chips, the "required config" warning and the plugin "tool-override" badge read metadata keys Hermes never uses, and miss the keys it does use. Hermes's own skills therefore show none of this, while fields Hermes ignores get shown as if they matter.
- Scarf:
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/SkillFrontmatterParser.swift:69-71` reads top-level `allowed_tools`, `related_skills` and `dependencies`.
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SkillsScanner.swift:179-181` reads `skill.yaml` → `required_config`, which feeds `SkillsViewModel.swift:343-369` `missingConfig`.
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesPluginDirectoryScanner.swift:128,141` reads manifest `tool_override`, which drives the badge and the `--allow-tool-override` confirm in `scarf/scarf/Features/Plugins/Views/PluginsView.swift:310,345`.
- Hermes @v2026.9.24:
  - `related_skills` is read from `metadata.hermes.*` first (`tools/skills_tool.py:613-617`), and all 131 bundled/optional skills that declare it put it under `metadata.hermes`.
  - Skill config needs come from `metadata.hermes.config` (`agent/skill_utils.py:666-689`). Nothing in `agent/`, `tools/` or `hermes_cli/` reads `skill.yaml`, `required_config`, top-level `allowed_tools` or skill `dependencies`.
  - Plugins declare override rights through `capabilities` (`tools.override`, `hermes_cli/plugin_capabilities.py:29`). No manifest `tool_override` key exists anywhere in the tree.
- Failure scenario:
  - Skill detail for bundled skills such as `apple-notes` or `llm-wiki` never shows their related skills.
  - A skill that declares `metadata.hermes.config` keys never triggers the "missing config" warning.
  - A plugin that declares `tools.override` never gets the tool-override badge or Scarf's explicit grant confirm. Hermes's non-TTY consent then fails closed, which Scarf does report through the consent marker.
- Suggested fix: read `metadata.hermes.related_skills` and `metadata.hermes.config` (keeping the top-level `related_skills` fallback, as Hermes does); derive the override badge from `capabilities` containing `tools.override`; drop `allowed_tools`/`dependencies`/`skill.yaml` or label them as author-only.

### S10-F4 · P3 · SOURCE · NEW
- Claim: two pieces of UI copy describe things that don't exist.
- Scarf:
  - `scarf/scarf/Features/Skills/Views/InstallFromURLSheet.swift:57` says "Paste an HTTPS URL pointing at a SKILL.md **or a tarball**".
  - `scarf/Scarf iOS/Skills/Installed/SkillDetailView.swift:40` says "Re-enable from the **Mac app's Skills config UI**". The Mac Skills view is read-only for enabled state: `SkillsView.swift:276-303` only renders the `skills.disabled` state, and nothing in the repo writes `skills.disabled`.
- Hermes @v2026.9.24: `UrlSource._matches` only claims HTTP(S) URLs whose path ends in `.md` (`tools/skills_hub_sources.py:172-184`). There is no tarball adapter for a bare URL, so a tarball URL ends in `Error: Could not download …`. Scarf reports that failure honestly.
- Failure scenario: a user pastes a `.tar.gz` URL on the sheet's own advice and gets a download failure. An iOS user looks for a Mac toggle that doesn't exist.
- Suggested fix: change the copy to "a URL ending in SKILL.md", and point iOS users at `hermes skills config` only.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `~/.hermes/skills/**/SKILL.md` walk (EXCLUDED/support dirs, `_org`) | file | ScarfCore/Services/SkillsScanner.swift:69-151 | agent/skill_utils.py (EXCLUDED_SKILL_DIRS, iter_skill_index_files) | OK |
| `skills.disabled` (config.yaml) read | config key | ViewModels/SkillsViewModel.swift:273-321 | agent/skill_utils.py:300-312 | OK (dir name == frontmatter name for all bundled skills; ESSENTIAL filter on Mac) |
| `skills/.usage.json` `pinned` | file | SkillsViewModel.swift:239-262 | tools/skill_usage.py:51,348,568-574 | OK |
| `skill-bundles/*.yaml` | file | Services/SkillBundlesScanner.swift:21-46; Models/HermesSkillBundle.swift | agent/skill_bundles.py:27-35 | OK |
| SKILL.md frontmatter `allowed_tools`/`related_skills`/`dependencies` | file | Parsing/SkillFrontmatterParser.swift:61-77 | tools/skills_tool.py:613-617 | FINDING-F3 |
| `skill.yaml` `required_config` | file | SkillsScanner.swift:179-181, SkillFrontmatterParser.swift:5-24 | agent/skill_utils.py:666-689 (real source) | FINDING-F3 |
| SKILL.md edit (guarded read/write) | file | SkillsViewModel.swift:1284-1440 | — | OK |
| `skills browse --size 40 [--source S]` | argv/table | SkillsViewModel.swift:437,542; Parsing/HermesSkillsHubParser.swift:48-111 | hermes_cli/subcommands/skills.py:38-44; skills_hub.py:382-435 | OK |
| All-sources search → client filter | logic | SkillsViewModel.swift:463-476,577 | tools/skills_hub_search.py:234-257 | FINDING-F2 |
| `skills search --limit 40 --source S [--json] -- q` | argv/JSON | SkillsViewModel.swift:500-513; HermesSkillsHubParser.swift:136-160 | skills.py:46-52; skills_hub.py:319-326 | OK |
| `skills install --yes [--category C] [--name N] -- id` | argv/verdict | SkillsViewModel.swift:727-734,974-991 | skills.py:54-63; skills_hub.py:673-753 | OK |
| install-from-URL | argv | SkillsViewModel.swift:534-555; InstallFromURLSheet.swift | skills_hub.py:525-561; tools/skills_hub_sources.py:156-184 | OK (FINDING-F4 copy) |
| `skills uninstall --yes -- <name>` | argv/verdict | SkillsViewModel.swift:696-702,748-800 | skills.py:89-92; skills_hub.py:943-952; tools/skills_hub_install.py:205-222 | OK |
| `skills check` table + closing line | argv/table | SkillsViewModel.swift:807-834; HermesSkillsHubParser.swift:212-231 | skills_hub.py:831-849; tools/skills_hub_install.py:262-305 | OK |
| `skills update` / `skills update --force -- n` | argv/verdict | SkillsViewModel.swift:738,855,1049-1085,1128-1150; HermesSkillsHubParser.swift:256-347 | skills.py:79-83; skills_hub.py:865-910 | OK |
| `skills audit` | argv/verdict | SkillsViewModel.swift:657-687,968-977 | skills.py:85-87; skills_hub.py:913-940 | OK |
| `skills trust|untrust -- root`; `skills.trusted_project_dirs` read | argv/config | Services/ProjectSkillsScanner.swift:52-153; ViewModels/ProjectSkillsViewModel.swift | skills.py:28-36; hermes_cli/main_agent_cmds.py:184-252 | OK (Hermes stores `resolve()`d paths; a symlinked project root would read as untrusted: edge case) |
| `./.hermes/skills`, `./.agents/skills` | file | ProjectSkillsScanner.swift:5 | agent/skill_utils.py PROJECT_SKILLS_SUBDIRS | OK |
| Built-in bootstrap `skills/scarf/<name>/SKILL.md` | file write | scarf/Core/Services/SkillBootstrapService.swift | agent/skill_utils.py (recursive walk) | OK |
| BuiltinSkills frontmatter (`name`,`description`,`metadata.hermes.tags`) | file | Resources/BuiltinSkills.bundle/*/SKILL.md | tools/skills_tool.py:185-231 | OK |
| `plugins list --json` | argv/JSON | Features/Plugins/ViewModels/PluginsViewModel.swift:156; Parsing/HermesPluginList.swift:68-125; iOS PluginsView.swift:109 | subcommands/plugins.py:71-81; plugins_cmd.py:1672-1698 | OK (extra `removed` key ignored) |
| `plugins.enabled/disabled` (config fallback) | config key | HermesPluginList.swift:143-195; HermesPluginDirectoryScanner.swift | plugins_cmd.py:1193-1206,1638-1651 | OK (pre-0.16 fallback only) |
| manifest `tool_override` | file | HermesPluginDirectoryScanner.swift:128,141 | hermes_cli/plugin_capabilities.py:29 | FINDING-F3 |
| `plugins compat --json` | argv/JSON | PluginsViewModel.swift:191; Parsing/HermesPluginCompat.swift:92-126 | plugins.py:115-124; plugins_cmd.py:2429-2445; plugin_compat.py:43-48 | OK |
| `plugins install --enable|--no-enable -- id` | argv/verdict | PluginsViewModel.swift:266; HermesPluginList.swift:305-337 | plugins.py:18-43; plugins_cmd.py:916-1004 | OK |
| `plugins enable [--allow-tool-override|--no-…] -- n` | argv/verdict | PluginsViewModel.swift:388-402; HermesCLIOutcome.swift:739-761 | plugins.py:83-92; plugins_cmd.py:1329-1383,1408-1453 | OK (consent marker fits on one Rich line) |
| `plugins disable -- n` | argv/verdict | PluginsViewModel.swift:427; HermesCLIOutcome.swift:764-793 | plugins.py:94-96; plugins_cmd.py:1524-1534 | OK |
| `plugins update -- n` | argv/verdict | HermesCLIOutcome.swift:2160-2223 | plugins_cmd.py:1052-1093; plugins_cmd_catalog.py:381-420 | FINDING-F1 |
| `plugins remove -- n` | argv/exit | PluginsViewModel.swift:358 | plugins.py:67-69; plugins_cmd.py:1150-1164 | OK |
| `curator status` text + `skills/.curator_state` | argv/text/file | Services/CuratorService.swift:39-50; Models/HermesCuratorReport.swift parser; ViewModels/CuratorViewModel.swift | hermes_cli/curator.py:76-142; agent/curator.py:37-56 | OK |
| `logs/curator/<ts>/REPORT.md` via `last_report_path` | file | CuratorViewModel.swift load() | agent/curator.py:682-717 | OK |
| `curator run` (sync default, 600 s) | argv | CuratorService.swift:96-101 | curator.py:145-186,613-627 | OK |
| `curator pause|resume` | argv | CuratorService.swift:103-111 | curator.py:189-197 | OK |
| `curator pin|unpin|restore|archive -- n` | argv | CuratorService.swift:144-185 | curator.py:219-237,297-322 | OK (exit codes propagate, main.py:3614-3617) |
| `curator list-archived` | argv/text | CuratorService.swift:57-66,330-400 | curator.py:548-553 | OK |
| `curator list-unmanaged` | argv/text | CuratorService.swift:72-76 (parseListUnmanaged) | curator.py:240-255 | OK |
| `curator prune --days N --dry-run|-y` | argv/text | CuratorService.swift:195-201 (parsePrune) | curator.py:333-368 | OK |
| `curator ledger [--skill] --limit N` | argv/fixed cols | CuratorService.swift:209-216 (parseLedger) | curator.py:387-416 | OK |
| `curator purge [--days] --dry-run|-y` | argv/text | CuratorService.swift:233-243 | curator.py:419-468 | OK |
| `curator rollback <id> -y` | argv/text | CuratorService.swift:254-268 | curator.py:471-497,500 | OK |
| `curator adopt <n> --yes` / `--all-unmanaged --yes [--dry-run]` | argv | CuratorService.swift:278-297 | curator.py:258-294 | OK |
| `tools list --platform p` | argv/text | Features/Tools/ViewModels/ToolsViewModel.swift:185; Models/HermesToolsList.swift | subcommands/tools.py:21-23; tools_config_mcp.py:187-205 | OK |
| `tools enable|disable <ts> --platform p` | argv/verdict | ToolsViewModel.swift:59-90; HermesCLIOutcome.swift:1577-1591 | tools.py:25-36; tools_config_mcp.py:241-285 | OK |
| `mcp list` (display only) | argv | ToolsViewModel.swift:191 | (S09) | OK |
| `approvals suggest --json`, `--apply N --json` | argv/JSON | Parsing/HermesApprovalsSuggestParser.swift; SettingsViewModel.swift:1653-1720 | subcommands/approvals.py:22-44; approvals_suggest.py:316-366 | OK (re-mines after each apply because indices shift) |
| `computer-use permissions status --json` | argv/JSON | Parsing/HermesComputerUseStatus.swift; HealthViewModel.swift:254 | subcommands/computer_use.py:173-183; tools/computer_use/permissions.py:85-107 | OK |
| HermesFileService.loadSkills (416-429) | file | scarf/Core/Services/HermesFileService.swift:424-426 | — | OK (delegates to SkillsScanner) |

## Not audited / couldn't verify
- Named profiles and remote SSH: this section builds every argv against `context.paths.hermesBinary` and reads every file through `context.paths` / the transport. Whether the transport injects the profile (`-p`/HERMES_HOME) and handles quoting is S13/S15 territory. No path in this section builds a home-relative string by hand.
- Mac `PluginsViewModel.load` parses `plugins list --json` from the COMBINED stdout+stderr (`runHermesCLI`). Any stderr line would make `parseJSON` fail and fall back silently to the user-dir-only walk, which omits bundled plugins. I found no stderr emitter on that path at the tag (console logging only under `--verbose`, `hermes_logging.py:266-277`), so this is not a finding. iOS already reads stdout only.
- Hub browse runs under a 30 s Scarf timeout while Hermes's own fan-out budget is also 30 s (`skills_hub.py:379-380`) plus CLI startup. When the index is unavailable and a registry is slow, Scarf could time out just before Hermes prints its partial page. This is plausible only; not traced live.
- iOS `SkillsView` calls `vm.load()` without `essentialHermesAgentSkill`. That only matters if a stale config still lists `hermes-agent` in `skills.disabled`, which counts as unusual config and was not reported.
- `updateAll()` doesn't set `isHubLoading`, so Update All stays tappable during a run of up to 300 s. This is UI hygiene, not a Hermes-contract issue.
- Pre-0.16 plugin directory fallback (`HermesPluginDirectoryScanner.walk`) was out of scope (older-version degradation).
