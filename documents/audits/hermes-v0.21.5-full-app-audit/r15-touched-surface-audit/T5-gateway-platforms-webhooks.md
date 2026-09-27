# T5-gateway-platforms-webhooks — verdict: WORKS-WITH-ISSUES

Scarf: integration worktree `/Users/awizemann/Developer/Scarf-wt/integration` @ `8b311060`.
Hermes: `~/.hermes/hermes-agent-v0215` @ `v2026.9.24`. No CLI probes were needed; every claim below is traced in source.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Gateway view load: `gateway_state.json` (own or root-projected) + `gateway status` + `pairing list` + `gateway list` | DEGRADED | T5-F2 |
| 2 | Gateway Start / Stop, judged by printed output (launchd, systemd, s6, parked profile) | WORKS | — |
| 3 | Gateway Restart (Gateway view; "Restart Gateway" in Platforms and MCP) | BROKEN on hosts with no installed service (manual/tmux gateway) | T5-F1 |
| 4 | Process detection: `pgrep -f` pattern (named profile, launchd osascript/stderr_timestamp wrappers), `gateway.pid` + `ps` fallback, `/proc` start-time check | WORKS | — |
| 5 | Served-profile projection (`served_profiles`, `<profile>:<platform>` re-key, api_server/webhook mirrors, config-derived fallback) | WORKS | — |
| 6 | Pairing approve / revoke | DEGRADED | T5-F2 |
| 7 | Platform setup forms: WhatsApp Cloud (.env vs config split, allowlist presence, dm_policy), Webhook (both switches), Signal (env + `require_mention`), shared save path (`config set` judged by output, proven loads, shared-key resolution) | WORKS | — |
| 8 | Webhooks on Mac: list / subscribe (secret captured once) / remove / test / not-enabled state | WORKS | — |
| 9 | Webhooks on iOS (read-only list via Citadel, profile-pinned by the transport) | WORKS (copy issue) | T5-F3 |
| 10 | Gateway setup terminal (`hermes gateway setup` locally or through `ssh -t`, profile pinned) | WORKS | — |
| 11 | Tools view: `tools list --platform`, `tools enable|disable … --platform`, connectivity dots, `mcp list` | WORKS | — |
| 12 | File watcher: gateway_state.json (own + root for a named profile), config/.env, atomic-rename re-arm, remote polling | WORKS | — |

## Findings

### T5-F1 · P1 · SOURCE · NEW (related to TRACKED decision `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md:2135-2140`, which records that the run "ends at Scarf's own CLI timeout" but not that the timeout kills the gateway)
- Claim: On a host with no installed gateway service, Scarf's Restart stops the user's running gateway, then starts a replacement inside the CLI process that Scarf itself SIGTERMs when the CLI timeout expires. The banner says the gateway is "starting in the foreground".
- Scarf: `scarf/scarf/Features/Gateway/ViewModels/GatewayViewModel.swift:491,549-551` (60 s `mutationTimeout`, `:130`); `scarf/scarf/Core/Services/HermesFileService.swift:1456-1457` (30 s, used by `PlatformsViewModel.swift:291` and `MCPServersViewModel.swift:670`); `LocalTransport.swift:~333` (`waitDraining`: poll → SIGTERM → SIGKILL on overrun); verdict arm `HermesCLIOutcome.swift` `HermesGatewayServiceVerdict.judge` (`gatewayForegroundStarting` → `.unconfirmed`).
- Hermes @v2026.9.24: `hermes_cli/gateway.py:4909-4981` `_cmd_restart`: when `_installed_service_kind_for` returns None (`:4504-4511`: no systemd unit, no launchd plist, not Windows), it calls `stop_profile_gateway()` (`:4977`), prints `Starting gateway...` (`:4980`), then `run_gateway(verbose=0, force=force)` (`:4981`). `run_gateway` (`:4075-4115`) runs the gateway in-process in the foreground ("Press Ctrl+C to stop"). `_restart_all` has the same shape (`:4898-4904`).
- Failure scenario: A user runs the gateway with `hermes gateway run` in tmux/nohup. This is common on a remote Linux VPS, and on a Mac where `gateway install` was never run. They save a platform form and click "Restart Gateway". Hermes kills the tmux gateway and starts a new one inside Scarf's spawned `hermes` process. After 30 s (Platforms/MCP) or 60 s (Gateway view), Scarf's timeout SIGTERMs that process, and with it the gateway. The UI shows the neutral "Hermes is starting the gateway in the foreground… Scarf can't confirm it" banner. The next reload shows "not running". A gateway that was running before the click is now down, and nothing says Scarf stopped it. On SSH the ssh client is killed instead; the remote gateway's stdout pipe breaks, so it dies the same way or is orphaned.
- Evidence: `run_gateway` → `from gateway.run import start_gateway` in the same process (`gateway.py:4107`); no detach/nohup on this path (contrast `gateway_launchd.py:_spawn_detached_gateway`).
- Suggested fix: Before restarting, read `gateway status`. If it shows the manual branch (`(Running manually, not as a system service)`), don't run `gateway restart`: tell the user to restart it where it runs (or offer `gateway install`). Alternatively spawn the restart detached and never kill it on timeout.

### T5-F2 · P2 · SOURCE · NEW
- Claim: When there are pending pairing requests but no approved users, `parsePairing` turns Hermes's `No approved users.` line into a phantom pending pairing (platform `No`, code `approved`) with a live Approve button.
- Scarf: `scarf/scarf/Features/Gateway/ViewModels/GatewayViewModel.swift:440-474` (section tracker keys on the capitalised `Approved Users`, `:442`; the `inPending && parts.count >= 2` arm at `:469` accepts any 2+-token line); rendered with Approve at `scarf/scarf/Features/Gateway/Views/GatewayView.swift:329-341`.
- Hermes @v2026.9.24: `hermes_cli/pairing.py:29-52` `_cmd_list`: the pending block and its two hints are printed first, then `print("\n  No approved users.")` (`:51`) when `approved` is empty. There is no header in between, so the line lands inside the pending section.
- Failure scenario: A new user DMs the bot and there are no approved users yet. This is the normal first-pairing state. The Gateway view shows two pending rows: the real one and `No / approved`. Clicking Approve on the phantom row runs `hermes pairing approve -- No approved`. Hermes refuses ("not found or expired") and records a failed attempt for platform `no`. The phantom row comes back on every reload.
- Evidence: the existing tests cover only both-empty (`scarfTests/AuditP21VerdictTests.swift:167-177`) and both-present (`:130-162`), not pending-present + approved-empty.
- Suggested fix: Skip trimmed lines starting with `No approved users` / `No pending pairing requests` (or reset both section flags on any line starting `No `).

### T5-F3 · P3 · SOURCE · NEW
- Claim: ScarfGo's "webhook not enabled" state tells the user to run `hermes setup`. That wizard only writes `WEBHOOK_ENABLED` to `.env`, which does not unlock `hermes webhook list`, so the advice leads nowhere.
- Scarf: `scarf/Scarf iOS/Webhooks/WebhooksView.swift:42`. The Mac copy was corrected (`scarf/scarf/Features/Webhooks/Views/WebhooksView.swift:111-127`: "Turn on Webhook in Platforms → Webhook, which sets platforms.webhook.enabled…").
- Hermes @v2026.9.24: `hermes_cli/webhook.py:54-55,105-107` (`_is_webhook_enabled` reads only config `platforms.webhook.enabled`); `hermes_cli/setup_platforms.py:~241` (`_setup_webhooks` writes only `save_env_value("WEBHOOK_ENABLED","true")`).
- Failure scenario: An iPhone user sees "Run `hermes setup`…", runs it, enables webhooks, and ScarfGo still says "Setup required".
- Suggested fix: Use the Mac wording (enable Webhook in the Mac app's Platforms → Webhook, or set `platforms.webhook.enabled: true`).

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `<home>/gateway_state.json` read (own) | file | HermesFileService.swift:157-195; GatewayViewModel.swift:278-304 | gateway/status.py:713-717,1088-1119 | OK |
| Root `gateway_state.json` for a named profile (`served_profiles`, `<profile>:<platform>`) | file | HermesFileService.swift:199-226; HermesGatewayStateProjection.swift:31-147 | gateway/status.py:1098,1259-1331; gateway/run_adapters.py:937-950 | OK |
| `platforms.*.state/error_code/error_message` | file keys | HermesConfig.swift:2270-2300 (PlatformState) | gateway/status.py:1106-1111 | OK |
| Config-derived multiplex (`multiplex_profiles`, `gateway.multiplex_profiles`) | config read | HermesGatewayStateProjection.swift:67-88 | hermes_cli/gateway_multiplex_mode.py:53-76 | OK |
| `/usr/bin/pgrep -f <pattern>` | argv | HermesFileService.swift:2986-3012; HermesGatewayProcessMatch.swift:59-76 | gateway_launchd.py:211-235,260; gateway_service_unit.py:223; gateway.py `_scan_gateway_pids` | OK |
| `<home>/gateway.pid` (JSON record or bare pid) | file | HermesFileService.swift:3019-3040; HermesGatewayProcessMatch.swift:90-103 | gateway/status.py:677-684,752-753 | OK |
| `/bin/ps -p <pid> -o command=` | argv | HermesFileService.swift:3023 | — | OK |
| `/proc/<pid>/stat` field 22 | file | HermesFileService.swift:3033-3038 | gateway/status.py:458-468 | OK |
| `/bin/kill -TERM <pid>` (remote stop fallback, only on `.failed`) | argv | HermesFileService.swift:3104-3111 | — | OK |
| `hermes gateway status` (✓/✗ markers, manual-mode line, multiplexer line, parked, standalone box) | argv/output | GatewayViewModel.swift:306-426 | gateway.py:5020-5073,1582-1595 | OK |
| `hermes gateway start` | argv/output | GatewayViewModel.swift:487,532-605; HermesCLIOutcome.swift (gatewayStartSuccess) | gateway.py:4763-4794; gateway_launchd.py:656-701 | OK |
| `hermes gateway stop` | argv/output | GatewayViewModel.swift:489; HermesFileService.swift:3081-3115 | gateway.py:4797-4832; gateway_launchd.py:707-721 | OK |
| `hermes gateway restart` | argv/output | GatewayViewModel.swift:491; HermesFileService.swift:1456; PlatformsViewModel.swift:276-299 | gateway.py:4909-4981; gateway_launchd.py:743-800 | FINDING-T5-F1 |
| `hermes gateway list` | argv | GatewayViewModel.swift:236-238 (HermesGatewayListService) | gateway.py:1610+ | OK |
| `hermes pairing list` | argv/output | GatewayViewModel.swift:234,431-485 | hermes_cli/pairing.py:22-53 | FINDING-T5-F2 |
| `hermes pairing approve -- <platform> <code>` | argv | GatewayViewModel.swift:623 | pairing.py:56-81; subcommands/pairing.py | OK |
| `hermes pairing revoke -- <platform> <user>` | argv | GatewayViewModel.swift:648 | pairing.py:84-90 | OK |
| `hermes config set <key> <value>` (all forms) | argv | PlatformSetupHelpers.swift:139-151 | hermes_cli/config.py `_cmd_config_set` | OK |
| `WEBHOOK_ENABLED/PORT/SECRET` (.env) + `platforms.webhook.enabled` | env/config | WebhookSetupViewModel.swift:61-88 | gateway/config_env.py:318-327; hermes_cli/webhook.py:54-55 | OK |
| `WHATSAPP_CLOUD_*` (.env), `platforms.whatsapp_cloud.{enabled,extra.*}` | env/config | WhatsAppCloudSetupViewModel.swift:130-275 | gateway/config_env.py:182-207,523-533 | OK |
| `SIGNAL_HTTP_URL/ACCOUNT/ALLOWED_USERS/GROUP_ALLOWED_USERS/HOME_CHANNEL/ALLOW_ALL_USERS`, `platforms.signal.extra.require_mention` | env/config | SignalSetupViewModel.swift:56-111 | config_env.py:536-543; gateway/platforms/signal.py:191-197; authz_mixin.py:32-35 | OK |
| `signal-cli link` / `daemon` (local-only, remote disabled) | argv | SignalSetupViewModel.swift:126-162 | — (external) | OK |
| Identifying env vars for "configured" dots | env | PlatformsViewModel.swift:211-243 | config_env.py table | OK |
| `hermes webhook list` | argv/output | WebhooksViewModel.swift:89; HermesWebhookList.swift:128-228; iOS WebhooksView.swift:111-124 | hermes_cli/webhook.py:210-235,73-97 | OK (iOS copy FINDING-T5-F3) |
| `hermes webhook subscribe … -- <name>` | argv/output | WebhooksViewModel.swift:146-214,236-249 | subcommands/webhook.py:17-50; webhook.py:115-205 | OK |
| `hermes webhook remove/test -- <name>` | argv | WebhooksViewModel.swift:261-300 | webhook.py:238-260 | OK |
| `hermes gateway setup` (Terminal / `ssh -t`) | argv | GatewaySetupTerminalCommand.swift:21-42 | hermes_cli/gateway_setup_wizard.py | OK |
| `hermes tools list --platform <p>` | argv/output | ToolsViewModel.swift:185; HermesToolsList.swift:18-49 | subcommands/tools.py:21-23; tools_config_mcp.py:187-221,241-258 | OK |
| `hermes tools enable|disable <ts> --platform <p>` | argv/output | ToolsViewModel.swift:61-96 | tools_config_mcp.py:241-285 | OK |
| `hermes mcp list` (raw text shown) | argv | ToolsViewModel.swift:191 | — | OK |
| Watched paths (gateway_state.json own + root, config.yaml, .env, gateway.log, …) | file | HermesFileWatcher.swift:103-134,224-263 | — | OK |
| `hermes whatsapp` (pairing terminal, local only) | argv | EmbeddedSetupTerminal.swift:57-125 (via WhatsAppSetupViewModel.swift:121-135) | subcommands/whatsapp.py; main_platform_setup.py:125 | OK |

## Not audited / couldn't verify
- `HermesFileService.restartGateway()` uses a 30 s cap, but the Gateway view uses 60 s. `launchd_restart`'s SIGUSR1 path waits for `drain + after_turn + 15 s` (`gateway/restart.py:358-361`) and then up to 15 s more for a new PID (`gateway_launchd.py:767-770`). With a messaging turn in flight, the Platforms/MCP "Restart Gateway" could time out and show "Restart failed" while the restart is actually proceeding. I didn't resolve the default `restart_after_turn_timeout`, so this isn't filed as a finding.
- A named-profile gateway started with `HERMES_HOME` in its environment (no `-p`) also matches the DEFAULT profile's pgrep pattern, so a default window could borrow its PID. It needs an unusual launch and was not pursued.
- Profile pinning for Mac local `runHermes` / SSH / Citadel was not re-traced. It belongs to T6's area; I only confirmed the transports call `HermesProfileScope.pinnedRemoteArguments`.
- Platform forms outside the manifest (Discord, Telegram, Slack, Email, Matrix, Mattermost, Feishu, HomeAssistant, iMessage/BlueBubbles, Ntfy, SimpleX, GatewayBehavior) were not re-audited beyond the shared `PlatformSetupHelpers` save path.
