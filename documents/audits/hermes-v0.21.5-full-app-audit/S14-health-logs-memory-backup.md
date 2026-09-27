# S14-health-logs-memory-backup — verdict: WORKS-WITH-ISSUES

Paths: Scarf = `/Users/awizemann/Developer/Scarf/scarf/…`; Hermes = `~/.hermes/hermes-agent-v0215/…` (tag v2026.9.24, 0.21.5).
Every capability floor this section uses resolves TRUE on 0.21.5 (`hasBackupKeep` 0.21.2, `hasBackupPartialExitNonZero`/`hasSessionsOptimizeForce` 0.21.4, `hasDebugShareYes`/`hasComputerUsePermissionsJSON` 0.18, `hasVersionFlagFullOutput` 0.20.5, `hasHermesAudit`/`hasXAIModelRetirement` 0.15, `isV020OrLater`).

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Health load: `hermes --version` → version string, update status | WORKS | – |
| 2 | Health load: `hermes doctor` sections + completion/exit judgement | WORKS | – |
| 3 | Health load: `hermes status` sections (Status tab + header counts) | DEGRADED | F4 |
| 4 | Health actions: `security audit --fail-on critical`, `sessions optimize [--force]`, `dump`, `debug share [-y/--local]`, `migrate xai --apply` | WORKS | – |
| 5 | HermesCapabilities parse of the current version line / Python discovery | WORKS | – |
| 6 | Logs pane: file locations, line format + session tag, live tail | DEGRADED | F6, F7 |
| 7 | Memory (Mac): load / edit / conflict-checked save of MEMORY.md, USER.md; `memory reset --yes` | DEGRADED (local save) | F5 |
| 8 | Memory (iOS): MEMORY.md / USER.md / SOUL.md editor, reset | WORKS | – |
| 9 | Settings Backup Now (`hermes backup --keep 0`) / Restore (`hermes import --force -- <zip>`) | WORKS | – |
| 10 | Manage Servers → Back Up… (Scarf tar-based `.scarfbackup`) | DEGRADED | F2 |
| 11 | Manage Servers → Restore from Backup… | BROKEN (live host) / DEGRADED (custom home) | F1, F3 |
| 12 | .env service / Keychain env mirror / secrets block | WORKS | – |
| 13 | Power settings writer (`agent.reasoning_overrides`, `model_catalog.excluded_providers`) | WORKS | – |
| 14 | Updater argv builder (`update --check/--yes`) | WORKS (no callers; dead plumbing) | – |

## Findings

### S14-F1 · P1 · SOURCE · NEW
- Claim: Server Restore extracts the backup's `state.db` over the live one with `tar -x`. It never removes the target's `state.db-wal`/`-shm`, and it never checks whether a Hermes process holds the database. This is exactly the corruption / split-brain class Hermes's own `import` defends against.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift:273-281` (push `hermes.tar.gz` into `$HOME`), `:351` (`tar -xzf - -C <target>`); the archive deliberately excludes the WAL/SHM (`RemoteBackupService.swift:424-427`). No sidecar cleanup and no running-Hermes guard anywhere in `run()` (`:234-333`). The sheet shows no "stop Hermes first" warning (`scarf/Features/Servers/Views/RestoreServerSheet.swift:90-156`).
- Hermes @v2026.9.24: `hermes_cli/backup.py:852-866` (`_import_db_member`): "a rename-publish over a live database is the #65942 / #90950 corruption class … a sidecar WAL beside the new file describes the old database — nothing fails, the sessions are simply gone". `:540-559`: Hermes refuses while any process holds the database, and unlinks `-wal/-shm/-journal` before moving the snapshot in: "SQLite would replay that foreign WAL over the restored file: 'malformed' or resurrected post-snapshot rows". `:946-951` skips archived sidecars for the same reason.
- Failure scenario: The user restores onto a host where the gateway is running (the local server included, since Manage Servers offers Restore for Local, `ManageServersView.swift:392-411`). `tar` unlinks and recreates `state.db`. The gateway keeps writing the old inode and its `state.db-wal` path. The next opener pairs the new file with the foreign WAL, which gives "database disk image is malformed" or mixed rows, and sessions the gateway writes afterwards are invisible. The sheet reports success.
- Suggested fix: Before extracting, refuse (or require stopping) when Hermes holds `state.db`, and delete `state.db-wal/-shm/-journal`. Or push the zip and run `hermes import --force`, which already handles the page-safe restore.

### S14-F2 · P2 · SOURCE (torn copy: PLAUSIBLE) · NEW
- Claim: Server Backup copies the live `state.db` with `tar`, excludes the WAL, and records `checkpointedWAL: true` even when the checkpoint did nothing. Its only "quiesce" step is a `sqlite3 … wal_checkpoint(TRUNCATE)` write to `state.db`, which Scarf is not supposed to make.
- Scarf: `RemoteBackupService.swift:231-243`: `cmd = "sqlite3 … 'PRAGMA wal_checkpoint(TRUNCATE);' || true"` and then `checkpointed = (result?.exitCode == 0)`. The `|| true` makes that always true, so manifest `options.checkpointedWAL` (`:320`) is always set. `:424-427` exclude `state.db-wal`/`-shm`. `:245-259` tar the live file.
- Hermes @v2026.9.24: `hermes_cli/backup.py:101-104`: `*.db` is snapshotted via `sqlite3.backup()` because "shipping the live WAL/SHM … would pair a fresh snapshot with stale sidecar" data. Hermes never tars a live database.
- Failure scenario: On a host with an active gateway, the sqlite3 CLI (no busy timeout) gets SQLITE_BUSY. It falls back to a partial checkpoint and still exits 0. Frames left in the WAL are excluded from the archive, so the most recent sessions and messages are missing from the backup. Also, a Hermes autocheckpoint that runs while `tar` reads the file can yield a torn `state.db`. Charter note: the checkpoint is a write to state.db by a non-Hermes process.
- Suggested fix: Snapshot with `sqlite3 -readonly … ".backup /tmp/x"` (or `hermes backup --quick`) and archive the snapshot. Drop the checkpoint, and only record `checkpointedWAL` when it is proven.

### S14-F3 · P2 · SOURCE · NEW
- Claim: Server Restore always extracts to the SSH user's `$HOME/.hermes`. It ignores the server's configured Hermes home (`remoteHome`), which Backup honours. `RestoreOptions.targetHomeOverride` is never set by any caller.
- Scarf: `RemoteRestoreService.swift:246-248` (`targetHome = options.targetHomeOverride ?? inspection.targetHomeResolved /* echo $HOME */ ?? …`), `:279`. The cron pause and registry re-anchor also target `targetHome + "/.hermes"` (`:702`, `:754`). `grep targetHomeOverride` finds only its declaration. Backup, by contrast, reads `context.paths.home` (`RemoteBackupService.swift:151`).
- Hermes: N/A (Scarf-side path logic). Hermes reads `HERMES_HOME` (`tools/memory_tool.py:40`, `hermes_constants`).
- Failure scenario: A server configured with `remoteHome = /var/lib/hermes/.hermes` (one of Scarf's own "Use this" suggestions, `TestConnectionProbe.swift:156`) and SSH user `ubuntu`. Restore writes to `/home/ubuntu/.hermes`, pauses cron and re-anchors there, and reports success. The server's Hermes and every Scarf window keep reading the untouched `/var/lib/hermes/.hermes`. The done view does print the path (`RestoreServerSheet.swift:185`), which is why this is P2 and not P1.
- Suggested fix: Default `targetHome` to the parent of the resolved `context.paths.home`, not `$HOME`.

### S14-F4 · P2 · SOURCE · NEW
- Claim: The Health "Status" tab parser does not match `hermes status`'s current row shapes. Rows whose value is `✗ …` are counted as passing checks, and every `_row` line (Messaging Platforms, API Keys, Auth Providers, API-Key Providers, Nous Tool Gateway) is silently dropped.
- Scarf: `scarf/Features/Health/ViewModels/HealthViewModel.swift:666-735` (`parseOutputStatic`). Only lines starting with `✓ `/`⚠`/`✗ ` get a status. Any other `Key: value` line becomes `.ok` (`:705-731`). Lines with no colon are ignored. Counts come from `computeCounts` (`:840-845`), and card colour from `HealthView.swift:548-556`.
- Hermes @v2026.9.24: `hermes_cli/status.py:35-37` `_row` prints `  {name:<12}  {✓|✗} {text}` (no colon, the glyph is mid-line). `:45-52` `_kv`/`_kv_flag` print `  Label:        ✗ off-text`. Used at `:151` (`.env file:`), `:231` (gateway `Status:` running/stopped), `:336-338` (Deep checks), `:203`/`:214` (platforms `_row`), and `status_auth.py:41,97,140,170,186,202` (`_row`).
- Failure scenario: Gateway stopped → the "Gateway Service" card shows a green "Status" check with detail "✗ stopped" and adds 1 to the OK count. A missing `.env` shows green "✗ not found". The Messaging Platforms / API Keys / Auth Providers cards render with no checks and default to the success colour, so a user with no provider logged in sees nothing red on the Status tab.
- Suggested fix: When a `Key: value` value (or a `_row` remainder) starts with `✓`/`✗`/`⚠`, take the status from that glyph. Also parse `name  ✓|✗ text` rows.

### S14-F5 · P2 · SOURCE · NEW
- Claim: On a local host, Scarf's memory-save lock file has the same path as Hermes's own memory lock (`memories/MEMORY.md.lock`, `USER.md.lock`), but the two use incompatible protocols. Scarf treats Hermes's persistent lock file as "held", deletes it as stale, or fails the save with a misleading "Another Scarf process" error.
- Scarf: `scarf/Core/Services/HermesFileService.swift:284` (`GuardedTextFile(context:)` = locked) → `GuardedTextFile.swift:219` → `RegistryWriteLock.swift:187` (local lock = `<path>.lock`), `:329` (`O_CREAT|O_EXCL`), `:358-370` (`breakIfStale` removes the file once its mtime is more than 30 s old, `:122`), `:130` (2 s acquire timeout). Error text: `Models/ProjectRegistrySalvage.swift:175-176`.
- Hermes @v2026.9.24: `tools/memory_tool_store.py:168-205`. `_file_lock` opens `path.with_suffix(".md.lock")` with `O_RDWR|O_CREAT` and `flock`s it, and never deletes it. So the file persists (on this host: `MEMORY.md.lock`, 0 bytes, mtime Apr 4). `:514-517`: mutation callers hold this lock because "a bare write from an earlier snapshot drops concurrent entries (#119668)".
- Failure scenario: (a) Every Mac memory save finds Hermes's lock file, waits, and deletes it as "stale" (mtime is its creation time, since fchmod does not touch mtime). If a Hermes process holds the flock at that moment, a second Hermes writer gets a fresh inode and the exclusion between Hermes processes is lost. (b) After Scarf deletes it, the agent's next memory write recreates the file with a fresh mtime. A user who saves again within 30 s waits 2 s and gets "Another Scarf process is updating MEMORY.md right now. Nothing was changed". Remote and iOS are unaffected (their lock lives in Application Support).
- Suggested fix: Use a Scarf-specific lock name for these two files (e.g. `.MEMORY.md.scarf-lock`), or take `flock` on Hermes's `.lock` file.

### S14-F6 · P2 · SOURCE · NEW
- Claim: The remote (SSH, Mac) Logs pane shows the last 200 log lines twice.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Services/HermesLogService.swift:97-100`: `openLog` starts `tail -n 200 -F <path>` (`QueryDefaults.logLineLimit` = 200, `HermesConstants.swift:30`), whose first 200 lines go into `remoteTailBuffer`. `:144-153`: `readLastLines` then does a separate `tail -n 500` for the initial list (`LogsViewModel.swift:134-135`, `:146-147`). `:212-217`: the first 2 s poll drains the buffer, which still holds those 200 initial lines, and appends them.
- Hermes: N/A (format and paths match; see inventory).
- Failure scenario: The user opens Logs on an SSH server. After about 2 s the tail of the list repeats the previous 200 entries, and level/component counts and searches see duplicates. The same happens on every log-file switch.
- Suggested fix: Start the follow with `tail -n 0 -F`, or drop the buffered backlog after `readLastLines`.

### S14-F7 · P3 · SOURCE · NEW
- Claim: The local Logs live tail stops silently after Hermes rotates the log.
- Scarf: `HermesLogService.swift:115` holds a `FileHandle` on the path opened once. `:212-222` reads `availableData` from that handle and never re-opens it.
- Hermes @v2026.9.24: `hermes_logging.py:21-35` uses stdlib `RotatingFileHandler` on POSIX (rename-based), `:231` (default 5 MB), `:241-243`.
- Failure scenario: With `agent.log` at 5 MB and the Logs pane open, the rotation renames the file to `agent.log.1`. Scarf keeps reading the renamed inode, so no new lines ever appear, with no indication, until the user switches files or reopens the pane.
- Suggested fix: Poll-stat the path's inode and size, and re-open on change or shrink (or use `tail -F` locally too).

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes --version` (full banner, update line) | argv/parse | HealthViewModel.swift:1358-1450; HermesVersionCache.swift:280-292 | hermes_cli/_startup_fast.py:174-221 | OK (LIVE) |
| Version line `Hermes Agent v0.21.5 (2026.9.24) · upstream …` | parse | HermesCapabilities.swift:2650-2710 | _startup_fast.py:185-189 | OK (LIVE) |
| `Update available…` / `Up to date` / absent (offline) | parse | HealthViewModel.swift:1429-1436 | _startup_fast.py:216-221 | OK |
| bare `hermes version` fallback (pre-0.20.5 only) | argv | HealthViewModel.swift:1384-1389 | n/a on 0.21.5 (not reached: `--version` carries update line) | OK |
| `hermes status` | argv/parse | HealthViewModel.swift:220, :666-735 | hermes_cli/status.py:29-52, status_auth.py | FINDING-F4 |
| `hermes doctor` + summary line + exit code | argv/parse | HealthViewModel.swift:233, :774-812 | hermes_cli/doctor.py:142-188, doctor_report.py:12-35 | OK (LIVE help) |
| Non-TTY colour (ANSI off) | output | parseOutputStatic | hermes_cli/colors.py:7-11 | OK |
| `computer-use permissions status --json` | argv/parse | HealthViewModel.swift:241-249 | (S-other owns JSON parse) | OK |
| `security audit --fail-on critical` 0/1/2 + `Found N …` head | argv/parse | HealthViewModel.swift:986-1070 | hermes_cli/security_audit.py:255-312 | OK (LIVE) |
| `sessions optimize [--force]`, `Optimized N FTS index(es).`, `Error: optimization failed:`, held-store refusal + `PID …` lines | argv/parse | HealthViewModel.swift:1082-1250; HermesCLIOutcome.swift:2285-2350 | hermes_cli/sessions_cmd.py:858-867; hermes_state_holders.py:481-515 | OK (LIVE) |
| `hermes dump` | argv | HealthViewModel.swift:849-875 | dump verb | OK (LIVE) |
| `debug share -y` / `--local` | argv | HealthViewModel.swift:895-972 | debug share parser | OK (LIVE) |
| `migrate xai --apply` + two exit-0 arms | argv/parse | HealthViewModel.swift:1259-1330 | migrate verb | OK (LIVE) |
| Python discovery (shebang / venv sibling) | shell | HermesPythonDiscovery.swift | setup-hermes.sh:391 (symlink → venv shebang python) | OK (note: this host's `~/.local/bin/hermes` is a temporary `#!/bin/sh` test shim with no sibling python, so discovery would fail HERE only; not a standard layout) |
| `~/.hermes/logs/{agent,errors,gateway}.log` | path | HermesPathSet.swift:80-82 | hermes_logging.py:230-243 | OK |
| Log line `ts LEVEL [session] logger: msg` | parse | HermesLogService.swift:249-251 | hermes_logging.py:47, :130 | OK |
| Remote `tail -n 200 -F` + `tail -n 500` | argv | HermesLogService.swift:97-100, :144-153 | – | FINDING-F6 |
| Local tail FileHandle vs rotation | file | HermesLogService.swift:115, :212 | hermes_logging.py:21-35 | FINDING-F7 |
| `$HERMES_HOME/memories/MEMORY.md`, `USER.md` | path | HermesPathSet.swift:67-69; HermesFileService.swift:311-316 | tools/memory_tool.py:38-40; memory_tool_store.py:212 | OK |
| `memories/MEMORY.md.lock` / `USER.md.lock` | lock | RegistryWriteLock.swift:187 | memory_tool_store.py:168-205 | FINDING-F5 |
| Memory "profiles" = subdirs of memories/, `memory.profile` key | config/path | HermesFileService.swift:192-198; HermesConfig+YAML.swift:969 | not read/created by Hermes (config_defaults.py:1289-1303) | OK (dead but harmless: empty by default, picker hidden) |
| `memory.provider`, `memory.memory_char_limit`, `memory.user_char_limit` | config | HermesConfig+YAML.swift:892-893, :966 | config_defaults.py:1296-1302; memory_tool.py:56 | OK (limits not shown in editor; over-limit only warns in Hermes, memory_tool_store.py:158-163) |
| `hermes memory reset --yes` + `Memory reset complete.` / `Nothing to reset` | argv/parse | HermesCLIOutcome.swift:2212-2243; MemoryView.swift:583-620; MemoryListView.swift:94-157 | hermes_cli/main_agent_cmds.py:21-56 | OK (LIVE) |
| iOS reset HERMES_HOME scoping | env | CitadelServerTransport.swift:805-815 | – | OK |
| `$HERMES_HOME/SOUL.md` (iOS editor) | path | HermesPathSet.swift:65 | agent/prompt_builder.py:1545 | OK |
| `hermes backup --keep 0` + complete/incomplete/`Archive kept,`/`No files` | argv/parse | HermesCLIOutcome.swift:2420-2493; SettingsViewModel.swift:1445-1495 | hermes_cli/backup.py:671-760; main.py:2266-2271 | OK (LIVE) |
| `hermes import --force -- <zip>` + `Import complete:` / warnings / shrink | argv/parse | HermesCLIOutcome.swift:2590-2640; SettingsViewModel.swift:1535-1558 | backup.py:993-1040 | OK (LIVE) |
| Server backup: `bash -lc 'echo $HOME'`, `hermes --version`, `du -sb`, `command -v sqlite3` | shell | RemoteBackupService.swift:117-181, :478-489 | – | OK |
| Server backup: `sqlite3 state.db 'PRAGMA wal_checkpoint(TRUNCATE)'` | SQL (write) | RemoteBackupService.swift:231-243 | backup.py:101-104 | FINDING-F2 |
| Server backup: `tar -czf - -C <parent> .hermes` + excludes | shell | RemoteBackupService.swift:245-259, :409-431 | – | FINDING-F2 (live db). Hard-coded `.hermes` basename: a home not named `.hermes` fails LOUDLY (stream throws on non-zero exit, SSHTransport.swift:955-960). Not a finding |
| Server restore: `tar -xzf - -C $HOME` over live state.db | shell | RemoteRestoreService.swift:273-281, :351 | backup.py:540-559, :852-866 | FINDING-F1 |
| Server restore target home | path | RemoteRestoreService.swift:246-248 | – | FINDING-F3 |
| Restore: `cron/jobs.json` `enabled=false` | file/JSON | RemoteRestoreService.swift:753-770 | cron/jobs.py:524, :1335-1376 | OK (enabled always written, jobs.py:1827) |
| Restore: `scarf/projects.json` re-anchor | file | RemoteRestoreService.swift:696-750 | Scarf-owned | OK |
| `.env` read/write (`KEY=value`, quoting, comment-out unset) | file | HermesEnvService.swift | hermes_cli/config.py:2451; agent/secret_scope.py:330-362 | OK |
| `.env` Scarf secrets block `SCARF_<SLUG>_<FIELD>` | file/env | SecretsEnvBlock.swift; KeychainEnvMirror.swift:43-124 | cron/scheduler.py:2333-2341 (reload per job); tools/environments/local.py:243-273 (terminal passes non-blocklisted names) | OK for terminal. Doc nit: execute_code strips non-allowlisted names (tools/code_execution_env.py:25, :76-86), so the mirror comment's "or code_exec" is not true |
| `agent.reasoning_overrides`, `model_catalog.excluded_providers`, reasoning vocab | config | PowerSettingsWriter.swift:266-340 | hermes_constants.py:1300-1323, :1428; config_defaults.py:262; inventory.py:54 | OK |
| `hermes update [--check] [--yes]` | argv | HermesUpdaterCommandBuilder.swift:20-33 | update parser (LIVE) | OK (no callers) |
| BackupManifest schema | Scarf-owned | BackupManifest.swift | – | OK |

## Not audited / couldn't verify
- Did not run `hermes status`, `doctor`, `dump`, backup or restore (brief allows `--help` only). F4's row shapes come from source, not a live capture.
- F2's torn-copy half depends on timing (PLAUSIBLE). The missing-WAL-frames half and the always-true `checkpointed` are SOURCE.
- KeychainEnvMirror under a multiplexing gateway for a routed (non-launch) profile: whether `SCARF_*` names reach that profile's terminal depends on `scoped_passthrough_additions` (tools/env_passthrough.py). Not traced to the end. Works for the launch/default profile.
- `.env` edge syntax (`export KEY=`, inline `# comment` after an unquoted value, a secret value containing `'`, which SecretsEnvBlock writes shell-style as `'\''`) was not checked against Hermes's tokenizer. Only hand-edited or unusual values are affected.
- The Web Dashboard, gateway start/stop and Tool Gateway rows inside HealthViewModel were left to their owning sections.
- Memory editor UX gap (not filed): neither the Mac nor the iOS editor shows `memory_char_limit`/`user_char_limit`. A save over the limit is accepted, and Hermes then silently refuses further agent `memory add` calls (memory_tool_store.py:158-163).
