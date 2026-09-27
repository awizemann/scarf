# T8-cron-projects-templates-skills — verdict: WORKS

Reference: Hermes worktree `~/.hermes/hermes-agent-v0215` @ `v2026.9.24` (0.21.5; `hermes --version` LIVE = v0.21.5). Code: integration worktree `/Users/awizemann/Developer/Scarf-wt/integration` @ 8b311060.

Every primary journey in this section works against 0.21.5, locally and over SSH. The R14 remediation items in this area hold when re-read end to end:
- the Run Now tick gate
- the widget's effective state
- the cron zone note
- the archive record, and rename carrying `uuid` and `extra`
- the v3 schema guard
- the MEMORY.md entry delimiter and hashed markers
- the dotenv double-quote escaping
- the remote export schema read
- the skill-tree link containment
- the any-depth skills scanner
- the iOS uninstall by bare name
- `.usage.json` pins
- the iOS plugins roster
- the removal of `platforms:` from the built-ins
- deletion of the shadow detector

There is one new P3 finding, on the template export → install round trip. The manifest entry `ProjectHermesShadowDetector.swift` no longer exists. S11-F1 deleted it, and only build artifacts still reference it.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Cron list (jobs.json read) + schedule phrase + host-zone note (Mac, iOS, cockpit) | WORKS | — |
| 2 | Cron create / duplicate / edit (argv, `--`, clear gestures, `--pin` follow-up) | WORKS | — |
| 3 | Pause / Resume / Resume --run-now (Mac CLI; iOS CLI with JSON fallback) | WORKS | — |
| 4 | Run Now: synchronous `cron run` verdict, and the follow-up `cron tick` only on pre-0.18 hosts | WORKS | — |
| 5 | Delete (`cron remove`) | WORKS | — |
| 6 | Run history / doctor / incidents list + ack | WORKS | — |
| 7 | Project dashboard cron-status widget (effective-state badge) | WORKS | — |
| 8 | Project archive (pause runnable jobs, record ids) / restore (resume only recorded) | WORKS | — |
| 9 | Project rename (uuid + extra kept, record name propagated) | WORKS | — |
| 10 | Cockpit: attributed cron, memory block, context block, zone note | WORKS | — |
| 11 | AGENTS.md managed block (render/write/strip; survives Hermes context-file threat scan) | WORKS | — |
| 12 | Project doctor (registry/record/cron checks) | WORKS | — |
| 13 | Template install (schema 1–3, files, skills → `skills/templates/<slug>/`, `cron create --paused`, MEMORY.md entry, `.env` mirror, lock) | WORKS | — |
| 14 | Template export (local + remote, skill tree, cron spec, schema forward) | DEGRADED (edge) | F1 |
| 15 | Template uninstall (cron remove by resolved id, memory strip, `.env` unmirror, leftovers surfaced) | WORKS | — |
| 16 | Skills: scan (any depth, symlinks), browse/search/install/uninstall/update/audit, Mac + iOS | WORKS | — |
| 17 | Built-in skill bootstrap (`skills/scarf/<name>/`) + known-bad prune | WORKS | — |
| 18 | Plugins: Mac list/enable/disable/install/remove; iOS roster (`plugins list --json` → config fallback) | WORKS | — |

## Findings

### T8-F1 · P3 · SOURCE · NEW
- **Claim:** An exported template keeps each cron job's skill reference exactly as stored. That is `category/name` for any categorized skill, and Scarf's own cron picker writes that form. But the bundle flattens skills to `skills/<name>/`, and the installer places them at `skills/templates/<slug>/<name>/`. On another host, the installed job's `--skill category/name` does not resolve.
- **Scarf:**
  - `scarf/scarf/Core/Services/ProjectTemplateExporter.swift:483-496` (`strip`: `skills: job.skills` passed through unchanged).
  - `:172-183` (bundle layout `skills/<skill.name>/`).
  - `:267` (manifest `contents.skills` = last path segment).
  - `scarf/scarf/Core/Services/ProjectTemplateService.swift:171-190` (install to `<skillsDir>/templates/<slug>/<name>`).
  - `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift:318-331` (`--skill` from `job.skills` unchanged).
  - The picker offers path ids: `scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift:199` and `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SkillsScanner.swift:195` (`id = relative path`).
- **Hermes @v2026.9.24:**
  - `cron/scheduler_prompt.py:190-198` (`skill_view(normalize_skill_lookup_name(name))`; a miss is skipped with a "could not be found" note).
  - `tools/skills_tool.py:345-361`: `_collect_skill_candidates` matches the direct path `<skills>/<name>`, or a directory or frontmatter name equal to the whole string. So `creative/pixel-art` never matches `templates/<slug>/pixel-art`.
- **Failure scenario:**
  1. An author has a cron job using a user skill at `skills/creative/pixel-art/`, picked in Scarf's editor.
  2. They export it with that skill included.
  3. Someone installs it on another host that has no `skills/creative/pixel-art`.
  4. The skill lands at `skills/templates/<slug>/pixel-art`, and the job is created with `--skill creative/pixel-art`.
  5. Every run then goes ahead without the skill. Hermes prepends "skill(s) … could not be found".

  Nothing in Scarf reports it. The failure does not occur for flat skills, for Hermes-bundled skills (same path on every host), or when reinstalling on the authoring host.
- **Evidence:**
  - `strip` passes `job.skills` through verbatim.
  - Installer argv: `FleetApplyPlan.cronCreateArgs(... skills: job.skills ?? [] ...)`.
  - Hermes lookup: `_record_direct(search_dir / direct)` plus the recursive `found_skill_md.parent.name == name`.
- **Suggested fix:** In `strip`, rewrite each job skill that the bundle ships to its bare name, or to `templates/<slug>/<name>` at install time. The path form is unambiguous; a bare name can collide with a same-named skill already on the host.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `<home>/cron/jobs.json` read (Mac, iOS, lifecycle, cockpit, doctor, widget, uninstaller) | file | CronViewModel.swift:196; IOSCronViewModel.swift:88-99; ProjectLifecycleService.swift:228-237; ProjectCockpitViewModel.swift:302; ProjectDoctorService.swift:1039-1044; CronStatusWidgetView.swift:180; ProjectTemplateUninstaller.swift:429-447 | cron/jobs.py:1477 | OK |
| iOS jobs.json whole-file write (create/edit/delete/toggle fallback), baseline + .bak | file write | IOSCronViewModel.swift:540-609 | cron/jobs.py | TRACKED (S08 inventory; .memory/decisions/hermes-v0-21-1-compatibility-decisions.md) |
| `cron create [--name= --deliver= --failure-deliver= --repeat= --skill= --script= --workdir= --no-agent --pin] -- <sched> [prompt]` | argv | CronViewModel.swift:1092-1131 | hermes_cli/subcommands/cron.py:25-89; hermes_cli/cron.py:698-724 (exit 1 on failure) | OK (LIVE help) |
| `cron edit [flags] -- <id>` (diffed skills, `--prompt=""`, `--repeat=0`, `--agent`, `--pin/--unpin`) | argv | CronViewModel.swift:1256-1288 | subcommands/cron.py:91-146; cron.py:725-760 | OK |
| `cron pause|resume <id>` (Mac, lifecycle, iOS) | argv | CronViewModel.swift:492,585; ProjectLifecycleService.swift:177,188; IOSCronViewModel.swift:208,470-491 | cron.py:762-783,812-820; cron/jobs.py:2067-2077 | OK |
| `cron resume <id> --run-now` | argv | CronViewModel.swift:604; IOSCronViewModel.swift:290 | cron.py:812-832 | OK (LIVE help) |
| `cron remove <id>` | argv | CronViewModel.swift:982; ProjectTemplateUninstaller.swift:644-653 | cron.py:762-783; cronjob_tools.py:648-657 | OK |
| `cron run <id>` (1800 s) and its verdict markers | argv+parse | CronViewModel.swift:648-658,820-846,946; HermesCLIOutcome.swift:696-732 | cron.py:762-808; cronjob_tools.py:179-199,700-718 | OK |
| `cron tick` only when host < v0.18 and verdict `.started` | argv | CronViewModel.swift:886-892,960-977; CronView.swift:91-94,176,197 | cron.py tick; HermesCapabilities.swift:1884 | OK |
| `cron runs` / `cron incidents` / `incidents ack` / `cron doctor` | argv+parse | CronViewModel.swift:289-487 | cron.py:611-667 and incidents | OK |
| `--pin` did-not-take check | JSON | CronViewModel.swift:111-162 | cron/jobs.py `_main_model_pin` | OK |
| Host zone: `.env` HERMES_TIMEZONE, then config `timezone` | file/config | CronScheduleFormatter.swift:44-100; HermesConfig+YAML.swift:993 | hermes_time.py:71-106; env_loader.py:396-398 | OK |
| Widget badge from effectiveState | JSON | CronStatusWidgetView.swift:123-132; HermesCronJob.swift:703-714 | cron/jobs.py:527-540 | OK |
| `[proj:<uuid>]` / `[tmpl:<id>]` name attribution | JSON (name) | ProjectCronAttribution.swift:22-68 | cron/jobs.py:498,1804-1811 (name stored verbatim) | OK |
| Archive record `archivePausedCronJobIds` in registry `extra` | Scarf file | ProjectLifecycleService.swift:243-268; ProjectsViewModel.swift:631-765 | n/a (runnable test mirrors cron/jobs.py:521-524) | OK |
| AGENTS.md managed block (markers, text) | file | ProjectContextBlock.swift:21-22,313-381 | agent/prompt_builder.py:81-108 (context-scope threat scan BLOCKS whole file) | OK: rendered static block scanned with Hermes's own `_PATTERNS`, context and strict give no hits |
| MEMORY.md template entry (`\n§\n` delimiter, hashed markers), guarded append/strip | file | ProjectTemplateService.swift:303-366; ProjectTemplateInstaller.swift:219-275; ProjectTemplateUninstaller.swift:1169-1260 | tools/memory_tool_store.py:23,132-146,515-538; tools/threat_patterns.py:31 | OK |
| `<home>/memories/MEMORY.md` path | file | HermesPathSet.swift:74 | tools/memory_tool.py:38-40 | OK |
| `<home>/.env` secrets block (`# scarf-secrets:*`, double-quote escaping) | file | SecretsEnvBlock.swift:73-160; KeychainEnvMirror.swift | hermes_cli/env_loader.py:265-310 (dotenv parse then `parse_variables`) | OK |
| Template skills → `<home>/skills/templates/<slug>/<name>/` | file | ProjectTemplateService.swift:171-190; ProjectTemplateInstaller.swift:195-206 | agent/skill_utils.py:783-800 | OK |
| Exported cron spec skill refs | argv (via install) | ProjectTemplateExporter.swift:483-496; ProjectTemplateInstaller.swift:318-331 | cron/scheduler_prompt.py:190-198; tools/skills_tool.py:328-368 | FINDING-F1 |
| Export skill tree walk (dotfiles/guard artifacts skipped, links contained, depth 12) | file | ProjectTemplateExporter.swift:350-470 | agent/skill_utils.py:792 (followlinks) | OK |
| Export `.scarf/manifest.json` via transport | file | ProjectTemplateExporter.swift:318-348 | n/a | OK |
| Template schemaVersion 1…3 guard | Scarf contract | ProjectTemplateService.swift:32,74 | n/a | OK |
| Skills scan (any depth, EXCLUDED/support dirs, `_org` gate, symlink follow) | file | SkillsScanner.swift:49-160 | agent/skill_utils.py:23-37,783-800 | OK |
| `config.yaml skills.disabled` (read, dir-name keyed) | config | SkillsViewModel.swift:270-310 | tools/skills_tool.py:152-168,209 (frontmatter-name keyed) | OK (frontmatter-name ≠ dir-name edge case left as not-reported in R14) |
| `skills/.usage.json` pins | file | SkillsViewModel.swift:234-265 | tools/skill_usage.py:345-374 | OK |
| `skills browse/search/install --yes [--category/--name] -- ID/uninstall [--yes] -- NAME/update/check/audit` | argv | SkillsViewModel.swift:437-880 | subcommands/skills.py; skills_hub.py | OK (LIVE help: uninstall `[--yes] name`) |
| iOS uninstall identifier = `skill.name` | argv | SkillDetailView.swift:290; SkillsViewModel.swift:745-768 | tools/skills_hub_install.py:205-210 | OK |
| `skill-bundles/*.yaml` | file | SkillBundlesScanner.swift | agent/skill_bundles.py | OK |
| Built-in skills bootstrap to `skills/scarf/<name>/`; frontmatter without `platforms:` | file | SkillBootstrapService.swift:44-100; BuiltinSkills.bundle/*/SKILL.md:1-12 | agent/skill_utils.py:128-145; tools/skills_tool.py:207 | OK |
| Built-in skill text vs Hermes CLI (`hermes cron create --workdir/--name`, `cron pause`, `skills config`, `auth spotify`) | docs | scarf-template-author/SKILL.md:87,346-510; iOS SkillDetailView.swift:40,100 | LIVE `hermes skills --help`, `hermes auth --help`, `hermes cron create --help` | OK |
| `plugins list --json` (Mac + iOS, stdout only), then config `plugins.enabled/disabled` + one-level walk fallback | argv/config/file | PluginsViewModel.swift:156-276; PluginsView.swift:95-141; HermesPluginDirectoryScanner.swift:61-148; HermesPluginList.parseJSON | plugins_cmd.py:1638-1702 | OK (LIVE help: `--json`) |
| `plugins install/enable/disable/remove/compat` | argv | PluginsViewModel.swift:191-430 | subcommands/plugins.py; plugins_cmd.py | OK (R14 S10 inventory, not re-derived) |
| ProjectHermesShadowDetector (`<project>/.hermes` banner) | file | removed (manifest path absent) | hermes_constants.py:112-119 | OK (deleted per S11-F1) |
| Projects registry / `.scarf/project.json` / salvage | Scarf files | ProjectStore.swift; ProjectRegistrySalvage.swift; ProjectsViewModel.swift | n/a | OK (Scarf-internal) |

## Not audited / couldn't verify
- I ran no mutating verbs (cron create/run/tick, skills install, plugins install). All verdicts are traced from source plus `--help` probes. The threat-pattern check ran Hermes's `tools/threat_patterns.py` regex table in a scratch Python process against Scarf's rendered static block and the two built-in SKILL.md files. The template-author SKILL.md hits `exfil_curl` in context scope, but skill content is only warn-scanned (`tools/skills_tool.py:560-570`), so it is not blocked.
- "Bundled slash commands": the manifest lists no slash-command resources, only the two BuiltinSkills. Scarf's bundled slash-command files (for example `scarf-cron.md`) were not in scope.
- iOS cron create/edit field parity with `update_job` validation was not re-derived. Prior rounds covered it (P50/P56), and the JSON write path is TRACKED.
- Remote named-profile HERMES_HOME propagation for the transport-run cron and skills verbs belongs to T6 (transport). Every path here comes from the profile-scoped `context.paths`.
- ProjectDoctorService's `userHome` heuristic (`home`'s parent) is `~/.hermes/profiles` for a local named-profile context, so a project directly under `~` makes `~` an orphan-scan root. It is local-only and cheap (≤300 entries). It was not reported because it is Scarf-internal and has no Hermes effect.
