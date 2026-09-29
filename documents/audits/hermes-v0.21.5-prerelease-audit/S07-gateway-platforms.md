# S07-gateway-platforms — verdict: WORKS

Reference: Hermes worktree `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (0.21.5). Probes: `hermes auth spotify --help`, `hermes webhook subscribe --help`, `hermes gateway list --help`, `hermes whatsapp --help`, `hermes auth --help` (all LIVE, match Scarf argv).

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Gateway status badge (running / loaded / served-by-multiplexer / parked / standalone warning) | WORKS | — |
| 2 | Gateway start / stop / restart incl. launchd drain + restart guard | WORKS | — |
| 3 | Telegram setup form (.env creds + telegram.* / platforms.telegram.extra.* toggles, env-first resolution) | WORKS | — |
| 4 | Discord setup form | WORKS | — |
| 5 | Slack setup form (shared-key bridge resolution) | WORKS | — |
| 6 | WhatsApp (Baileys) + WhatsApp Cloud setup, `hermes whatsapp` pairing terminal | WORKS | — |
| 7 | Other platforms (Matrix, Mattermost, Signal, SimpleX, Email, Feishu, HA, iMessage/BlueBubbles, Ntfy, Webhook) | WORKS | — |
| 8 | Allowlists (top-level `<platform>.allowed_*` direct YAML write, .env override move) + busy-ack / restart-notification | WORKS | — |
| 9 | Webhooks list / subscribe / remove / test (Mac) and list (iOS) | WORKS | — |
| 10 | Spotify sign-in (`hermes auth spotify [--client-id=]`, auth.json confirm) | WORKS | — |

## Findings
None. No P0–P3 defect could be proven against the tag. Every hypothesis I raised was disproved:
- Gateway status markers match `hermes_cli/gateway.py:5039,5056-5057,5064`. The parked early return matches `gateway_profile_lifecycle.py:87` (Scarf accepts it only when it is the whole output, which correctly excludes the default profile's satellite lines at :97). `_print_other_profiles_gateway_status` (`gateway.py:1593`) prints `  ✓ <profile> — PID`, which never contains the `✓ Gateway is running` substring.
- Start/stop/restart success markers match launchd (`gateway_launchd.py:680,721,768,779,797`) and the manual/profile branches (`gateway.py:4830-4839,4977-4980`). The exit-0 refusal arms and the `Starting gateway...` foreground arm are handled as unconfirmed rather than success (`HermesCLIOutcome.swift:1789+`).
- Every `.env` key the 17 setup view models write is read somewhere in `gateway/` or `plugins/platforms/` at the tag. `SIGNAL_ALLOW_ALL_USERS` is derived (`gateway/authz_mixin.py:35`), and `SIMPLEX_HOME_CHANNEL_NAME` follows the `_HOME_CHANNEL[_NAME]` convention (`plugins/platforms/simplex/adapter.py:7`). Config keys are read too: telegram rich_messages/status_indicator/disable_topic_auto_rename, slack reply_broadcast, HA watch_all/cooldown_seconds, ntfy markdown/publish_topic, email skip_attachments, signal require_mention and discord history_backfill/auto_thread each have a reader. The one key without a reader, `allow_any_attachment` (discord), is written only inside its capability window (`DiscordSetupViewModel.swift:158`).
- Root-level `<platform>:` blocks are promoted wholesale into `extra` (`gateway/config_loader.py:226-242`), so `telegram.*`/`discord.*`/`matrix.*` keys and Scarf's top-level `allowed_*` lists are read. Scarf rewrites nested shared keys onto the bridged section (`HermesPlatformSharedKeys.swift`, `PlatformSetupHelpers.resolveSharedKeys`), in line with `platform_section` (`config_loader.py:182-191`).
- The allowlist readers are discord `_gate_raw` (`discord/adapter.py:4845-4866`, env first), telegram `_extra_str_set` (:5778), slack (:6259), mattermost (:499), matrix (:873) and dingtalk (:267). They match `PlatformEnvAllowlist` precedence.
- `display.busy_ack_enabled` is bridged at `gateway/run.py:1962`. `<platform>.gateway_restart_notification` is a shared key (`config_loader.py:223`, `config.py:478`). The bare `unauthorized_dm_decline_message` is read at `config.py:789` / `run_inbound.py:140`.
- For webhooks, the subscribe success is judged by the `Secret:` line (`hermes_cli/webhook.py:217`), and every failure arm is an exit-0 `Error:` print. The list parser matches `_cmd_list` (:224-246; the Profile line is ignored harmlessly). Remove matches :255. The enabled gate reads only `platforms.webhook.enabled` (:51-56), which Scarf's Webhook form writes and the iOS copy explains.
- For Spotify, the argv matches the live `--help`. Hermes stores the token under `providers.spotify` in HERMES_HOME's auth.json (`auth_spotify.py:382-385`), which is what Scarf polls.
- The gateway_state.json fields Scarf reads (`gateway_state`, `exit_reason`, `pid`, `start_time`, `updated_at`, `platforms`, `restart_requested`, `active_work` while draining) are written at `gateway/status.py:715-717,1080-1095` and `run.py:4009`.

## File coverage (mandatory — one row per manifest line, none skipped)
| File | Hermes touchpoints? (yes/no) | Status (OK / FINDING-id / TRACKED / NO-TOUCHPOINT) |
|---|---|---|
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/GatewayAllowlistKind.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/GatewayPlatformSettings.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/PlatformEnvSetting.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesGatewayParkedStatus.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesGatewayStandaloneWarning.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesGatewayStateProjection.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPlatformSharedKeys.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesWebhookList.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GatewayConfigWriter.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesGatewayListService.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesGatewayProcessMatch.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesGatewayRestartDrain.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesGatewayRestartGuard.swift | yes | OK |
| scarf/Scarf iOS/Webhooks/WebhooksView.swift | yes | OK |
| scarf/scarf/Core/Services/GatewayActionBanner.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/GatewayRestartDrainWatcher.swift | yes | OK |
| scarf/scarf/Core/Services/SpotifyAuthFlow.swift | yes | OK |
| scarf/scarf/Features/Gateway/ViewModels/GatewayViewModel.swift | yes | OK |
| scarf/scarf/Features/Gateway/Views/GatewayRestartDrainBanner.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Gateway/Views/GatewayView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/MCPServers/Views/RestartGatewayBanner.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/DiscordSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/EmailSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/FeishuSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/GatewayBehaviorViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/HomeAssistantSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/IMessageSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/MatrixSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/MattermostSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/NtfySetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/SignalSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/SimpleXSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/SlackSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/TelegramSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/WebhookSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/WhatsAppCloudSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/WhatsAppSetupViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/ViewModels/PlatformsViewModel.swift | yes | OK |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/Components/AllowlistEditor.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/Components/EnvOverrideCaption.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/Components/GatewayBehaviorSection.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/DiscordSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/EmailSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/EmbeddedSetupTerminal.swift | yes | OK |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/FeishuSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/HomeAssistantSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/IMessageSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/MatrixSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/MattermostSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/NtfySetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/SignalSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/SimpleXSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/SlackSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/TelegramSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/WebhookSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/WhatsAppCloudSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformSetup/WhatsAppSetupView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Platforms/Views/PlatformsView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Skills/Views/SpotifySignInSheet.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Webhooks/ViewModels/GatewaySetupTerminalCommand.swift | yes | OK |
| scarf/scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift | yes | OK |
| scarf/scarf/Features/Webhooks/Views/WebhooksView.swift | yes | OK |
| scarf/scarf/Core/Services/HermesFileService.swift lines 155-226 (Gateway State) (region only; file listed under S15) | yes | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `gateway status` | argv+parse | GatewayViewModel.swift:308,382-427 | hermes_cli/gateway.py:5019-5070 | OK |
| parked line | parse | HermesGatewayParkedStatus.swift:34-50 | gateway_profile_lifecycle.py:82-98 | OK |
| `gateway start/stop/restart` | argv+verdict | HermesCLIOutcome.swift:1789-1990; GatewayViewModel.swift:540-700 | gateway.py:4763-4981; gateway_launchd.py:656-800 | OK |
| restart guard `gateway status` + `status` | argv | HermesGatewayRestartGuard.swift:194,208 | gateway.py:5019; top-level `status` | OK |
| restart drain budget `agent.restart_drain_timeout` / `agent.restart_after_turn_timeout` | config read | HermesGatewayRestartDrain.swift:193-202 | gateway/run.py:1952,3403-3549 | OK |
| gateway_state.json fields | file read | GatewayViewModel.swift:279-304; HermesGatewayRestartDrain.swift:86-92; HermesFileService.swift:155-226 | gateway/status.py:715-717,1080-1095; run.py:4009 | OK |
| `gateway list` | argv+parse | HermesGatewayListService.swift:122-160,188 | gateway.py:1610-1640 | OK |
| platform .env keys (all forms) | .env | PlatformSetup/*ViewModel.swift | gateway/config_env.py:512-560; plugins/platforms/*/adapter.py | OK |
| platform config keys via `hermes config set` | config | PlatformSetupHelpers.swift:saveForm | config_loader.py:182-242 | OK |
| env-first precedence | logic | PlatformEnvSetting.swift | discord/adapter.py:4845-4866; telegram 5713-5778; matrix 873-951; slack 6240-6260; mattermost 499; ntfy 127 | OK |
| `<platform>.allowed_channels/chats/rooms` | direct YAML | GatewayConfigWriter.swift:294; GatewayBehaviorViewModel.save | same adapters as above | OK |
| `display.busy_ack_enabled`, `<p>.gateway_restart_notification` | config | GatewayBehaviorViewModel.save | run.py:1962; config.py:478 | OK |
| `hermes whatsapp` / `gateway setup` terminal | argv | WhatsAppSetupViewModel.swift:255; GatewaySetupTerminalCommand.swift:22 | live --help | OK |
| `webhook list/subscribe/remove/test` | argv+parse | WebhooksViewModel.swift:92,205-221,326,348; HermesWebhookList.swift; iOS WebhooksView.swift:121 | hermes_cli/webhook.py:127-270 | OK |
| `auth spotify [--client-id=]`, auth.json providers.spotify | argv+file | SpotifyAuthFlow.swift:177,469,498 | auth_spotify.py:314-385; live --help | OK |

## Not audited / couldn't verify
- Runtime behaviour was not exercised; this is a source trace only. Verdicts on SwiftUI view files are limited to confirming that they carry no Hermes touchpoints.
- The systemd/Windows/s6 status and restart branches were checked only for marker parity, not traced end to end (outside the mainstream macOS path).
- The HermesGatewayStateProjection root-record projection for multiplexer-served profiles was read but not traced line by line against `gateway/status.py`.
