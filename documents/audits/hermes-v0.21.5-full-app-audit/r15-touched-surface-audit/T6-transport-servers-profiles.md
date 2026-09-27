# T6-transport-servers-profiles — verdict: WORKS-WITH-ISSUES

Worktree: /Users/awizemann/Developer/Scarf-wt/integration @ 8b311060. Hermes ref: ~/.hermes/hermes-agent-v0215 @ v2026.9.24.
All paths below are relative to `scarf/` in the worktree unless they start with `hermes_cli/`, `nix/` or `website/`.

The primary paths work: SSH/Citadel one-shot CLI calls, the PATH fallback, the profile pins, Test Connection, profile list and switching. I also ran the generated command text through local shells. The findings are edge-of-mainstream remote setups plus misleading diagnostics. There are no P0s.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Remote one-shot hermes CLI over SSH (Mac): `ssh host sh -c '<PATH fallback>; COLUMNS=400 [HERMES_HOME=…] "hermes" [-p default] …'` | WORKS (default `~/.hermes` root and named profiles). DEGRADED for a custom root home | F1 |
| 2 | Remote ACP / streaming (Mac `bash -lc`, same composed command) | WORKS / DEGRADED for a custom root | F1 |
| 3 | iOS Citadel exec (`/bin/sh -c '<COLUMNS PATH HERMES_HOME cmd>'`, head -c script pipe) | WORKS (csh newline/`!` limit TRACKED) | F1 (same helper) |
| 4 | Remote file I/O (cat / scp+chmod+mv / stat / statAll / ls / watch) | WORKS; error text wrong on remote permission failures | F3 |
| 5 | Add Server → Test Connection (`ssh -v … /bin/sh -s` probe, hint/PATH/candidates, state.db + alternates) → Save (probed path marked `hermesBinaryHintIsPath`) | WORKS | — |
| 6 | Remote Diagnostics sheet | DEGRADED | F2, F4 |
| 7 | Profiles: list / show / create / rename / delete / export / import (Mac, local + remote) | WORKS | — |
| 8 | Profile switching: local `profile use` + relaunch; remote "View this profile" (window scope) / "Set as server's active profile"; ScarfGo picker | WORKS (cosmetic message on remote) | F5 |
| 9 | App launch: env enricher wiring, warm-up, local bootstraps skipped on test/preview hosts, remote `/scarf-*` bootstrap once per host+home | WORKS | — |
| 10 | HermesCLI runner (`runHermesCLI`/`Split`/`Data`) + generic outcome judge (`HermesCLIVerdict.judge`) | WORKS | — |

## Findings

### T6-F1 · P2 · SOURCE · NEW
- Claim: For a remote Hermes home that is a custom **root** (not `~/.hermes`, not `<root>/profiles/<n>`), Scarf reads files from the configured home. Every hermes CLI/ACP call gets `-p default` but no `HERMES_HOME`, so Hermes resolves the SSH user's `~/.hermes` instead. File views and CLI/chat actions then operate on two different homes.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Models/HermesProfileScope.swift:282-285` (`hermesHomeShellAssignment` returns `""` unless `isProfileHome`). `:237-242` adds only `-p default`. Callers: `Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift:670-697` (runProcess, makeProcess/ACP and streamLines all go through it); `Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift:822-856`; the terminal words at `Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift:410-420`. File layer: `ServerContext.swift:130-137` (`paths.home = config.remoteHome`).
- Scarf actively offers these homes: `scarf/Features/Servers/ViewModels/TestConnectionProbe.swift:343-346` suggests `/var/lib/hermes/.hermes`, `/opt/hermes/.hermes`, `/home/hermes/.hermes` and `/root/.hermes`, and `scarf/Features/Servers/Views/AddServerSheet.swift:194-196` fills them in with "Use this".
- Hermes @v2026.9.24: `hermes_cli/profiles.py:2366-2369` resolves `-p default` to the root from `profile_root_for_env_home(os.environ["HERMES_HOME"], _get_default_hermes_home())` (`:2345-2353`). With `HERMES_HOME` unset, that is `get_default_hermes_root()` → the native `~/.hermes` (`hermes_constants.py:217-234`). Hermes applies the pin in `hermes_cli/main.py:611-644`.
- Failure scenario: The user SSHes in as `ubuntu`, Hermes runs as user `hermes` at `/home/hermes/.hermes`, and the user clicks "Use this" after Test Connection. Sessions, Memory and Dashboard show `/home/hermes/.hermes`. Every CLI action, and remote chat through `bash -lc` too, runs against `/home/ubuntu/.hermes`: Cron "Run now", `config set`, skills, profile list and gateway start/stop. That home is empty or freshly created. Writes "succeed" into the wrong home, and chat starts with no provider configured.
- When it does not bite: the remote exports `HERMES_HOME` to non-interactive shells. NixOS with `addToSystemPackages` does this (`nix/nixosModules.nix:374-379`), or a `~/.hermes` symlink bridge is in place (`website/docs/getting-started/nix-setup.md:707`). That is why this is P2, not P1.
- Why this is a separate gap: the related Restore mis-target (S14-F3) and the accepted 0.6–0.8 Docker `-p default` gap (memory note `hermes-home-resolution-source-verified-v0-16.md:28`) are different issues. Neither covers CLI/ACP on a current host.
- Suggested fix: when `remoteHome` is set and is not a profile home, emit `HERMES_HOME=<root>` together with the existing `-p default`. Hermes then takes the root from the environment (`profiles.py:2367`). The Mac, iOS and Terminal-words builders should all do this.

### T6-F2 · P2 · SOURCE+LIVE · NEW
- Claim: Remote Diagnostics sources the user's `~/.zshenv`, `~/.zprofile`, `~/.bash_profile` and `~/.profile` into the remote `/bin/sh`. On Debian/Ubuntu (dash), one zsh- or bash-only syntax line aborts the whole script. The last four checks then show as FAILED even when sqlite3, hermes and pgrep are fine.
- Scarf: `scarf/Features/Servers/ViewModels/RemoteDiagnosticsViewModel.swift:299-301` (`for rc in … ; do [ -f "$rc" ] && . "$rc" 2>/dev/null; done`). The runner is `/bin/sh -s` (`Packages/ScarfCore/Sources/ScarfCore/Transport/SSHScriptRunner.swift:241-243`). Missing rows are filled as `.fail` "(script exited N before this check …)" at `RemoteDiagnosticsViewModel.swift:392-404`.
- TestConnectionProbe already dropped this pattern for exactly this reason (`TestConnectionProbe.swift:299-306`: "under dash … one line of zsh syntax … ends the whole probe").
- Evidence (LIVE, local dash): a file containing `path=(/opt/x $path)` sourced by `dash -c '… . "$rc" 2>/dev/null; …; echo AFTER'` gives exit 2 and no `AFTER`. Under sh/bash, `AFTER` prints.
- Failure scenario: an Ubuntu host where the user's login shell is zsh and `~/.zprofile` or `~/.zshenv` uses zsh arrays or `typeset`. Diagnostics then report "hermes binary on login PATH", "sqlite3 installed", "sqlite3 can open state.db" and "pgrep available" as FAILED, and the sheet sends the user off to reinstall sqlite3/procps that are already there.
- Suggested fix: borrow the login PATH the way TestConnectionProbe does (`"${SHELL:-/bin/sh}" -lc 'printf "__SCARF_PATH__%s" "$PATH"'`) instead of sourcing rc files into sh.

### T6-F3 · P2 · SOURCE · NEW
- Claim: Remote file operations that fail with a remote **file** permission error are reported as "SSH authentication to <host> failed. Ensure your key is loaded in ssh-agent." The classifier matches "permission denied" in stderr regardless of exit code.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Transport/TransportErrors.swift:137-142`. The callers pass a remote command's own stderr/exit: `SSHTransport.swift:378` (readFile `cat`), `:474` (write `mv`), `:626` (ls), `:636` (mkdir) and `:643` (rm). The message comes from `TransportErrors.swift:58-59`.
- Hermes: N/A (Scarf-side). Real ssh auth failures are exit 255, while `cat`/`mv` permission failures are exit 1 with `cat: …: Permission denied`.
- Failure scenario: a server whose Hermes files are owned by another user (the F1 setups, or a 0600 `auth.json`/`.env`). Opening Memory or Settings, or saving `config.yaml`, shows an ssh-agent/key error. The connection is fine, and every other surface keeps working, so the user chases the wrong problem.
- Suggested fix: classify auth, host-key and unreachable only when `exitCode == 255`. Otherwise treat it as `.commandFailed`, or `.fileIO` for the file verbs.

### T6-F4 · P3 · SOURCE · NEW
- Claim: Remote Diagnostics' two "hermes binary" checks ignore the server's saved Hermes binary (`hermesBinaryHint`). Both FAIL for a working wrapper hint (`docker compose exec hermes hermes`) or for a probed path outside the fallback directories. The failure hint then tells the user to set the path they already set.
- Scarf: `RemoteDiagnosticsViewModel.swift:166` (`buildScript(hermesHome:)` gets only the home), `:292-297` and `:303-313`. The runtime uses the hint via `HermesPathSet.swift:209-212`.

### T6-F5 · P3 · SOURCE · NEW
- Claim: On a remote window, "Set as server's active profile" reports "Active profile set to X — restart Scarf to refresh." A restart changes nothing there, because remote windows are pinned to their viewing profile.
- Scarf: `scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift:113-116`, reached from `scarf/Features/Profiles/Views/ProfilesView.swift:220`.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `-p default` root pin (argv, env-wrapper aware, skips `--version`/existing `-p`) | argv | Models/HermesProfileScope.swift:220-243 | hermes_cli/main.py:484-524, :611-648; profiles.py:2356-2369 | OK |
| `HERMES_HOME=<root>/profiles/<n>` | env | HermesProfileScope.swift:282-285 | main.py:603-605 | OK |
| No `HERMES_HOME` for a custom root | env | HermesProfileScope.swift:283 | profiles.py:2345-2369; hermes_constants.py:217-234 | FINDING-F1 |
| `rootPinShellFragment` for `/bin/sh -c` scripts | argv | HermesProfileScope.swift:262-264 | main.py:484-524 | OK |
| Profile-name validation `^[a-z0-9][a-z0-9_-]{0,63}$` | validation | HermesProfileScope.swift:35-61 | main.py:505-509 (`_PROFILE_NAME_RE`, casefold) | OK |
| `COLUMNS=400` (Mac local, Mac SSH, iOS) | env | LocalTransport.swift:115; SSHTransport.swift:694; CitadelServerTransport.swift:853 | rich Console width | OK |
| PATH fallback `PATH="$PATH"":…"` (sh -c), Terminal `env` words | shell | HermesConfigReader.swift:46-54; SSHTransport.swift:724-727; ServerContext.swift:410-420 | install.sh (cited in source) | OK (LIVE: sh/bash/zsh/dash/ksh/csh/tcsh with a fake hermes, root and named profile) |
| iOS `/bin/sh -c` wrap for csh | shell | CitadelServerTransport.swift:913-915, :280-289 | — | OK. csh newline/`!` args TRACKED (tasks/t-9b5f147f.md:19). LIVE: `!` is fine under `csh -c` |
| Remote cat/scp/mv/chmod/stat/statAll/ls/mkdir/rm/watch | files | SSHTransport.swift:365-645, :1073-1156 | — | OK; error classification FINDING-F3 |
| Probed binary path stays one word (`hermesBinaryHintIsPath`) | config | AddServerViewModel.swift:134-141; HermesPathSet.swift:169-196 | — | OK |
| Test Connection probe (`/bin/sh -s`, login-PATH borrow, candidates, state.db/alternates) | shell | TestConnectionProbe.swift:245-352 | — | OK (csh `-lc` unsupported → falls back to candidates; harmless) |
| Remote Diagnostics script | shell | RemoteDiagnosticsViewModel.swift:166-374 | — | FINDING-F2, F4 |
| `hermes profile list` + table parse | argv/parse | ProfilesViewModel.swift:56; HermesProfileList.swift:67-143; iOS Profiles/ProfilesView.swift:163-179 | hermes_cli/profile_cmd.py:108-127; profiles.py:906-910 | OK |
| `<root>/active_profile` read (remote badge) | file | ProfilesViewModel.swift:397-409; iOS ProfilesView.swift:167 | profiles.py:1909-1915 | OK |
| `profile show -- n` | argv | ProfilesViewModel.swift:92 | subcommands/profile.py:79-80 | OK |
| `profile use -- n` | argv | ProfilesViewModel.swift:110, :137 | profile_cmd.py:151-157 (`_die` exit 1) | OK (message FINDING-F5) |
| `profile create [--clone/--clone-all] [--no-skills] -- n` | argv | ProfilesViewModel.swift:182-195 | subcommands/profile.py:17-44; profile_cmd.py:186-210 | OK |
| `profile rename -- old new` | argv | ProfilesViewModel.swift:203 | profile_cmd.py:433-441; profiles.py:2296-2305 | OK |
| `profile delete -y -- n` (+ settlement-pending verdict) | argv | ProfilesViewModel.swift:224-230 | subcommands/profile.py:48-50 | OK / TRACKED (v0.21.4 verdict, prior remediation) |
| `profile export --output <scratch>.tar.gz -- n` + stream + rm | argv | ProfilesViewModel.swift:248-287; RemoteProfileExport.swift | profile_cmd.py:474-482 | OK |
| `profile import -- path` | argv | ProfilesViewModel.swift:290 | profile_cmd.py:485-497 | OK |
| `runHermesCLI` / `Split` / `Data` (local candidates, remote hint, timeout partial stdout, stdout/stderr separator) | runner | Core/Services/HermesFileService.swift:3486-3610 | — | OK |
| `HermesCLIVerdict.judge` (exit 0 never implies success; unconfirmed vs failed) | judge | Services/HermesCLIOutcome.swift:225-273 | — | OK |
| Login-shell env harvest (PATH, provider keys, SSH_AUTH_SOCK) | env | HermesFileService.swift:3139-3295 | — | OK |
| `hasAnyAICredential` (.env / auth.json incl. root fallback / config keyless) | file | HermesFileService.swift:3312-3405 | main.py:1052-1143 | OK (advisory banner only; Claude Code creds / gh-auth fallbacks not counted, noted not filed) |
| `setModelAndProvider` / `applyModelConfigPlan` (`config set`, judged) | argv | HermesFileService.swift:3431-3483 | (T3 owns HermesConfigSet) | OK |
| pgrep gateway match / `gateway stop` fallback | argv | HermesFileService.swift:2977-3113 | — | Owned by T5/T7 (not re-audited) |
| Remote `/scarf-*` bootstrap `<home>/scarf/slash-commands/*.md` | file (Scarf-owned) | scarfApp.swift:520-522; SlashCommandBootstrapService.swift:121-155 | — | OK |
| Local bootstraps skipped on XCTest/preview hosts | launch | scarfApp.swift:97; Analytics.swift:164-169 | — | OK |
| Enricher wiring for SSHTransport/LocalTransport + off-main warm-up | launch | scarfApp.swift:71-91 | — | OK |
| ControlMaster check/exit/recover, circuit gate | ssh | SSHTransport.swift:139-196, :1181-1286 | — | OK |
| Backup/Restore sheets + BackupServerViewModel | UI | Features/Servers/* | — | Owned by T7 (S14-F1/F2/F3 TRACKED there) |

## Not audited / couldn't verify
- HermesCLIOutcome.swift per-verb verdicts (MCP, gateway, plugins, backup, import, webhooks, auth logout, memory, sessions optimize and others) belong to the sections that own those verbs. I audited only the shared judge/marker machinery and `HermesProfileDeleteVerdict` usage.
- fish login shell: not installed locally. By reading: the single-quoted `sh -c '…'` survives fish, except that a token containing a literal backslash would be unescaped once by fish (`\\`→`\`). This is rare, and I have not filed it.
- iOS `CitadelServerTransport.shellJoin` treats `$` as shell-safe (`:922`), so a single-word argv token containing `$` would be expanded by sh. I found no iOS caller passing such user text, so this is unverified and not filed.
- Mac `SSHTransport.runProcess` (`:729-737`) omits `-T`. This only matters under `RequestTTY force` in ssh_config, because stdin is not a TTY. Not filed.
- I did not run Scarf builds or a live SSH host. The shell behaviour was confirmed by running the generated command text through local `sh`/`bash`/`zsh`/`dash`/`ksh`/`csh`/`tcsh`.
