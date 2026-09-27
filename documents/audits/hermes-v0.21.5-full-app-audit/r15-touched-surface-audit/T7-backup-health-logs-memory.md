# T7-backup-health-logs-memory — verdict: WORKS-WITH-ISSUES

Scarf = `/Users/awizemann/Developer/Scarf-wt/integration/scarf/…`; Hermes = `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (0.21.5).

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Backup preflight ($HOME, `hermes --version`, du, registry projects, tool probe) | WORKS | F4 (cosmetic) |
| 2 | Backup run on a remote Linux host whose gateway is running (Stage 2 home tarball, Stage 3 projects) | BROKEN (live host) | F1 |
| 3 | Every-database snapshot ladder (VACUUM INTO → .backup → query_only .backup → python3), root state.db mandatory, others skipped+listed | WORKS | – |
| 4 | Backup exclusions (sidecars, retired-WAL, auth/mcp-tokens/logs per profile, gateway_state.json) | DEGRADED | F2 |
| 5 | Restore inspect: unzip, manifest/schema, SHA-256, target home resolve, holder probe | WORKS | – |
| 6 | Restore run: guarded pre-check → home extract → per-profile cron pause → staged DB publish (holder re-scan in same shell) → projects → registry re-anchor | DEGRADED | F2 (home extract overwrites Hermes install/runtimes) |
| 7 | Mac memory edit (MEMORY.md/USER.md) holding Hermes's `flock` on `<name>.lock` + Scarf's own `.<name>.scarf-lock` | WORKS (local); remote = TRACKED residual | – |
| 8 | iOS Memory reset (`hermes [-p default] memory reset --yes`, output-judged) | WORKS | – |
| 9 | Health: `hermes status` / `hermes doctor` section parsing, doctor completion judge | WORKS | F3 (P3) |
| 10 | Health: version / update-status parse | WORKS | – |
| 11 | Log following: local tail (bounded) + rotation/truncation follow; remote `tail -n 0 -F`; line regex | WORKS (Mac); iOS stream = TRACKED (t-78ced4d2) | – |

## Findings

### T7-F1 · P1 · LIVE · NEW
- Claim: On a remote Linux host (GNU tar) with Hermes running, Server Backup fails, because GNU tar exits 1 ("file changed as we read it") whenever any entry is created/renamed in an archived directory during the tar, and Scarf treats any non-zero stream exit as a fatal backup error.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Services/RemoteBackupService.swift:333-344` (Stage 2 `tar -czf - … -C <parent> <leaf>`, no `--warning=no-file-changed`, no exit-1 tolerance), `:364-370` (projects, same), `:484-490` (any stream error → `BackupError.remoteCommandFailed`); `Transport/SSHTransport.swift:~886-890` (`streamRawBytes` finishes throwing on any `terminationStatus != 0`).
- Hermes @v2026.9.24: `gateway/status.py:743-744` (`_write_json_file` → `utils.atomic_json_write`, mkstemp + `os.replace` in the same dir) for `gateway_state.json` (`:33`) in the home root; on this Mac `gateway_state.json` and `channel_directory.json` in `~/.hermes` were both rewritten at 10:54 and the root's ctime was the current second — i.e. a running gateway churns the home root at least once a minute.
- Failure scenario: user runs Manage Servers → Back Up on a droplet with the gateway up (the normal state; the backup deliberately supports a live gateway via read-only snapshots). Stage 2 streams the home for longer than a minute (always, for a non-root install — see F2's 1-2 GB `hermes-agent/`), the gateway rewrites `gateway_state.json`, GNU tar prints `tar: .hermes: file changed as we read it`, exits 1, and the sheet shows "Remote command failed during backup: …". Retrying hits the same race. Local Mac (bsdtar) is unaffected.
- Evidence (LIVE, `debian:stable-slim`, `--network none`): `tar (GNU tar) 1.35` → `tar: .hermes: file changed as we read it` → `tar exit=1` after one `mv tmp state.json` in the archived root during `tar -czf - -C /h .hermes`.
- Suggested fix: pass `--warning=no-file-changed` (GNU) and accept exit 1 from the tar stages (not exit 2), or stream tar's own status out-of-band and treat 1 as success-with-note.

### T7-F2 · P1 · SOURCE · NEW
- Claim: The Hermes-home tarball includes everything `hermes backup` deliberately leaves out — the Hermes codebase `hermes-agent/` (with its venv and `.git`), `node/`, `runtimes/`, `models/`, `backups/`, `state-snapshots/`, `checkpoints/`, `node_modules`, `.venv`/`venv`/`site-packages`, caches, `browser-profiles/`, `browser-profile/` — and Restore extracts it over the target's home, overwriting the target's installed Hermes code and platform runtimes.
- Scarf: `RemoteBackupService.swift:538-556` (`hermesExcludes`: only DBs, sidecars, retired-WAL, Scarf dirs, gateway_state.json, mcp-tokens/logs/auth); `RemoteRestoreService.swift:1117-1128` (`hermesExtractCommand` excludes only DBs/sidecars/retired-WAL, `--strip-components=1 -C <home>` merge-overwrite); `HermesDatabaseScripts.swift:159-183` (snapshot `find` also walks and snapshots the `*.db` copies under `backups/`, `state-snapshots/`, `hermes-agent/`).
- Hermes @v2026.9.24: `hermes_cli/backup.py:46-70` (`_EXCLUDED_DIRS`: `hermes-agent` "the codebase repo — re-clone instead", `backups`, `state-snapshots` "each holds a full state.db copy", `checkpoints`, `browser-profiles`, `browser-profile` "a credential store that must NOT enter an archive", venvs, caches), `:72-81` + `hermes_constants.py:210` (`models`, `runtimes`, `node` platform downloads), `:108` (`gateway.pid`, `cron.pid`, `.backup.lock`); `scripts/install.sh:188` (default non-root install dir is `~/.hermes/hermes-agent`).
- Failure scenario: (a) non-root install (default on macOS and for non-root Linux users): the backup carries the 1-2 GB repo+venv (1.9 GB on this Mac) plus any local model weights — huge, slow archives that also make F1 near-certain. (b) Restore of that archive onto a target whose user/home differs (the documented `/home/alan` → `/home/ubuntu` re-anchor case) overwrites `~/.hermes/hermes-agent/venv/bin/*` with scripts whose shebangs point at the source's absolute path, so `hermes` fails with "bad interpreter" after a "successful" restore; onto a target at a different Hermes version it silently rolls the install back to the source's files merged over the target's (mixed tree). A Mac→Linux restore overwrites the target's `node/`/`runtimes/` with macOS binaries. (c) `browser-profile/` (real-browser cookies/Login Data) ships even with "Include auth.json" off.
- Evidence: `ls ~/.hermes` shows `hermes-agent`, `backups`, `state-snapshots`, `checkpoints`, `browser-profiles`, `cache`; `du -sh ~/.hermes/hermes-agent` = 1.9G; no Scarf exclusion or extract filter names any of them.
- Suggested fix: mirror `backup.py`'s `_EXCLUDED_DIRS` (root-only `hermes-agent`), `_EXCLUDED_ROOT_DIRS`/`browser_profiles` at root and `profiles/<name>/`, and `_EXCLUDED_NAMES` in `hermesExcludes`, the snapshot `find` prunes, and `hermesExtractCommand` (restore-side too, for older archives).

### T7-F3 · P3 · SOURCE · NEW
- Claim: `hermes doctor`'s numbered remediation list after `Found N issue(s) to address:` is parsed as green passing checks whenever an item has a colon within its first 30 characters.
- Scarf: `scarf/Features/Health/ViewModels/HealthViewModel.swift:747-768` (bare `Key: value` fallback appends `.ok` inside the still-open last `◆` section; only `Run `, `Found `, `Tip:` prefixes are skipped).
- Hermes @v2026.9.24: `hermes_cli/doctor.py:142-163` (`numbered = "  {i}. {issue}"` printed after the last section); issue strings such as `Install daytona SDK: pip install daytona` (doctor_* `_fail_and_issue`), `Reinstall certifi manually: {pip_cmd}`, `Repair the CA bundle: …`, `Install {name}: …`.
- Failure scenario: a host missing an optional package shows the ✗ row in its section AND a ✓ "1. Install httpx" row in the last section; okCount is inflated. The test `HealthDoctorAndAuditHonestyP7eTests.normalRunWithSectionsIsUnchanged` feeds exactly this shape (`1. api key: using env var fallback`) but asserts only the section title.
- Suggested fix: stop parsing checks once the summary head (`Found N issue(s)` / `Fixed N` / `All checks passed!`) or the `─` rule is seen.

### T7-F4 · P3 · LIVE · NEW
- Claim: The backup manifest's `source.hermesVersion` (and the restore target's version) is the whole multi-line `hermes --version` banner, shown as one row in the Backup/Restore sheets.
- Scarf: `RemoteBackupService.swift:152-162`; `RemoteRestoreService.swift:259-265`; shown at `scarf/Features/Servers/Views/BackupServerSheet.swift:92,176`, `RestoreServerSheet.swift:97,106`.
- Hermes @v2026.9.24: `hermes --version` (LIVE) prints 6 lines: version, Install directory, Install method, Python, OpenAI SDK, `Update available: …`.
- Failure scenario: the "Hermes version" row renders six lines including the install path and a stale "Update available" note frozen into the archive. Cosmetic.
- Suggested fix: keep the first line (as `HealthViewModel.load` does, `:271-272`).

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `bash -lc 'echo "$HOME"'` | shell | RemoteBackupService.swift:138-147; RemoteRestoreService.swift:252-258 | – | OK |
| `hermes --version` | argv | RemoteBackupService.swift:152-162; RemoteRestoreService.swift:259-265 | hermes_cli/_startup_fast.py:216-221 | OK (F4 cosmetic) |
| `du -sb` size estimate | shell | RemoteBackupService.swift:721-731 | – | OK (nil on BSD, handled) |
| `~/.hermes/scarf/projects.json` read (preflight) | file | RemoteBackupService.swift:180 | – (Scarf-owned) | OK |
| tool probe (`state.db`, sqlite3, python3, marker) | shell | RemoteBackupService.swift:198-210, 600-615 | – | OK |
| DB snapshot ladder over every `*.db` | shell/SQLite RO | HermesDatabaseScripts.swift:113-183; RemoteBackupService.swift:623-662 | hermes_cli/backup.py:101-104, 332-380, 590-610 | OK (walks excluded dirs: F2) |
| snapshot report parse (`SCARF_DB_*`) | parse | HermesDatabaseScripts.swift:201-217 | – | OK |
| leftover staging sweep | shell | HermesDatabaseScripts.swift:84-91 | – | OK |
| `tar -czf -` home tarball + excludes | shell | RemoteBackupService.swift:329-344, 497-584 | hermes_cli/backup.py:46-128, 270-311 | FINDING-F1, FINDING-F2 |
| per-profile exclusions (`profiles/*/auth.json`, `mcp-tokens`, `gateway_state.json`, named `logs`) | shell | RemoteBackupService.swift:538-584 | hermes_cli/profiles.py:174-177; auth.py:481-482, 679; tools/mcp_oauth.py:229-232 | OK |
| project tarballs | shell | RemoteBackupService.swift:347-380, 682-693 | – | FINDING-F1 (live edits) |
| `/usr/bin/zip` outer archive (timeout, drained) | local proc | RemoteBackupService.swift:755-808 | – | OK |
| `/usr/bin/unzip`, SHA-256 verify | local proc | RemoteRestoreService.swift:1398-1470 | – | OK |
| manifest kind/schema v1–v2 | parse | BackupManifest.swift:94-96; RemoteRestoreService.swift:228-233 | – | OK |
| target Hermes home resolution (`context.paths.home`, `~` expanded) | path | RemoteRestoreService.swift:1097-1103, 302-310 | – | OK |
| holder scan (/proc fd `-lname` incl. `(deleted)`, readlink fallback, lsof, UNKNOWN fails closed) | shell | HermesDatabaseScripts.swift:240-291; RemoteRestoreService.swift:1160-1186 | hermes_cli/backup.py:469-506 | OK |
| home extract `--strip-components=1`, DB/sidecar/retired-WAL excludes | shell | RemoteRestoreService.swift:1117-1128 | hermes_cli/backup.py:946-951 | FINDING-F2 (no install/runtime filter) |
| staged DB publish (chmod 600, rm -wal/-shm/-journal, mv, same-shell holder check) | shell (C3 exception: user-initiated restore swap) | RemoteRestoreService.swift:1197-1251 | hermes_cli/backup.py:536-559 | OK |
| v1 legacy DB lift + local WAL fold (Scarf temp copy only) | local proc | RemoteRestoreService.swift:1272-1345 | – | OK |
| `cron/jobs.json` pause, root + every `profiles/*/` (list, bare list, id-keyed map; enabled/state/paused_at/paused_reason) | file JSON | RemoteRestoreService.swift:891-1011 | cron/jobs.py:55-80, 515-524, 1350-1380, 2067-2077 | OK |
| projects.json re-anchor under RegistryWriteLock | file JSON | RemoteRestoreService.swift:825-872 | – (Scarf-owned) | OK |
| MEMORY.md/USER.md Hermes `flock` on `<name>.lock` (O_RDWR|O_CREAT|O_NOFOLLOW, 0600, LOCK_EX, never unlinked) | lock | RegistryWriteLock.swift:194-223, 329-378 | tools/memory_tool_store.py:166-205 | OK |
| same, remote target | lock | RegistryWriteLock.swift:207-209; GuardedTextFile.swift:141-166 | – | TRACKED (documented residual, S14-F5) |
| guarded text load/write + `.bak` | file | GuardedTextFile.swift:244-343 | – | OK |
| `hermes [-p default] memory reset --yes` + `Memory reset complete.` / `Nothing to reset` | argv/parse | MemoryListView.swift:112-165; HermesCLIOutcome.swift:2289-2345 | hermes_cli/main_agent_cmds.py:20-55 | OK (LIVE `--help`) |
| iOS profile scoping (HERMES_HOME / `-p default`) | env | CitadelServerTransport.swift:806-824; HermesProfileScope.swift:262-264 | – | OK |
| log line regex `ts LEVEL [sid] name: msg` | parse | HermesLogService.swift:308-336 | hermes_logging.py:47, 130 | OK |
| local tail (bounded) + rotation/truncation follow | file | HermesLogService.swift:185-282 | hermes_logging.py:21-35, 241-251 | OK |
| remote `tail -n N` + `tail -n 0 -F` | shell | HermesLogService.swift:97-165 | – | OK (iOS stream stub TRACKED t-78ced4d2) |
| `hermes status` parse (◆ sections, `_row`/`_kv_flag` mid-line marks, `_detail`) | argv/parse | HealthViewModel.swift:226, 677-808 | hermes_cli/status.py:25-52 | OK |
| `hermes doctor` parse + completion judge | argv/parse | HealthViewModel.swift:239, 843-881 | hermes_cli/doctor.py:142-188; doctor_report.py:13-34 | OK (FINDING-F3 P3) |
| `hermes --version` update status | argv/parse | HealthViewModel.swift:1427-1521 | hermes_cli/_startup_fast.py:216-221 | OK (LIVE) |
| `hermes acp --setup-browser --yes` | argv | HealthView.swift:264-286 | acp_adapter/entry.py:151-185; main_agent_cmds.py:75-89 | OK (LIVE `--help`) |
| `security audit --fail-on critical`, `sessions optimize [--force]`, `migrate xai --apply`, `debug share [-y|--local]`, `dump`, gateway start/stop | argv | HealthViewModel.swift:918-1393, 548-660 | (verdict types outside manifest) | OK (callers only; verdicts owned by other sections) |
| `computer-use permissions status --json` | argv/parse | HealthViewModel.swift:246-255, 335-432 | – | OK (gated) |
| Tool Gateway section (config `platform_toolsets`, `auxiliary.*.provider`) | config read | HealthViewModel.swift:434-509 | – | OK |

## Not audited / couldn't verify
- Could not run `hermes status` / `hermes doctor` (brief limits probes to `--help`/`--version`); parsing checked against the printing source only.
- F1 was reproduced with GNU tar 1.35 in a local `debian:stable-slim` container (no network), not against a real droplet; BusyBox tar behaviour not checked.
- `HermesFileService.hermesPID()`, `stopHermes()`, and the CLI verdict types (`HermesGatewayServiceVerdict`, `HermesSessionsOptimizeVerdict`, `HermesDebugShareVerdict`) are outside this manifest; only their call sites were read.
- Stale `gateway.pid`/`processes.json` restored from the source: checked benign (Hermes validates the runtime lock and host start time: gateway/status.py:1910-1936, tools/process_registry_checkpoint.py:46-82), so not reported.
