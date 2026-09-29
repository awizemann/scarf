# S15-servers-transport-ios — verdict: WORKS

The plumbing works against Hermes 0.21.5 (tag v2026.9.24), locally and over SSH, on both the default profile and named profiles. I found one real defect. It is small and rare (P3, iOS quoting). Everything else traced clean. The two repo scripts that touch Hermes pass against the tag.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Add server (Mac): form → Test Connection → Save (`AddServerViewModel`, `TestConnectionProbe`, `ServerRegistry.addServer`) | WORKS | — |
| 2 | Remove server (Mac): ControlMaster exit off-main, gate reset, snapshot prune, home-cache invalidate | WORKS | — |
| 3 | Test Connection: `ssh … /bin/sh -s` with the script on stdin; finds hermes via the saved override, then the login-shell PATH, then the install candidates; checks `state.db` and suggests alternate homes | WORKS | — |
| 4 | Remote Diagnostics: 14 probes via `SSHScriptRunner`, pipe-framed parse, missing rows filled in | WORKS | — |
| 5 | Finding hermes and HERMES_HOME. Local: candidates, then the harvested login PATH, off-main (C10). Remote: `PATH` fallback + `HERMES_HOME=` for any home that isn't the root, `-p default` for the root | WORKS | — |
| 6 | Running commands (`runHermesCLI`, `…Split`, `…Data`): quoting (`remotePathArg`), `COLUMNS=400`, timeouts, partial stdout kept on timeout, stdout/stderr joined with a separator, shared judge `HermesCLIVerdict.judge` (exit 0 with no success line is never a success) | WORKS | — |
| 7 | Remote file read/write: `cat`; scp to a per-write-unique temp, then chmod-then-`mv`; mkdir -p retry; 0600 for `.env`/`auth.json` | WORKS | — |
| 8 | File watcher: local vnode watch with re-arm on delete; remote polls `stat` every 3 s with a caller-owned baseline | WORKS | — |
| 9 | Connection status pill: 15 s probe, degraded causes (no-home / missing / perm / profile-active), 2-strike error | WORKS | — |
| 10 | App launch (C10): login-shell env probe warmed on a detached task; `hermesBinaryPath` never waits on it on main | WORKS | — |
| 11 | iOS onboarding: key generate/import → Keychain → Citadel `echo scarf-ok` probe → config saved | WORKS | — |
| 12 | iOS Citadel transport: exec with PATH/`HERMES_HOME`/`-p default`; SFTP read/atomic write; pool per context id; profile scoping via `remoteHome` | WORKS (one quoting defect) | S15-F1 |
| 13 | iOS notifications: APNs is gated off (`apnsEnabled = false`); Hermes has no push sender | WORKS (by design inert) | — |

## Findings

### S15-F1 · P3 · SOURCE · NEW (acknowledged "seen, not fixed" in `.memory/architecture/remote-hermes-resolution-appended-install-dir-path-wrapper.md:25`, no task)
- **Claim:** On iOS, a hermes argv word that has no spaces but contains `$` reaches the remote shell unquoted, so the shell expands it and the argument arrives corrupted.
- **Scarf:**
  - `scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift:940-946`: `shellJoin` counts `$` as a "safe" character.
  - `:900-905`: `commandLine` runs every non-`~` token through `shellJoin`.
  - `:852-857`: the result is then run by `/bin/sh -c`.
  - The Mac equivalent, `SSHTransport.remotePathArg` (`SSHTransport.swift:189-208`), escapes `$` correctly.
- **Hermes @v2026.9.24:** n/a. Hermes receives an argv that has already been altered by the shell.
- **Failure scenario:** any iOS call that uses `transport.runProcess(executable: hermes, args: [..., "Cost$5"])` or passes a single-word value like `$FOO`. The remote `sh` expands `$5` / `$FOO` to empty, and Hermes stores a different value than the one the user typed.
  - Words with spaces are single-quoted, so they are safe.
  - The iOS `config set` paths (`IOSSettingsViewModel.swift:203`, `ChatView.swift:1971`) do their own escaping, so they are also safe.
  - Impact is limited to single-word user values containing `$` on direct hermes argv, which is rare.
- **Evidence:** `let safe = CharacterSet(charactersIn: "…0123456789@%+=:,./-_$")`.
- **Suggested fix:** drop `$` from `shellJoin`'s safe set. `~` tokens already go through `homeRelativeWord`.

### Checked and dropped
- **Watcher never arms core paths that are absent at launch** (`HermesFileWatcher.startWatching`). This is deliberate per the watcher memory note ("Deliberately NOT seeded from `startWatching`"). In practice `agent.log` and the periodic WAL checkpoint (`hermes_state.py:491,1012`: every 50 writes) keep the ticks coming.
- **`runLocal` sets `terminationHandler` after `run()`** (`SSHTransport.swift`). In theory the handler could be missed. In practice the ssh process exits milliseconds later while the handler is set microseconds after launch, so this does not happen.
- **iOS pool contention between the base context and a profile-scoped context that share `serverID`** (`ScarfGoTabRoot.swift:68` vs `:126`). The contexts only meet on the capability probe, which is cached. Plausible at most; not reported.
- **Citadel `hostKeyValidator: .acceptAnything()`.** TRACKED: `tasks/t-5ca5eae5.md`, `tasks/t-93ddfdc4.md`, `.memory/decisions/section-audit-remediation-2026-09.md`.

## Hermes-side verifications
- The profile dir `<root>/profiles/<name>` and `active_profile` match `hermes_cli/profiles.py:177,187-188`.
- `HERMES_HOME=<root>/profiles/x` is trusted without reading `active_profile` (`hermes_cli/main.py:603-605`). This is why the remote `HERMES_HOME` assignment is correct.
- The install locations `~/.local/bin` and `/usr/local/bin` (root/FHS) match `scripts/install.sh:487-503`. Both are covered by `HermesConfigReader.pathFallback` and by the Test Connection candidates.
- `hermes config set [--force] key value` is LIVE-probed. The success lines `✓ Set {key} in …` / `✓ Set {key} = … in …` are at `hermes_cli/config.py:3503,3593`. The managed refusal returns exit 0 (`:3486-3488`), and `HermesConfigSet` (`failureWins`, anchored) handles it. This covers `setModelAndProvider` and `applyModelConfigPlan` in the range I own.
- The gateway process shapes `python -m hermes_cli.main [--profile X] gateway run --replace` (`hermes_cli/gateway_launchd.py:211-212`) and `hermes [-p X] gateway run --replace` (`service_manager.py:467-469`) both match `HermesGatewayProcessMatch.pgrepPattern`.
- Log files `agent.log`, `errors.log` and `gateway.log` exist (`hermes_logging.py:241-242`). So do `skills/.curator_state` (`agent/curator.py:37`), `skills/.usage.json` (`tools/skill_usage.py:1`), `skill-bundles` (`agent/skill_bundles.py:30`) and `cron/jobs.json` (`hermes_cli/dump.py:97`). Every one matches `HermesPathSet`.
- `hermes profile use <name|default>` exists (LIVE). This is the command the degraded pill suggests.
- Scripts:
  - `check-hermes-tables.py` targets `v2026.9.24`. Run read-only against the tag: `OK … lanes=8/8`, with only deliberate WARNs.
  - Every verb and flag in the `ui-fixture/make-ui-fixture.sh` verify pass is LIVE-probed OK: sessions list, cron create/pause/list (`--name`, `--deliver`, `--all`), kanban init/create/block/claim/request-review/list (`--body`, `--initial-status`, `--force`, `--session`), project create/list (`--description`), skills repair-official/list (`--restore`, `--yes`), and the root `-z PROMPT`.
  - `resolve_runtime_provider` exists at the tag (`hermes_cli/runtime_provider.py:975`) for `probe-hermes-routable-bands.py`.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| Packages/ScarfCore/.../Models/HermesConstants.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Models/HermesPathSet.swift | yes | OK |
| Packages/ScarfCore/.../Models/OffPool.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Models/ServerContext.swift | yes | OK |
| Packages/ScarfCore/.../Security/IOSServerConfig.swift | yes (remoteHome/hint) | OK |
| Packages/ScarfCore/.../Security/OnboardingState.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Security/OnboardingViewModel.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Security/SSHConnectionTester.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Security/SSHKey.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Services/HermesCLIOutcome.swift | yes | OK. I audited the shared judge core and `HermesConfigSet`. The verb-specific verdicts belong to their feature sections. |
| Packages/ScarfCore/.../Transport/LocalTransport.swift | yes (env, COLUMNS) | OK |
| Packages/ScarfCore/.../Transport/SSHConnectionGate.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Transport/SSHScriptRunner.swift | no (script host) | OK |
| Packages/ScarfCore/.../Transport/SSHTransport.swift | yes | OK |
| Packages/ScarfCore/.../Transport/ServerTransport.swift | yes (protocol) | OK |
| Packages/ScarfCore/.../Transport/StreamingChild.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Transport/TransportErrors.swift | no | NO-TOUCHPOINT |
| Packages/ScarfCore/.../Transport/TransportPrivateMode.swift | yes (.env/auth.json modes) | OK |
| Packages/ScarfCore/.../ViewModels/ConnectionStatusViewModel.swift | yes (state.db, active_profile) | OK |
| Packages/ScarfIOS/Package.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../CitadelSSHService.swift | no | OK (host key: TRACKED) |
| Packages/ScarfIOS/.../CitadelServerTransport.swift | yes | FINDING-S15-F1 |
| Packages/ScarfIOS/.../CitadelTransportPool.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../Ed25519KeyGenerator.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../KeychainSSHKeyStore.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../NetworkReachabilityService.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../SSHClient+ExecCompletion.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../SSHConnectPolicy.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../SSHKeyICloudPreference.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../SSHKeyResolver.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../SSHPrivateKeyDecoding.swift | no | NO-TOUCHPOINT |
| Packages/ScarfIOS/.../UserDefaultsIOSServerConfigStore.swift | no | NO-TOUCHPOINT |
| Scarf iOS/App/ScarfGoCoordinator.swift | yes (profile normalize) | OK |
| Scarf iOS/App/ScarfGoTabRoot.swift | yes (profile remoteHome) | OK |
| Scarf iOS/App/ScarfIOSApp.swift | no (transport factory) | OK |
| Scarf iOS/App/Theme/ListDensity.swift | no | NO-TOUCHPOINT |
| Scarf iOS/Components/FlowLayout.swift | no | NO-TOUCHPOINT |
| Scarf iOS/Notifications/APNSTokenStore.swift | no (future Hermes endpoint, inert) | NO-TOUCHPOINT |
| Scarf iOS/Notifications/NotificationRouter.swift | no (gated off) | NO-TOUCHPOINT |
| Scarf iOS/Onboarding/OnboardingRootView.swift | no | NO-TOUCHPOINT |
| Scarf iOS/Servers/ServerListView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Models/HermesCLIRunner.swift | yes (wrapper) | OK |
| scarf/scarf/Core/Models/ServerContext+Mac.swift | yes (wrapper) | OK |
| scarf/scarf/Core/Persistence/ServerRegistry.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/HermesFileService.swift (3092-3896) | yes | OK |
| scarf/scarf/Core/Services/HermesFileWatcher.swift | yes (watched paths) | OK |
| scarf/scarf/Features/Servers/ViewModels/AddServerViewModel.swift | yes (hint) | OK |
| scarf/scarf/Features/Servers/ViewModels/RemoteDiagnosticsViewModel.swift | yes | OK |
| scarf/scarf/Features/Servers/ViewModels/TestConnectionProbe.swift | yes | OK |
| scarf/scarf/Features/Servers/Views/AddServerSheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Servers/Views/ConnectionStatusPill.swift | yes (`hermes profile use default` hint) | OK |
| scarf/scarf/Features/Servers/Views/ManageServersView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Servers/Views/MissingServerView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Servers/Views/RemoteDiagnostics.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Servers/Views/ServerSwitcherToolbar.swift | no | NO-TOUCHPOINT |
| scripts/build-detached.sh | no | NO-TOUCHPOINT |
| scripts/catalog.sh | no | NO-TOUCHPOINT |
| scripts/check-hermes-tables.py | yes | OK (ran, 8/8) |
| scripts/local-build.sh | no | NO-TOUCHPOINT |
| scripts/probe-hermes-routable-bands.py | yes | OK (older bands out of scope) |
| scripts/release.sh | no | NO-TOUCHPOINT |
| scripts/site.sh | no | NO-TOUCHPOINT |
| scripts/test-build.sh | no | NO-TOUCHPOINT |
| scripts/ui-gate.sh | yes (`hermes --version`, fixture) | OK |
| scripts/verify-ios-transport-pool.sh | yes (throwaway HERMES_HOME) | OK |
| Packages/ScarfCore/.../Parsing/HermesCLIOption.swift | yes (argv shape) | OK |
| Packages/ScarfCore/.../Parsing/IncrementalUTF8Decoder.swift | no | NO-TOUCHPOINT |

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `HERMES_HOME=<profiles/x>` prefix (remote) | env | SSHTransport.swift:500-526; CitadelServerTransport.swift:823-857 | hermes_cli/main.py:603-605 | OK |
| `-p default` pin for the root home | argv | HermesProfileScope.swift:220-242 | main.py `_scan_profile_flag`; profiles.py:1909-1941 | OK |
| PATH fallback `~/.local/bin:/opt/homebrew/bin:/usr/local/bin:~/.hermes/bin` | env | HermesConfigReader.swift:46-54 | scripts/install.sh:487-503 | OK |
| `~/.hermes/active_profile` read | file | ConnectionStatusViewModel.swift (probe script) | profiles.py:187-188 | OK |
| `<home>/state.db` readable probe | file | TestConnectionProbe.swift; RemoteDiagnosticsViewModel.swift; ConnectionStatusViewModel.swift | hermes_state.py | OK |
| `<home>/config.yaml` optional | file | RemoteDiagnosticsViewModel.swift | hermes_cli/config.py | OK |
| `hermes config set -- model.provider/model.default` | argv | HermesFileService.swift:3643-3661 | config.py:3479-3593 (LIVE --help) | OK |
| `hermes gateway stop` + pgrep/`gateway.pid` fallback | argv/file | HermesFileService.swift:3117-3254 | gateway_launchd.py:211-212; service_manager.py:467-469 | OK (verdict owned by gateway section) |
| `.env` / `auth.json` / `config.yaml api_key` credential scan | file | HermesFileService.swift:3517-3615 | main.py `_has_any_provider_configured` (check-hermes-tables lane 6 OK) | OK |
| Watched files (state.db, -wal, config.yaml, .env, memories, cron/jobs.json, gateway_state.json, logs, mcp-tokens) | file | HermesFileWatcher.swift watchedCorePaths | hermes_logging.py:241-242; dump.py:97; tools/send_message_tool.py:366 | OK |
| `hermes profile use default` hint | argv (user-copied) | ConnectionStatusPill.swift:145 | LIVE `hermes profile use --help` | OK |
| `COLUMNS=400` for rich wrapping | env | LocalTransport.swift; SSHTransport.swift:523 | rich non-TTY width | OK |
| iOS exec argv quoting | argv | CitadelServerTransport.swift:900-946 | — | FINDING-S15-F1 |
| Script verbs (fixture, tables) | argv/source | scripts/ui-fixture/make-ui-fixture.sh:195-236; check-hermes-tables.py:135 | LIVE --help; tag v2026.9.24 | OK |

## Not audited / couldn't verify
- Live SSH round-trips were not run: read-only brief, no remote host.
- The verb-specific verdicts in HermesCLIOutcome.swift (tools, skills, cron, plugins, mcp, pairing, gateway judge wording) belong to their feature sections. I audited only the shared `HermesCLIVerdict.judge` core, `managedRefusalAnchored`, and `HermesConfigSet`.
- The older-band correctness of `probe-hermes-routable-bands.py` is out of scope (it concerns pre-0.21.5 versions).
