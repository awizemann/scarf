# S14-health-logs-memory-backup — verdict: WORKS

No P0–P3 findings. Every argv checked with a `--help` probe against the installed 0.21.5. Output markers and paths traced into the v0215 worktree.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Health load: `status` + `doctor` parse, version/update line, computer-use JSON | WORKS | — |
| 2 | Health actions: security audit, sessions optimize (+`--force`), dump, debug share (`-y`/`--local`), migrate xai `--apply`, acp `--setup-browser --yes`, gateway start/stop/restart, dashboard launch | WORKS | — |
| 3 | Version detection + capabilities for 0.21.5 (`hermes --version` parse, cache, inverse/window flags) | WORKS | — |
| 4 | Logs: agent/errors/gateway.log tail, parse, rotation | WORKS | — |
| 5 | Memory (Mac) load/edit/save with conflict check + `memory reset --yes` | WORKS | — |
| 6 | Memory (iOS) MEMORY/USER/SOUL edit/save + reset over SSH | WORKS | — |
| 7 | Server backup / restore (Scarf tar archive; cron pause on restore; db-holder refusal) | WORKS | — |
| 8 | Hermes `backup` / `import --force` (Settings VM, cross-checked) | WORKS | — |
| 9 | .env / Keychain secrets mirror, power settings (reasoning overrides, excluded providers), managed-install marker, updater | WORKS | — |

## Findings
None.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| ScarfCore/Models/BackupManifest.swift | no (archive model) | NO-TOUCHPOINT |
| ScarfCore/Services/HermesCapabilities.swift | yes (`--version` parse, gates) | OK |
| ScarfCore/Services/HermesManagedInstall.swift | yes (`<home>/.managed`) | OK |
| ScarfCore/Services/HermesPythonDiscovery.swift | yes (hermes shebang → python) | OK |
| ScarfCore/Services/HermesUpdaterCommandBuilder.swift | yes (`update --check/--yes`), no callers | OK |
| ScarfCore/Services/HermesVersionCache.swift | yes (`--version`, 10 s timeout) | OK |
| ScarfCore/Services/PowerSettingsWriter.swift | yes (agent.reasoning_effort / reasoning_overrides, model_catalog.excluded_providers) | OK |
| ScarfCore/Services/RemoteBackupService.swift | yes (home tree, excludes, db snapshots, `--version`) | OK |
| ScarfCore/Services/RemoteRestoreService.swift | yes (extract, cron/jobs.json pause, skipped runtime files) | OK |
| ScarfCore/Services/SecretsEnvBlock.swift | yes (.env dotenv syntax) | OK |
| ScarfCore/ViewModels/IOSMemoryViewModel.swift | yes (memories/MEMORY.md, USER.md, SOUL.md) | OK |
| ScarfCore/ViewModels/LogsViewModel.swift | yes (logs/*.log) | OK |
| Scarf iOS/Components/HermesVersionBanner.swift | yes (caps, hidden on 0.21.5) | OK |
| Scarf iOS/Diagnostics/MetricKitSubscriber.swift | no | NO-TOUCHPOINT |
| Scarf iOS/Memory/MemoryEditorView.swift | no (UI over IOSMemoryViewModel) | OK |
| Scarf iOS/Memory/MemoryListView.swift | yes (`memory reset --yes` via sh) | OK |
| scarf/Core/Services/HermesEnvService.swift | yes (.env) | OK |
| scarf/Core/Services/KeychainEnvMirror.swift | yes (.env block) | OK |
| scarf/Core/Services/UpdaterService.swift | no (Sparkle) | NO-TOUCHPOINT |
| scarf/Features/Health/ViewModels/HealthViewModel.swift | yes | OK |
| scarf/Features/Health/Views/HealthView.swift | yes (acp --setup-browser --yes) | OK |
| scarf/Features/Health/Views/HermesCapabilitiesPanel.swift | yes (caps display) | OK |
| scarf/Features/Logs/Views/LogsView.swift | no (UI) | NO-TOUCHPOINT |
| scarf/Features/Memory/ViewModels/MemoryViewModel.swift | yes (memory.provider, memories dir) | OK |
| scarf/Features/Memory/Views/MemoryView.swift | yes (`memory reset --yes`) | OK |
| scarf/Features/Servers/ViewModels/BackupServerViewModel.swift | no (drives service) | OK |
| scarf/Features/Servers/ViewModels/RestoreServerViewModel.swift | no (drives service) | OK |
| scarf/Features/Servers/Views/BackupServerSheet.swift | no (UI) | OK |
| scarf/Features/Servers/Views/RestoreServerSheet.swift | no (UI) | OK |
| scarf/Features/Settings/Views/Tabs/MemoryTab.swift | yes (memory.* keys, auxiliary.background_review.enabled) | OK |
| HermesFileService.swift 227-360 (Memory) | yes (memories/MEMORY.md, USER.md) | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes @v2026.9.24 | Status |
|---|---|---|---|---|
| `status` | argv | HealthViewModel.swift:226 | hermes_cli/status.py:30-52 (◆ / _row / _kv_flag) | OK (LIVE) |
| `doctor` + summary-line completion check | argv/output | HealthViewModel.swift:239,883-921 | doctor.py:148,155,162; doctor_report.py:31-34; check_* :200-207 | OK (LIVE) |
| `computer-use permissions status --json` | argv | HealthViewModel.swift:254 | help probe | OK (LIVE) |
| `--version` / "Update available" / "Up to date" | argv/output | HealthViewModel.swift:1470-1560; HermesVersionCache.swift:292 | installed output `Hermes Agent v0.21.5 (2026.9.24)`, `Update available: …` | OK (LIVE) |
| `security audit --fail-on critical` exit 0/1/2 | argv | HealthViewModel.swift:1095 | security_audit.py:293,301,307,312 | OK (LIVE) |
| `sessions optimize [--force]`, `Optimized N FTS index(es).` / exit-0 `Error: optimization failed:` | argv/output | HealthViewModel.swift:1201 | sessions_cmd.py:858-867 | OK (LIVE) |
| `dump` | argv | HealthViewModel.swift:548 | help probe | OK (LIVE) |
| `debug share -y` / `--local`, `Debug report uploaded:` / `(failed to upload` | argv/output | HealthViewModel.swift:1065-1080 | debug.py:506,510 | OK (LIVE) |
| `migrate xai --apply` two exit-0 arms | argv/output | HealthViewModel.swift:1374,1420 | migrate.py:44-45,74-75 | OK (LIVE) |
| `acp --setup-browser --yes` | argv | HealthView.swift:272 | acp_adapter/entry.py:151-184; main_agent_cmds.py:71-81 | OK (LIVE) |
| `gateway start/stop` | argv | HealthViewModel.swift:644 | (owned by gateway section) | OK |
| `dashboard --no-open --port` | argv | HealthViewModel.swift:1629 | help probe | OK (LIVE) |
| `memory reset --yes`, `Memory reset complete.` / `Nothing to reset` | argv/output | MemoryView.swift:589; MemoryListView.swift:116; HermesCLIOutcome.swift:2384-2407 | main_agent_cmds.py:21-55 | OK (LIVE) |
| `<home>/memories/{MEMORY,USER}.md` | file | HermesFileService.swift:355-360; HermesPathSet.swift:73-75 | tools/memory_tool.py:38-40; memory_tool_store.py:212 | OK |
| `<home>/SOUL.md` | file | IOSMemoryViewModel (paths.soulMD) | agent/prompt_builder.py:82-87 | OK |
| memory.memory_enabled/user_profile_enabled/memory_char_limit/user_char_limit/nudge_interval/provider | config | SettingsViewModel.swift:939-955 via MemoryTab | config_defaults.py:1289-1302 | OK |
| auxiliary.background_review.enabled | config | SettingsViewModel.swift:1016 | config_defaults.py:789 | OK |
| memory.profile (read-only display) | config | HermesConfig+YAML.swift:979 | not a Hermes key; row only shows when set | OK (harmless) |
| logs/agent.log, errors.log, gateway.log + line format | file | HermesPathSet.swift:86-88; HermesLogService.swift:308-310 | hermes_logging.py:47,241-243,130 | OK |
| agent.reasoning_overrides, model_catalog.excluded_providers, reasoning_effort vocabulary | config | PowerSettingsWriter.swift | config_defaults.py:262; config.py:3292; hermes_constants.py:1300,1428 | OK |
| `.env` dotenv syntax (quoting, `${:-$}` escape) | file | SecretsEnvBlock.swift; HermesEnvService.swift | hermes_cli/env_loader.py:265-284 (python-dotenv parser) | OK |
| `<home>/.managed` marker values | file | HermesManagedInstall.swift | hermes_constants.py:1092-1112 | OK |
| `backup [--keep 0]`, `Backup complete/incomplete:`, `Archive kept, but`, `No files to back up.` | argv/output | HermesCLIOutcome.swift:2560-2640 (called from SettingsViewModel.swift:1488) | backup.py:671-760 | OK (LIVE) |
| `import --force -- <zip>`, `Import complete:` | argv/output | HermesCLIOutcome.swift:2764 (SettingsViewModel.swift:1578) | backup.py:993-1033 | OK (LIVE) |
| backup excludes (dirs/names/root runtime dirs/cache kept subdirs) | file tree | RemoteBackupService.swift:695-790 | backup.py:52-118 | OK |
| cron pause on restore (`enabled/state/paused_at/paused_reason`) | file | RemoteRestoreService.swift:996-1055 | cron/jobs.py:515-524,2067-2077 | OK |
| `update --check/--yes` (builder has no callers) | argv | HermesUpdaterCommandBuilder.swift | help probe | OK (LIVE) |

## Not audited / couldn't verify
- The ~3,200 lines of individual capability floors in HermesCapabilities.swift. I checked the parser, the inverse flags and the window flags for 0.21.5. Per-feature floors belong to their feature sections, and floors below 0.21.5 are out of scope.
- Hermes backup/import runs from SettingsViewModel, which is not in this manifest. I cross-checked the verdict strings only.
- Memory saves take Scarf's own lock, not Hermes's `MEMORY.md.lock` (memory_tool_store.py:168-173). The two only race if the agent writes memory during a user save. That is a rare race, so it is out of scope.
- HermesUpdaterCommandBuilder has no callers. That is hygiene only and nothing users can see.
- Memory "profiles" are subdirectories of `memories/` plus a `memory.profile` key. Hermes does not have this concept, so on a normal host the list is empty and the UI stays hidden.
- No live runs of mutating verbs. Only `--help` probes were used.
