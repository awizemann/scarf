# S15-servers-transport-ios — verdict: WORKS-WITH-ISSUES

The core plumbing works against Hermes 0.21.5 (v2026.9.24). That covers binary/home resolution on local and remote hosts, profile pinning (`HERMES_HOME=` plus `-p default`), argv quoting over `sh -c`, timeouts on every spawn, the stdout/stderr split, exit-code capture, the shared CLI verdict judge, the pgrep gateway match, file-watcher paths, and the connection pill and diagnostics scripts. I verified these against the tagged source and, where possible, against the live install. Five findings remain: none P0 or P1, two P2 and three P3.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Add server (Mac, SSH) → Test Connection probe → save with probed binary hint | WORKS | — |
| 2 | Edit an existing server (fix home / binary / identity after a failed check) | BROKEN (no UI) | F2 |
| 3 | Remote Diagnostics sheet (14 probes) | WORKS | F2 (hints point to a missing Edit screen) |
| 4 | Connection status pill (15 s two-tier probe, degraded causes, profile hint) | WORKS | — |
| 5 | Locate hermes + HERMES_HOME: local (candidates, active_profile), remote (hint → login PATH → install dirs; profile `HERMES_HOME=` + `-p default`) | WORKS (local: DEGRADED for non-standard installs) | F5 |
| 6 | Run a hermes command (runHermesCLI / Split / Data): argv quoting over SSH, env, COLUMNS, timeouts, stdout/stderr split, exit code, partial stdout on timeout | WORKS | — |
| 7 | CLI outcome judging (HermesCLIVerdict / HermesCLIOutcome core, glyph stripping, anchoring, 3-state confidence) | WORKS | — |
| 8 | Read / write files remotely (cat / scp+mv / stat / statAll / ls) | DEGRADED | F1 |
| 9 | File watcher (local vnode sources, remote 3 s stat poll) — watched paths exist at tag | WORKS | — |
| 10 | Gateway running/stop (pgrep pattern, gateway.pid fallback, stopHermes fallback gating) | WORKS | — |
| 11 | App launch / first paint (C10) and server removal | WORKS / DEGRADED on remove | F3 |
| 12 | iOS: onboarding test → Citadel transport runProcess (PATH, HERMES_HOME, pin, COLUMNS, timeout) → profile re-pointing, version banner, notification router | WORKS | F4 |

## Findings

### S15-F1 · P2 · PLAUSIBLE · NEW
- Claim: A remote write to any path containing a space, quote or non-ASCII character fails on a current macOS client. `scpRemoteSpec` shell-quotes the path, but OpenSSH 9+ `scp` uses the SFTP protocol by default, which runs no remote shell, so the quote characters become part of the file name.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift:332-337` (`scpRemoteSpec` → `~/` + `shellQuote(rest)`), used at `:421`. The retry after `mkdir -p` (`:423-434`) re-sends the same quoted spec, so it fails again and throws `classifySSHFailure`. The unit test pins the shell-quoted form (`TransportAtomicityParityTests.swift:374`: `"~/'My Projects/a.json'"`).
- Hermes @v2026.9.24: n/a (transport layer; affects every remote `unguardedWriteFile`: project `.scarf/*`, AGENTS.md, registry/sidecar writes under a spaced `remoteHome` or projects root).
- Failure scenario: A remote project at `~/My Projects/foo`, or a custom Hermes home with a space. Scarf stages `~/'My Projects/foo/.scarf/dashboard.json.scarf-XXXX.tmp'`. SFTP-mode scp creates or looks for a directory literally named `'My Projects` and fails. The user sees a transport error on save, and the `mv` step (which quotes correctly through `remotePathArg`) never runs.
- Evidence: local client is `OpenSSH_10.3p1`. `man scp` says SFTP is the default protocol and that only the legacy protocol (`-O`) "requires execution of the remote user's shell … careful quoting". I did not run scp against a live host (read-only audit), so this is PLAUSIBLE, not LIVE.
- Suggested fix: pass the remote path unquoted, keeping `~/` (SFTP mode expands it via expand-path), or pin `-O` and keep the quoting. Either way, test with a spaced path against a real host.

### S15-F2 · P2 · SOURCE · TRACKED(t-83d2fe, the missing edit feature) + NEW (misleading hints)
- Claim: The Mac app has no way to edit a saved server. `ServerRegistry.updateServer` has no callers, and the ManageServersView row menu only offers Back Up, Restore, Diagnostics and Remove. Yet six user-facing hints tell the user to fix things via "Manage Servers → this server → Edit".
- Scarf: `scarf/scarf/Core/Persistence/ServerRegistry.swift:205` (unused `updateServer`), `scarf/scarf/Features/Servers/Views/ManageServersView.swift:395-431` (actions menu). Hints:
  - `RemoteDiagnosticsViewModel.swift:74`, `:90`, `:92`
  - `ConnectionStatusViewModel.swift:359`, `:374`
  - `HermesDataService.swift:234`
  - Export doc comment at `ServerRegistry.swift:~300` ("re-point each entry's identityFile in Edit Server").
- Hermes @v2026.9.24: n/a.
- Failure scenario: Diagnostics reports "Hermes directory exists: FAIL" on a systemd host (`/var/lib/hermes/.hermes`), or the pill says profile `work` is active. The user follows the hint and finds no Edit, so their only path is Remove and re-add. The comment at `ServerContext.swift` (hermesBinaryHintIsPath doc) already accepts this ("repaired by adding the server again").
- Suggested fix: add an Edit sheet (reuse AddServerSheet prefilled → `updateServer`), or reword the hints to "remove and re-add the server" until it exists.

### S15-F3 · P3 · SOURCE · NEW
- Claim: Removing a server spawns `/usr/bin/ssh -O exit` synchronously on the main actor, with a 10 s budget. That breaks charter C10 (no subprocess on the main actor).
- Scarf: `scarf/scarf/Core/Persistence/ServerRegistry.swift:233` (`transport.closeControlMaster()` inside `removeServer`; the app target defaults to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and the call comes from the confirmation dialog in `ManageServersView.swift:77`) → `SSHTransport.swift:139-143` → `runLocal(..., timeout: 10, gate: .none)`, which blocks on `DispatchGroup.wait`.
- Failure scenario: After sleep or a network change the ControlMaster is wedged (the gh#123 shape). Clicking Remove Server freezes the UI for up to 10 s. Normally `-O exit` returns in milliseconds, so this only shows with a wedged master.
- Suggested fix: `Task.detached`/`OffPool.run { transport.closeControlMaster() }`, like the cache invalidation two lines below.

### S15-F4 · P3 · SOURCE · NEW (cross-cutting, iOS transport)
- Claim: The iOS Citadel transport single-quotes every argv token and never rewrites a leading `~/` to `$HOME/`. `rewriteHomeRelative` is defined but has no callers. So a home-relative path argument reaches the remote command as a literal `~`. The Mac `SSHTransport.remotePathArg` does the rewrite.
- Scarf: `scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift:894-898` (`commandLine` → `shellJoin([token])`), `:920-927` (`~` is not in the safe set, so the token is single-quoted), `:931` (unused `rewriteHomeRelative`).
- Affected call site found: `GitBranchService.swift:48` (`git -C <projectPath>`), from iOS `ChatView.swift:2955`, `:3163`. Remote template installs store `~/projects/<slug>` as the project path: `ServerContext.defaultProjectsRoot` flows into `ProjectTemplateInstaller.swift:453`.
- Failure scenario: In ScarfGo, a chat in a remote project installed under the default `~/projects` never shows its git branch chip, because `git -C '~/projects/x'` fails. The same project shows the chip on the Mac. I found no hermes argv on iOS that currently passes a `~/` path, so the impact today is cosmetic, but the divergence is latent for any future path argument.
- Suggested fix: apply `rewriteHomeRelative` and double-quote tokens starting with `~/` in `commandLine`, mirroring `remotePathArg`.

### S15-F5 · P3 · SOURCE · NEW
- Claim: Local environment discovery assumes a zsh user with a standard install location:
  - The login-shell env probe always runs `/bin/zsh`, not `$SHELL`.
  - The local `hermes` binary is looked up only in four fixed paths; the harvested login PATH is never consulted.
- Scarf: `scarf/scarf/Core/Services/HermesFileService.swift:3261` (`/bin/zsh -l [-i]`), `:3161-3166` (`hermesBinaryPath()` → `HermesPathSet.hermesBinaryCandidates`, `HermesPathSet.swift:148-156`), used by `runHermesCLI`/`Split`/`Data` (`:3488-3495` etc.). The remote probe does use `${SHELL}` (`TestConnectionProbe.loginPathBorrow`).
- Hermes @v2026.9.24: the installer links to `~/.local/bin` or `/usr/local/bin` (`scripts/install.sh:487-494`), both covered. Documented alternatives such as Nix (`website/docs/getting-started/nix-setup.md`) or an editable dev venv (`README.md:229`) land elsewhere.
- Failure scenario:
  - A bash or fish user who exports provider keys or nvm PATH only in `.bash_profile` / `config.fish`: Scarf-spawned `hermes`, and the MCP servers it starts, get neither, and the missing-credentials hint shows falsely.
  - A Mac with hermes only on a Nix/venv PATH: every local CLI action returns `(-1, "")` ("hermes binary not found").
  - Default-shell installs via install.sh or Homebrew are unaffected.
- Suggested fix: probe `$SHELL` (falling back to zsh), and fall back to resolving `hermes` against the enriched PATH after the fixed candidates.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `pgrep -f <gateway pattern>` (default / named profile) | argv (system) | HermesFileService.swift:3034-3039; HermesGatewayProcessMatch.swift pgrepPattern | live cmdline `python -m hermes_cli.main gateway run --external-supervisor` (matched live, wrappers excluded) | OK (LIVE) |
| `<home>/gateway.pid` JSON record (pid, kind, hermes_home, start_time) | file | HermesFileService.swift:3066-3087 | gateway/status.py:677-684, 752-753 (live file shape confirmed) | OK |
| `ps -p <pid> -o command=`, `/proc/<pid>/stat` | argv/file | HermesFileService.swift:3068-3084 | gateway/status.py:458-468 | OK |
| root `gateway_state.json` served_profiles | file | HermesFileService.swift:3093-3099 | hermes_cli/service_manager.py:254; container_boot.py:155 | OK |
| `hermes gateway stop` + judge + gated SIGTERM fallback | argv | HermesFileService.swift:3130-3159 | hermes_cli/gateway.py (verb verdict owned by gateway section) | OK |
| `/bin/kill -TERM <pid>` (remote) | argv | HermesFileService.swift:3149-3155 | — | OK |
| local binary candidates `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.hermes/bin` | path | HermesPathSet.swift:148-156 | scripts/install.sh:487-494 | OK / FINDING-F5 |
| login-shell env harvest (PATH, provider keys, SSH_AUTH_SOCK) | env | HermesFileService.swift:3181-3310 | hermes_cli/main.py:1052 (`_has_any_provider_configured` env vars) | FINDING-F5 |
| `~/.hermes/.env`, `auth.json` (credential_pool / providers), `config.yaml` model | file | HermesFileService.swift:3356-3453 | hermes_cli/main.py:1052-1140 | OK |
| `hermes config set model.provider / model.default` (legacy) and plan ops | argv | HermesFileService.swift:3474-3517 | hermes_cli/config.py (config section owns) | OK |
| runHermesCLI / Split / Data (binary, stdin, timeout, stdout+sep+stderr, partial stdout on timeout) | process | HermesFileService.swift:3519-3643 | — | OK |
| readFile / readFileData / isFileNotFound | file I/O | HermesFileService.swift:3647-3735 | — | OK |
| remote `sh -c` composition: `PATH="$PATH":<install dirs>`, `COLUMNS=400`, `HERMES_HOME=`, `-p default` | argv | SSHTransport.swift:640-706; HermesProfileScope.swift:220-300; HermesConfigReader.swift:46-54 | hermes_cli/main.py:484-524, 596-619 (scan + HERMES_HOME trust + active_profile); `hermes --help` line 212 `-p <profile>` | OK (LIVE) |
| ACP/stream spawns `bash -lc` | argv | SSHTransport.swift:722-744, 764-775 | — | OK |
| streamRawBytes (no PATH/HOME prefix) | argv | SSHTransport.swift:917 | callers are `cat`/`tar` only | OK |
| remote readFile `cat`, stat/statAll, ls -A, mkdir -p, rm -f, test -e | shell | SSHTransport.swift:342-590 | — | OK |
| remote write scp → chmod/mv | scp | SSHTransport.swift:388-466 | — | FINDING-F1 |
| ControlMaster `-O exit` on remove | argv | SSHTransport.swift:139; ServerRegistry.swift:233 | — | FINDING-F3 |
| Test Connection probe script (`HERMES:`, `DB:ok`, `SUGGEST:`) | shell | TestConnectionProbe.swift:237-354 | install.sh:487-494 | OK |
| Remote Diagnostics script (14 probes) | shell | RemoteDiagnosticsViewModel.swift:237-409 | — | OK |
| Connection pill script (TIER1/TIER2, `~/.hermes/active_profile`) | shell | ConnectionStatusViewModel.swift:254-273 | hermes_cli/main.py:607-619 (active_profile file) | OK |
| Watched core paths: state.db, -wal, config.yaml, .env, memories/MEMORY.md, USER.md, cron/jobs.json, gateway_state.json, logs/agent.log, errors.log, gateway.log, mcp-tokens, scarf/projects.json, scarf/session_project_map.json, root gateway_state.json | files | HermesFileWatcher.swift:91-124 | hermes_logging.py:241-243; tools/mcp_oauth.py:232; tools/memory_tool_store.py:212; cron jobs.json (profile_distribution.py:60); live ~/.hermes listing | OK |
| `hermes --version` capability probe | argv | HermesVersionCache.swift:288-303; HermesCapabilities.swift:2788-2830 | live: `Hermes Agent v0.21.5 (2026.9.24) · upstream …` | OK (LIVE) |
| Shared judge (stripANSI, unglyphed glyph set ✓✗⚠⊘•, anchoring, confidence) | parser | HermesCLIOutcome.swift:136-270 | glyph survey of hermes_cli prints: no anchored Scarf marker follows ❌/✅/→/ℹ | OK |
| iOS Citadel runProcess: `COLUMNS`, `PATH` prelude, `HERMES_HOME`, `-p default`, `/bin/sh -c`, timeout | argv | CitadelServerTransport.swift:791-885 | same as Mac rows | OK |
| iOS Citadel argv tokens with `~/` | argv | CitadelServerTransport.swift:894-935 | — | FINDING-F4 |
| iOS onboarding probe `echo scarf-ok` | exec | CitadelSSHService.swift:51-110 | — | OK |
| iOS host-key validation `.acceptAnything()` | ssh | CitadelSSHService.swift:147; CitadelServerTransport.swift:1217 | — | TRACKED (t-93ddfdc4) |
| iOS profile re-pointing (`remoteHome` → `<root>/profiles/<name>`) | path | ScarfGoTabRoot.swift:80-86; IOSServerConfig toServerContext | hermes_cli/main.py:603-605 | OK |
| NotificationRouter (APNs disabled, local routing only) | — | NotificationRouter.swift | — | OK (no Hermes touchpoint) |
| HermesVersionBanner (< v0.12 via hasCurator) | caps | HermesVersionBanner.swift:21-27 | — | OK |
| OutcomeMessage / OutcomeMessageBar / StateReadErrorBanner (3-state UI) | UI | OutcomeMessage.swift | — | OK |
| App launch: enricher warm-up detached, bootstrap tasks detached | C10 | scarfApp.swift:71-160 | — | OK |

## Not audited / couldn't verify
- F1 is not confirmed live: auditing is read-only, so I did not run scp/ssh against any host.
- I read PipeReader.swift, TransportErrors.swift and CitadelTransportPool.swift only at the level of their use sites. I did not re-derive the drain/EOF concurrency proofs.
- Per-verb verdicts in HermesCLIOutcome.swift (skills, cron, MCP, plugins, gateway, backup, webhook…) belong to their feature sections. I checked only the shared judge.
- For another section (iOS cron), noted in passing: `IOSCronViewModel.runCronCLI` (`IOSCronViewModel.swift:490`) judges `cron pause/resume/resume --run-now` by `exitCode == 0` alone. The cron section should confirm against Hermes `hermes_cli/cron.py` exit-0 arms.
- iOS onboarding saves the server without checking that Hermes exists on the host. This is by design (later screens surface it), so it is not a finding.
