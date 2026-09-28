# S14-health-logs-memory-backup — verdict: WORKS-WITH-ISSUES

Health, version detection, the backup and restore verbs, and the Mac Memory editor all check out against v2026.9.24 (0.21.5). Every argv parses at the tag and every verb is judged by its output where Hermes exits 0 on failure. I found three real defects:
- Python discovery fails on the launcher that the tagged `install.sh` writes, so Hermes Voice TTS and Live Voice cannot start on a fresh official install.
- The iOS memory editor saves last-write-wins, with no baseline conflict check.
- The Logs component filter uses prefixes that do not match Hermes's logger names.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Health load: `status` + `doctor` parse, doctor completion/crash detection | WORKS | — |
| 2 | Version detection (`--version` probe, `HermesCapabilities.parse` of the current line, update-status line) | WORKS | — |
| 3 | Security audit (`security audit --fail-on critical`, 0/1/2 exit contract) | WORKS | — |
| 4 | Sessions optimize (+ v0.21.4 held-store refusal, `--force`) | WORKS | — |
| 5 | Dump / debug share (`-y`, `--local`) / migrate xai / acp --setup-browser | WORKS | — |
| 6 | Python discovery (Hermes Voice TTS, Live Voice) | BROKEN on fresh `install.sh` installs | F1 |
| 7 | Logs: file locations, line format, session tag, rotation, remote tail | WORKS (component filter DEGRADED) | F3 |
| 8 | Memory (Mac): load/save MEMORY.md/USER.md, conflict check, `memory reset --yes` | WORKS | — |
| 9 | Memory (iOS): load/save, reset | DEGRADED | F2 |
| 10 | `hermes backup --keep 0` / `hermes import --force` verdicts | WORKS | — |
| 11 | Scarf server backup / restore (.scarfbackup, remote tar, read-only state.db snapshot, holder probe) | WORKS (skim-level, see below) | — |
| 12 | .env service / Keychain mirror / secrets block / managed-install probe / power settings keys | WORKS | — |
| 13 | Updater argv builder | WORKS (dormant, no production caller) | — |

## Findings

### S14-F1 · P1 · SOURCE (+ local shell simulation) · NEW
- **Claim:** `HermesPythonDiscovery` cannot find the interpreter behind the `hermes` launcher that the tagged `install.sh` writes. As a result, Hermes Voice TTS and Live Voice fail with "no Python interpreter found" on a fresh official install, on both local and remote hosts.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesPythonDiscovery.swift:23-59`. It is used by `HermesSpeechService.swift:512` and `VoiceLive/VoiceLiveHostExchange.swift:177`. `hermesBinary` resolves to `~/.local/bin/hermes` first (`Models/HermesPathSet.swift:148-151,209-217`).
- **Hermes @v2026.9.24:** `scripts/install.sh:2153-2170` does `rm -f "$command_link_dir/hermes"` and then writes a regular-file launcher:
  - Content: `#!/usr/bin/env bash` / `unset PYTHONPATH` / `exec "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/hermes" "$@"`.
  - The non-venv arm is the same, with `exec "$HERMES_BIN"`.
  - `command_link_dir` is `~/.local/bin` (`install.sh:487-494`) and `USE_VENV=true` by default (`:71`).
  - The comment at `:2152-2154` says older installs used a symlink, which is the only launcher shape the discovery handles.
- **Failure scenario:** the user installs Hermes with the official installer and plays a message with Hermes Voice, or starts Live Voice.
  1. `readlink -f` returns the launcher itself, because it is not a symlink.
  2. The shebang candidate is `/usr/bin/env`, whose basename `env` is not `python*`.
  3. The sibling search looks in `~/.local/bin` and finds no `python`/`python3` there.
  4. The script exits 3 with `<marker> no Python interpreter found for …/.local/bin/hermes`.

  The feature fails honestly, with an error rather than a false success, but it never works on this layout. pipx/uv-tool symlink layouts and pre-change symlink installs still work.
- **Evidence:** I rebuilt the tagged launcher in the scratchpad and ran the discovery fragment verbatim. Output: `ERR no Python interpreter found for …/s14sim/bin/hermes`, `exit=3`. The existing test `findsSiblingPythonThroughASymlinkedShWrapper` (`Tests/ScarfCoreTests/HermesPythonDiscoveryTests.swift:146-158`) covers only the symlink shape.
- **Suggested fix:** when the launcher is a shell script, parse its `exec "<path>/python…"` line, or fall back to `<dir of $2 in exec>/venv/bin/python`. Alternatively, resolve the interpreter with `hermes`'s own Python, e.g. `hermes -c`-free: `"$(dirname "$(sed -n 's/^exec "\(.*python[0-9.]*\)".*/\1/p' "$real")")"`.
- **Severity note:** Voice is a secondary feature. I graded it P1 because it is fully broken on the mainstream fresh-install layout, not merely wrong. Downgrade to P2 if Voice is not treated as primary.

### S14-F2 · P2 · SOURCE · NEW
- **Claim:** the iOS memory editor's Save overwrites `MEMORY.md`/`USER.md` without checking against the text the editor loaded. A memory entry the agent writes while the editor is open (for example from a gateway conversation) is silently discarded. The Mac editor guards against exactly this case.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/IOSMemoryViewModel.swift:190-191` calls `file.mutate(path) { _ in snapshot }`, which ignores the loaded bytes. `originalText` (`:80`) is never compared.
  - Contrast the Mac path: `scarf/scarf/Core/Services/HermesFileService.swift:321-326` compares `loaded.text != baseline` and returns `.conflict`, and `MemoryViewModel.swift:146-154` names blind last-write-wins as the bug it prevents.
- **Hermes @v2026.9.24:** the agent mutates these files independently:
  - `tools/memory_tool_store.py:168-202` takes a `.lock` file flock, and `:526` writes with `atomic_write_text`.
  - The directory is `get_hermes_home()/memories` (`tools/memory_tool.py:38-40`).
  - Scarf's `RegistryWriteLock` is process-local and does not interlock with that flock.
- **Failure scenario:**
  1. On iPhone, the user opens USER.md and starts editing.
  2. Meanwhile a Telegram turn runs `memory(action=add, target=user)`, and Hermes writes the new entry.
  3. The user taps Save.

  iOS reports success. The file now holds the user's buffer, the agent's new entry is gone, and nothing tells the user.
- **Evidence:** iOS `save()` has no baseline parameter. The Mac `saveMemoryFile(_:target:profile:ifMatches:)` exists but iOS cannot reach it, because it lives in the Mac target.
- **Suggested fix:** inside the same `mutate` hold, return `nil` and surface a reload-or-overwrite prompt when `loaded.text != originalText`, mirroring the Mac `.conflict` path.

### S14-F3 · P3 · SOURCE · NEW
- **Claim:** the Logs pane's component filter matches logger-name prefixes that differ from Hermes's own component map. **CLI** shows almost nothing, **Agent** misses the main agent loop, and **Messaging Gateway** misses platform-plugin lines.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/LogsViewModel.swift` defines `LogComponent.loggerPrefix` as `cli` / `agent` / `gateway` / `tools` / `cron`, and the filter is `entry.logger.hasPrefix(prefix)` in `recomputeFilteredEntries`.
- **Hermes @v2026.9.24:** `hermes_logging.py:159-169` defines `COMPONENT_PREFIXES`:
  - `cli`: `("hermes_cli", "cli")`
  - `agent`: `("agent", "run_agent", "model_tools", "batch_runner")`
  - `gateway`: `("gateway", "hermes_plugins", "plugins.platforms")`
- **Failure scenario:** the user picks "CLI" and sees an almost empty list. On this Mac, 13,543 of about 14,900 `agent.log` lines use a `hermes_cli.*` logger, and `"hermes_cli".hasPrefix("cli")` is false. Picking "Agent" drops every `run_agent` and `model_tools` line.
- **Evidence:** I counted logger roots in local `agent.log` + `agent.log.1`: `hermes_cli` 13543, `gateway` 1184, `hermes_state` 156, `plugins` 31. No logger starts with `cli`.
- **Suggested fix:** make `loggerPrefix` a list that mirrors `COMPONENT_PREFIXES`, and match on dotted-segment boundaries.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes status` + `◆`/`✓✗⚠` parse, mid-line `_row`/`_kv_flag` | argv/output | HealthViewModel.swift:226, 677-810 | hermes_cli/status.py:25-52, 351; colors.py:7-11 (no ANSI off-TTY) | OK |
| `hermes doctor` + summary-line completion check, exit 1 = findings | argv/output | HealthViewModel.swift:239, 883-930 | hermes_cli/doctor.py:142-188; doctor_report.py:12-34 | OK |
| `hermes --version` probe (10 s, exit 0 required) | argv | HermesVersionCache.swift:282-299 | hermes_cli/_startup_fast.py:174-225 | OK (LIVE) |
| `HermesCapabilities.parse` of `Hermes Agent v0.21.5 (2026.9.24) · upstream d0288be5` | parse | HermesCapabilities.swift:2788-2860 | hermes_cli/_startup_fast.py:183-188 | OK (LIVE) |
| Update-status lines (`Update available…` ×2 shapes / `Up to date` / none) | parse | HealthViewModel.swift:1537-1560 | _startup_fast.py:215-221; banner.py:380-425 | OK (LIVE) |
| Bare `version` fallback (only if `--version` unparseable) | argv | HealthViewModel.swift:1493-1497 | — (no verb at 0.21.5) | OK (unreachable on a working 0.21.5 host) |
| `security audit --fail-on critical` 0/1/2 | argv/exit | HealthViewModel.swift:1095-1165 | security_audit.py:286-312; main.py:2228-2238 | OK (LIVE) |
| `sessions optimize [--force]`, `Optimized `/`Error: optimization failed:`/held-store refusal | argv/output | HermesCLIOutcome.swift:2383-2460; HealthViewModel.swift:1180-1240 | sessions_cmd.py:858-867, 1025-1057; hermes_state_holders.py:481-515 | OK (LIVE) |
| `dump` (exit code) | argv | HealthViewModel.swift:967-974 | hermes dump --help | OK (LIVE) |
| `debug share [-y|--local]` | argv/output | HealthViewModel.swift:1004-1080; HermesCLIOutcome.swift:2951-2980 | debug.py:465-510 | OK (LIVE) |
| `migrate xai --apply` | argv/output | HealthViewModel.swift:1368-1432 | hermes migrate xai --help | OK (LIVE) |
| `acp --setup-browser --yes` | argv/exit | HealthView.swift:264-287 | acp_adapter/entry.py:151-184; main_agent_cmds.py:71-86 | OK (LIVE) |
| `computer-use permissions status --json` (stdout only) | argv | HealthViewModel.swift:249-255 | help probe | OK (LIVE) |
| `gateway start/stop` from Health | argv | HealthViewModel.swift:640-648 | (S07) | OK (owned by S07) |
| `pgrep -f` gateway PID | process | HermesFileService.swift:3022-3057 | (S07) | OK (owned by S07) |
| Tool Gateway section: `platform_toolsets`, `auxiliary.*.provider` | config read | HealthViewModel.swift:441-503 | (S05/S06) | OK |
| Python discovery shell fragment | shell | HermesPythonDiscovery.swift:23-59 | scripts/install.sh:2153-2170 | FINDING-F1 |
| `memories/MEMORY.md`, `memories/USER.md` (Mac load/save, conflict check) | file | HermesFileService.swift:229-355 | tools/memory_tool.py:38-40; memory_tool_store.py:23,212,526 | OK |
| `memory.provider`, `memory.memory_char_limit`/`user_char_limit` reads | config | HermesConfig+YAML.swift:891-893, 966 | config_defaults.py:1289-1302 | OK |
| `memory.profile` + `memories/<subdir>/` "profiles" | config/file | HermesConfig+YAML.swift:969; HermesFileService.swift:229-235, 350-355 | not read by Hermes (memory is flat per HERMES_HOME) | OK (harmless legacy: empty on real homes) |
| `memory reset --yes` (Mac + iOS), `Memory reset complete.` / `Nothing to reset` | argv/output | MemoryView.swift:583-620; MemoryListView.swift:113-160; HermesCLIOutcome.swift:2323-2380 | main_agent_cmds.py:21-56 | OK (LIVE) |
| iOS MEMORY.md/USER.md/SOUL.md read + save | file | IOSMemoryViewModel.swift:65-69, 112-205; HermesPathSet.swift:71-75 | memory_tool.py:38-40; agent/prompt_builder.py:1545 | FINDING-F2 |
| `logs/agent.log`, `errors.log`, `gateway.log` paths | file | HermesPathSet.swift:86-88 | hermes_logging.py:218-253 | OK |
| Log line regex (`asctime LEVEL [sid] name: msg`) | parse | HermesLogService.swift:305-335 | hermes_logging.py:47, 117-130 | OK |
| Local rotation follow / remote `tail -n 0 -F` | file | HermesLogService.swift:126-127, 218-280 | hermes_logging.py:241-253 (RotatingFileHandler) | OK |
| Log component filter prefixes | parse | LogsViewModel.swift (`LogComponent.loggerPrefix`) | hermes_logging.py:159-169 | FINDING-F3 |
| `backup --keep 0` + complete/incomplete/`Archive kept`/nothing arms (exit 1 on partial) | argv/output | HermesCLIOutcome.swift:2555-2620; SettingsViewModel.swift:1458-1505 | backup.py:668-760; main.py cmd_backup (`raise SystemExit(1)`) | OK (LIVE) |
| `import --force -- <zip>` | argv | HermesCLIOutcome.swift:2705-2707; SettingsViewModel.swift:1547-1570 | backup.py:997-1052 | OK (LIVE) |
| Scarf server backup: remote `tar -czf -`, excludes, read-only `sqlite3 .backup` snapshot | shell/SQL | RemoteBackupService.swift:190-350, 521-660 | backup.py:84-93 (excluded roots) | OK (skim) |
| Scarf server restore: holder probe (/proc, lsof), guarded db publish, `tar -x` | shell | RemoteRestoreService.swift:250-300, 1136-1370 | backup.py:1024-1037 (parity) | OK (skim) |
| Restore target `hermes --version` (display only) | argv | RemoteRestoreService.swift:264-268 | — | OK |
| `.env` read/write (KEY=value, dotenv quoting) | file | HermesEnvService.swift (whole) | hermes_cli/env_loader.py:17, 265-290 (python-dotenv) | OK |
| `SCARF_<SLUG>_<FIELD>` secrets block in `.env` | file | SecretsEnvBlock.swift; KeychainEnvMirror.swift:48-124, 273-290 | env_loader.py:47 (per-cron-fire reload) | OK |
| `$HERMES_HOME/.managed` marker probe | file | HermesManagedInstall.swift:88-107 | hermes_constants.py:1080-1110 | OK (note: `_MANAGED_FALSE_VALUES` {"false","0","no","off"} in the marker file is not mirrored; exotic, not reported) |
| `agent.reasoning_overrides`, `model_catalog.excluded_providers` direct-YAML writes | config write | PowerSettingsWriter.swift:313-452 | hermes_constants.py:1404-1428; hermes_cli/inventory.py:54; config_defaults.py:262 | OK |
| `update [--check] [--yes]` | argv | HermesUpdaterCommandBuilder.swift:21-33 | `hermes update --help` | OK (no production caller) |
| Capability floors used here (`hasBackupKeep`, `hasBackupPartialExitNonZero`, `hasSessionsOptimizeForce`, `hasDebugShareYes`, `hasVersionFlagFullOutput`, `hasComputerUsePermissionsJSON`) at 0.21.5 | gate | HermesCapabilities.swift | — | OK (all true at 0.21.5) |
| BackupManifest model | model | BackupManifest.swift | — (Scarf-owned format) | OK |
| HermesCapabilitiesPanel (display of the version line) | UI | HermesCapabilitiesPanel.swift | — | OK |

## Not audited / couldn't verify
- **Scarf server backup and restore.** I audited `RemoteBackupService` and `RemoteRestoreService` (about 2,700 lines) at skim level only. I checked the argv/shell shapes, the read-only state.db snapshot, the holder probe and the timeouts. I did not re-derive every tar-exclude anchor or every restore publish step by hand. Both files carry extensive prior tag-cited work.
- **Profile scoping of `runHermes`** (`-p default` / `HERMES_HOME`) for Health and Memory reset on named profiles. That belongs to S13/S15; I only confirmed that the iOS reset script pins a root home.
- **Memory write race with Hermes's `.lock` flock on Mac.** Scarf does not take Hermes's `MEMORY.md.lock`. The Mac content-baseline check narrows the window to milliseconds, so I did not report it.
- **Doctor `--live`, the `status --deep` section, and a real OSV run.** I did not execute these (network/mutating risk). Verified from source only.
- **Logs ownership.** No section manifest lists `LogsViewModel`, `HermesLogService` or `LogsView`. I audited them here because the section focus names logs.
