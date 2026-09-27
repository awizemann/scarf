# S15-servers-transport-ios — verdict: WORKS-WITH-ISSUES

The shared plumbing works for the mainstream setups: local default profile; SSH servers added with Test Connection; iOS via Citadel. That covers the transports, the argv quoting, HERMES_HOME profile scoping, stdout/stderr split, exit codes, timeouts, file I/O, the watcher paths and the core CLI judge (`HermesCLIVerdict.judge`). There are four real defects. Three are on remote/SSH or named-profile paths and one is a misleading chat banner. None is a silent false success.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Add SSH server (Mac) → Save | DEGRADED | F1 (Save without Test leaves hint nil), F3 (wrapper override) |
| 2 | Test Connection probe (Mac) | DEGRADED | F3 (manual hint dropped by probe) |
| 3 | Remote Diagnostics | WORKS | — (script via stdin `/bin/sh -s`, honest about non-login PATH) |
| 4 | Locate hermes binary / HERMES_HOME (local) | WORKS | — (candidates match install.sh `~/.local/bin`, `/usr/local/bin`; active_profile honoured by CLI `_apply_profile_override`, hermes_cli/main.py:593-651) |
| 5 | Locate hermes binary (remote Mac / iOS) | DEGRADED (Mac) / WORKS (iOS) | F1 |
| 6 | Run a hermes command (argv quoting, env, timeout, split streams, exit code, verdict) | WORKS (with F1/F3 caveats on remote) | — |
| 7 | Read/write files remotely (cat / scp+mv, 0600 on .env/auth.json) | WORKS | — |
| 8 | File watcher paths | WORKS | — (all core paths still exist at the tag) |
| 9 | Connection status pill | WORKS | — |
| 10 | Hermes running indicator (sidebar / Health / Dashboard / Settings) | DEGRADED | F2 |
| 11 | Chat credential preflight banner (hasAnyAICredential, in owned range) | DEGRADED | F4 |
| 12 | App launch / first paint (C10) | WORKS | — (init does only local file ops; env probe warmed on a detached task, scarfApp.swift:89) |
| 13 | iOS onboarding / Citadel exec / NotificationRouter | WORKS | — (Citadel prepends `~/.local/bin` to PATH; APNs disabled, so the router has no Hermes touchpoint) |

## Findings

### S15-F1 · P1 · SOURCE · NEW
- **Claim:** On the Mac, an SSH server saved without clicking Test Connection has `hermesBinaryHint == nil`. Every one-shot CLI call then runs bare `hermes` in a non-login `sh -c`. This fails with exit 127 on the default non-root install (`~/.local/bin`). Chat (ACP, `bash -lc`) keeps working, so the split is confusing.
- **Scarf:**
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesPathSet.swift:155-156` (`binaryHint ?? "hermes"`).
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift:658-671,683-691` (`runProcess` → `sh -c`, no PATH prefix).
  - `scarf/scarf/Features/Servers/ViewModels/AddServerViewModel.swift:124-128` (the hint is only filled from a probe result).
  - `scarf/scarf/Features/Servers/Views/AddServerSheet.swift:236-243` (Save is enabled and is the default action without testing).
  - Contrast `scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift:837-840`: iOS prepends `$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin` for exactly this reason.
- **Hermes @v2026.9.24:**
  - `scripts/install.sh:487-494`: the non-root command link lives in `$HOME/.local/bin`.
  - `scripts/install.sh:2269-2313`: the PATH line is appended at the END of `~/.bashrc` / `.bash_profile` / `.profile`. That is not reached by a non-interactive, non-login `sh -c` (stock Ubuntu `.bashrc` returns early when not interactive).
- **Failure scenario:** The user adds an Ubuntu VPS where Hermes was installed as a normal user and clicks Save without testing. Config set, cron run, gateway start/stop, skills and so on all fail with `sh: 1: hermes: not found`. The failure is reported honestly, because the verdict sees exit 127. Chat works, and Remote Diagnostics flags "hermes binary on non-login PATH: FAIL". There is no Edit Server UI to add the hint afterwards (TRACKED as `t-edit-srv`, TASKS.md:16), so the user has to remove and re-add the server.
- **Affected call sites:** every `runHermesCLI` / `runHermesCLISplit` / `runHermesCLIData` / `ServerContext.runHermes*` on a Mac SSH context (HermesFileService.swift:2903, 2966, 2998).
- **Suggested fix:** Prepend the same `PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"` in `SSHTransport.composedRemoteCommand`, matching Citadel. Alternatively, run a hint probe on first connect.

### S15-F2 · P2 · SOURCE (+LIVE regex check) · NEW
- **Claim:** The gateway PID matcher does not match a gateway serving a named profile. Hermes puts `--profile <name>` between `hermes_cli.main` and `gateway run`, so "Hermes Running" reads **Stopped** while the gateway is up.
- **Scarf:** `scarf/scarf/Core/Services/HermesFileService.swift:2471-2476`. The regex requires `-m hermes_cli.main` followed directly by `gateway run`, or `hermes gateway run`.
- **Hermes @v2026.9.24:**
  - `hermes_cli/gateway_launchd.py:210-212`: `[python, "-m", "hermes_cli.main", *_profile_arg().split(), "gateway", "run", ...]`.
  - `hermes_cli/gateway_service_unit.py:223`: systemd `ExecStart={python} -m hermes_cli.main{ profile_arg} gateway run`.
  - `hermes_cli/gateway.py:2184-2193`: `_profile_arg` returns `--profile <name>` for any non-root HERMES_HOME.
- **Failure scenario:** The sticky `active_profile` is `work` (or a remote has `remoteHome=~/.hermes/profiles/work`). The user starts the gateway from Scarf, and the service argv is `python -m hermes_cli.main --profile work gateway run --external-supervisor`. The sidebar footer (SidebarView.swift:297-302), Health (HealthView.swift:406-417), Dashboard and Settings all show "Hermes Stopped". A foreground `hermes -p work gateway run` is missed the same way.
- **Evidence:** Live `pgrep` on this Mac (default profile) matches `…python -m hermes_cli.main gateway run --external-supervisor`. The profile form cannot match, because `hermes_cli\.main[[:space:]]+gateway` needs `gateway` as the next token.
- **Suggested fix:** Allow an optional `(--profile|-p)[[:space:]]+[^[:space:]]+[[:space:]]+` group between `hermes_cli.main`/`hermes` and `gateway`.

### S15-F3 · P2 · SOURCE · NEW
- **Claim:** The gh#105 "Hermes binary" override does not work for the wrapper values the UI advertises. The runtime and the probe each break it:
  - **Runtime:** the executable is double-quoted as ONE shell word, so a multi-word value like `docker compose exec hermes hermes` is looked up as a single command name.
  - **Probe:** Test Connection drops the hint entirely.
- **Scarf:**
  - Runtime: `scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift:669-670` (`([executable] + args).map { remotePathArg($0) }` makes `"docker compose exec hermes hermes"`). The same applies to `makeProcess`/ACP (:707) and Citadel `shellJoin` (CitadelServerTransport.swift:873-881).
  - UI promise: `scarf/scarf/Features/Servers/Views/AddServerSheet.swift:129` ("Anything `/bin/sh -c "<value> …"` can run is accepted … short shell fragments").
  - Probe: `scarf/scarf/Features/Servers/ViewModels/TestConnectionProbe.swift:106-115,117,225-227`. The script is passed as a separate ssh argv element after `/bin/sh -c`. ssh space-joins its argv into one command string for the remote login shell, so the remote runs `/bin/sh -c HERMES_HINT="…"` as its own child, and the assignment dies with it. The rest of the script then runs in the user's login shell with `HERMES_HINT` unset. `SSHScriptRunner.swift:7-25` documents this same argv-flattening hazard and avoids it by piping the script on stdin.
- **Hermes:** n/a (Scarf-side quoting).
- **Failure scenario:** The user enters `docker compose exec hermes hermes`:
  - Test Connection reports "hermes binary not found in remote $PATH", or a different `hermes` path, because the hint is ignored.
  - After Save (the hint wins), every CLI call and chat fails with `docker compose exec hermes hermes: not found`.
  - A single-word absolute path does work.
- **Suggested fix:** Emit the hint unquoted (it is user-trusted input from the Advanced field) or split it into words. Pipe the probe script via `ssh … /bin/sh -s` stdin, like SSHScriptRunner.

### S15-F4 · P2 · SOURCE · NEW
- **Claim:** The chat preflight "No AI provider credentials detected" banner shows falsely in two cases:
  - The key is in `~/.hermes/.env` under any of the many provider env vars Scarf does not list.
  - The provider is a keyless local endpoint.
- **Scarf:** `scarf/scarf/Core/Services/HermesFileService.swift:2596-2610` (11-key allowlist), :2748-2831 (the .env scan only looks for those keys; the config.yaml scan only looks for `api_key:`). Banner: `scarf/scarf/Features/Chat/Views/ChatView.swift:253-262`.
- **Hermes @v2026.9.24:** The provider registry at `hermes_cli/auth.py:171-260` reads `DEEPSEEK_API_KEY`, `KIMI_API_KEY`, `ZAI_API_KEY`/`GLM_API_KEY`, `MINIMAX_API_KEY`, `HF_TOKEN`, `NVIDIA_API_KEY`, `DASHSCOPE_API_KEY`, `COPILOT_GITHUB_TOKEN`, `AI_GATEWAY_API_KEY`, `KILOCODE_API_KEY` and others. Hermes stores `.env` at `get_hermes_home()/.env` (`hermes_cli/config.py:462`).
- **Failure scenario:** A DeepSeek user whose `hermes setup` wrote `DEEPSEEK_API_KEY=…` to `.env` (or an Ollama/LM Studio user with no key) sees an orange "No AI provider credentials detected" banner telling them to add `ANTHROPIC_API_KEY`, even though chat works.
- **Suggested fix:** Treat any non-empty `*_API_KEY=` / `*_TOKEN=` line in `.env` as a credential, and suppress the banner when `model.base_url` is set.

### S15-F5 · P3 · SOURCE (+LIVE) · NEW
- **Claim:** On a standard macOS launchd install, `hermesPID()` returns the `osascript` wrapper's PID, not the gateway's. This happens because the wrapper argv also contains `-m hermes_cli.main gateway run` and has the lowest PID.
- **Scarf:** `scarf/scarf/Core/Services/HermesFileService.swift:2479-2485` (first line of `pgrep` output); Health shows it as "PID n" (HealthView.swift:413-416).
- **Hermes @v2026.9.24:** `hermes_cli/gateway_launchd.py:233-235` (`/usr/bin/osascript -e 'do shell script "exec … -m hermes_cli.main gateway run …"'`), :260 (the `stderr_timestamp` wrapper).
- **Evidence (live):** `pgrep` returned `8542` (osascript), `8548` (stderr_timestamp), `8550` (the real gateway).
- **Impact:** Health shows the wrong PID. On `stopHermes`'s `.failed`-only fallback, the SIGTERM goes to osascript rather than to the gateway.
- **Suggested fix:** Take the highest PID, or anchor the regex on the argv[0] python/hermes executable.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `pgrep -f <gateway regex>` | argv | HermesFileService.swift:2471-2476 | gateway_launchd.py:210-212; gateway_service_unit.py:223 | FINDING-F2, F5 |
| `hermes gateway stop` + verdict + kill fallback | argv | HermesFileService.swift:2525-2556 | gateway.py (owned by S07) | OK (judge owned by S07) |
| `/bin/kill -TERM` (remote fallback) | argv | HermesFileService.swift:2547-2553 | — | OK |
| local binary candidates | path | HermesPathSet.swift:133-142; HermesFileService.swift:2558 | scripts/install.sh:487-494 | OK |
| remote binary `binaryHint ?? "hermes"` | path | HermesPathSet.swift:155-156 | install.sh:2269-2313 | FINDING-F1 |
| login-shell env harvest (PATH + creds) | env | HermesFileService.swift:2596-2690 | — | OK |
| credential preflight (.env / auth.json `credential_pool[].access_token`, `providers.*` / config `api_key:`) | file | HermesFileService.swift:2748-2831 | auth.py:658-704; credential_pool.py:217; auth.py:171-260 | FINDING-F4 (auth.json shape OK) |
| `config set model.provider/model.default` (legacy, no callers) | argv | HermesFileService.swift:2851-2877 | (S05/S06) | OK |
| `runHermesCLI` combined output + separator + timeout partial | runner | HermesFileService.swift:2893-2945 | — | OK |
| `runHermesCLISplit` / `runHermesCLIData` | runner | HermesFileService.swift:2951-3012 | — | OK |
| readFile / readFileResult / ENOENT classification | file | HermesFileService.swift:3014-3112; SSHTransport.swift:365-380 | — | OK |
| SSH write (scp tmp + chmod + mv, 0600 set) | file | SSHTransport.swift:383-475; TransportPrivateMode.swift | config.py:462 (.env), auth.py | OK |
| `HERMES_HOME=` profile scope (Mac SSH / iOS) | env | SSHTransport.swift:658-661; CitadelServerTransport.swift:815-840; HermesProfileScope.swift:161-164 | hermes_constants.py:113-118; main.py:593-651 | OK |
| `COLUMNS=400` | env | LocalTransport.swift:76,114; SSHTransport.swift:669 | — | OK |
| argv quoting (`remotePathArg`, `shellQuote`, `shellJoin`) | quoting | SSHTransport.swift:283-337; CitadelServerTransport.swift:873-881 | — | OK for argv; FINDING-F3 for executable hint |
| Test Connection probe script | script | TestConnectionProbe.swift:117-227 | — | FINDING-F3 |
| Remote Diagnostics script (`/bin/sh -s` stdin) | script | RemoteDiagnosticsViewModel.swift; SSHScriptRunner.swift:231-243 | — | OK |
| Connection status probe (`state.db`, `active_profile`) | file | ConnectionStatusViewModel.swift | hermes_state.py:168; profiles.py:187-188 | OK |
| watched: `state.db`, `-wal`, `config.yaml`, `.env` | file | HermesFileWatcher.swift (watchedCorePaths) | hermes_state.py:168; config.py:462 | OK |
| watched: `memories/MEMORY.md`, `USER.md` | file | same | tools/memory_tool.py:38-40; memory_tool_store.py:212 | OK |
| watched: `cron/jobs.json` | file | same | cron/jobs.py:74 | OK |
| watched: `gateway_state.json` | file | same | gateway/run.py:4016 | OK |
| watched: `logs/agent.log`, `errors.log`, `gateway.log` | file | same | hermes_logging.py:241-243 | OK |
| watched: `mcp-tokens/` | file | same | tools/mcp_oauth.py:229-232 | OK |
| watched: `scarf/projects.json`, `session_project_map.json` | file | same | Scarf-owned | OK |
| `HermesCLIVerdict.judge` core (exit≠0 fails, silence = unconfirmed, anchored/glyph strip) | judge | HermesCLIOutcome.swift:225-266 | cli_output.py:13-22 (✓ ⚠ ✗ glyphs); colors.py:9 | OK |
| per-verb marker tables | judge | HermesCLIOutcome.swift:276+ | owned by feature sections | UNVERIFIABLE here (per-section) |
| iOS onboarding `echo ok` test | ssh | OnboardingViewModel.swift:181-213 | — | OK |
| iOS NotificationRouter | — | NotificationRouter.swift | — | OK (no Hermes touchpoint; APNs off) |
| Edit existing server (to set hint later) | UI | — | — | TRACKED (TASKS.md:16 `t-edit-srv`) |

## Not audited / couldn't verify
- The individual per-verb marker lists in `HermesCLIOutcome.swift` (skills, cron, plugins, gateway, mcp, backup, and so on) are owned by the feature sections. I audited only the shared `judge` / ANSI / glyph logic.
- Fish or csh as the remote login shell. The Test Connection probe script runs in the login shell (see F3), so it would fail there. This is rare and was not separately reported.
- Nix installs (`~/.nix-profile/bin/hermes`) are not among the local candidates. This is rare and was not reported.
- No live SSH round-trip was performed; the remote behaviour is traced from source.
