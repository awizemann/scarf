# S07-gateway-platforms — verdict: WORKS-WITH-ISSUES

Reference: Hermes worktree `~/.hermes/hermes-agent-v0215` @ `v2026.9.24` (0.21.5). Probes run: `hermes whatsapp --help`, `hermes auth spotify --help`, `hermes webhook subscribe --help`; one read of the live `~/.hermes/gateway_state.json` (key names only, no secrets).

The core gateway and the most-used platform journeys work: start/stop/restart argv, `gateway status` markers, `gateway list` parsing, pairing, the Telegram/Discord/Slack/WhatsApp forms (every `.env` name and config key traced to a reader), allowlists, gateway behaviour toggles, Mac webhook list/subscribe/remove, and Spotify auth. I found five real defects. None is P0. One is P1 (WhatsApp Cloud). The other four are P2 and are mostly status shown wrong or a secondary surface that doesn't work.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Gateway start/stop/restart (`gateway start|stop|restart`) + banner | WORKS | — (verdict logic in HermesCLIOutcome is S15's) |
| 2 | Gateway status (`gateway status` markers + `gateway_state.json`) | WORKS (default profile) / DEGRADED (named profile) | F2 |
| 3 | `gateway list` multi-profile header | WORKS | — |
| 4 | Pairing list / approve / revoke | WORKS | — |
| 5 | Platforms sidebar connectivity dots + error detail | BROKEN (display) | F1, F2 |
| 6 | Telegram setup | WORKS | — |
| 7 | Discord setup (+ `discord.allowed_channels`) | WORKS | — |
| 8 | Slack setup (+ allowlist, shared-key resolver) | WORKS | — |
| 9 | WhatsApp (Baileys) setup + `hermes whatsapp` pairing | WORKS | — |
| 10 | WhatsApp Cloud setup | DEGRADED | F3 |
| 11 | Signal / Matrix / Mattermost / Email / Home Assistant / iMessage(BlueBubbles) / Feishu / ntfy / SimpleX setup | WORKS | — |
| 12 | Webhook platform setup → Webhooks tab | BROKEN (setup form can't unlock the tab) | F4 |
| 13 | Gateway behaviour (allowlist YAML writer, `display.busy_ack_enabled`, `<platform>.gateway_restart_notification`) | WORKS | — |
| 14 | Webhooks list/subscribe/remove/test (Mac) | WORKS | — (t-fc4d3a6f still open for subscribe's failure message) |
| 15 | Webhooks list (iOS) | BROKEN | F5 |
| 16 | Spotify auth (`hermes auth spotify`) | WORKS | — |

## Findings

### S07-F1 · P2 · LIVE+SOURCE · NEW
- Claim: `PlatformState` decodes `connected` (a Bool) and `error` (a String), but Hermes writes per-platform `state`, `error_code` and `error_message`. As a result, the Platforms sidebar and the Tools platform picker never show a platform as Connected or in Error.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift:2280-2289` (decodes `connected`/`error`); consumers `scarf/scarf/Features/Platforms/ViewModels/PlatformsViewModel.swift:94-97` and `scarf/scarf/Features/Tools/ViewModels/ToolsViewModel.swift:161-164`.
- Hermes @v2026.9.24: `gateway/status.py:1102-1120` writes `platforms[<name>] = {state, error_code, error_message, needs_attention, retrying_since, …}`. No `connected` or `error` key exists.
- Failure scenario: Telegram is connected and healthy. The sidebar dot stays orange ("configured") and never turns green. If a platform goes `fatal` with an `error_message`, the red error state and its message never appear either. The Gateway tab reads the same file correctly (`GatewayViewModel.swift:296` reads `info["state"]`), so the two screens disagree.
- Evidence: the live `~/.hermes/gateway_state.json` platform entry has keys `['error_code','error_message','needs_attention','retrying_since','state','updated_at','writer_pid','writer_start_time']` with `state: connected`. Scarf's own test fixture `scarfTests/GatewayParkedProfileP2Tests.swift:25` already uses `{"state": "connected"}`.
- Suggested fix: decode `state` and `error_message`; set connected = `state == "connected"` and error = non-empty `error_message` (or `state == "fatal"`).

### S07-F2 · P2 · SOURCE+LIVE · NEW
- Claim: For a named profile served by the default multiplexer (the normal 0.21.x topology), Scarf reads `<profile home>/gateway_state.json`. Hermes never writes that file. The profile's platform states live in the root `gateway_state.json` under `<profile>:<platform>` keys, so the Gateway tab's platform list is always empty for named profiles and the Platforms dots can't reflect them.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesPathSet.swift:73` (`home + "/gateway_state.json"`); `scarf/scarf/Features/Gateway/ViewModels/GatewayViewModel.swift:276-300`; `scarf/scarf/Core/Services/HermesFileService.swift:157-165`.
- Hermes @v2026.9.24: `gateway/status.py:1236-1239` ("a served profile writes no runtime record of its own, so its platform states live there under `<profile>:<platform>` keys"); `:1259-1291` `multiplexer_liveness_for_profile` reads the root file; `:1320-1330` `profile_platforms_from_multiplexer` re-keys the entries.
- Failure scenario: A user runs Telegram on the `seo-research-bot` profile and opens Scarf scoped to that profile. The gateway reports "running" (correct, via the `via the default-profile multiplexer` marker), but the Platforms list shows nothing and every dot shows only "configured".
- Evidence: live host with 6 served profiles has no `~/.hermes/profiles/*/gateway_state.json`; the root file carries `served_profiles: ['default','bot-test','gateway',…]`.
- Suggested fix: when `gateway status` says multiplexer-served, read the root home's `gateway_state.json` and filter the `<profile>:` prefix (mirroring `profile_platforms_from_multiplexer`). Fix F1 first.

### S07-F3 · P1 · SOURCE · NEW (supersedes premise of `.memory/decisions/section-audit-remediation-2026-09.md:43`)
- Claim: The WhatsApp Cloud form is config-only and assumes Hermes reads no WhatsApp Cloud environment variables. At the tag, Hermes's own `hermes whatsapp-cloud` wizard stores every credential and the allowlist in `.env`, and the gateway reads them. A WhatsApp Cloud setup made the Hermes way therefore opens in Scarf as a blank form. Saving it can explicitly disable the working adapter or override the allowlist.
- Scarf: `scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/WhatsAppCloudSetupViewModel.swift:56` (`loadSnapshot(includeEnv: false)`), `:65` (blank `dm_policy` becomes `"open"`), `:77` (the stale comment says the adapter "reads all six credentials out of the config section and NOTHING from the environment"), `:95` (`enabled: configured ? "true" : "false"`), `:104` (`extra.allow_from` is written even when blank); `PlatformsViewModel.swift:~225-233` (no env arm for `whatsapp_cloud`, so an env-only setup also shows "not configured").
- Hermes @v2026.9.24:
  - `gateway/config_env.py:523-533` maps `WHATSAPP_CLOUD_PHONE_NUMBER_ID`, `_ACCESS_TOKEN`, `_APP_ID`, `_APP_SECRET`, `_WABA_ID`, `_VERIFY_TOKEN` and `_API_VERSION` into `extra` and enables the platform from env.
  - `hermes_cli/setup_whatsapp_cloud.py:144-150` saves each credential with `save_env_value`, and `:269-285` saves `WHATSAPP_CLOUD_ALLOWED_USERS`.
  - `gateway/config_env.py:182-207`: an explicit `platforms.<x>.enabled: false` beats env creds, and `_warn_explicit_disable_beats_env` warns about it at `:60-76`.
  - `gateway/platforms/whatsapp_common.py:113-119`: a config `allow_from` key wins by presence ("an explicit empty list stays authoritative") over the env allowlist.
  - `gateway/platforms/whatsapp_cloud.py:185-195`: with no allowlist, `dm_policy` defaults to `"open"`.
- Failure scenario: The user set up WhatsApp Cloud with `hermes whatsapp-cloud`, so creds and allowlist are in `.env` and the adapter runs. In Scarf the form shows empty fields and DM policy "open". The user changes anything and hits Save without retyping the token. Scarf writes `platforms.whatsapp_cloud.enabled: false`, and the adapter stops at the next gateway restart, while the banner says "Saved — restart gateway to apply". If the user does retype the creds, Scarf still writes `extra.allow_from: ""` and `extra.dm_policy: open`. That replaces the wizard's `WHATSAPP_CLOUD_ALLOWED_USERS` allowlist at the adapter layer. The gateway-level authz may still apply the env list; I didn't trace that.
- Suggested fix: add the env half to load/save, using the `WHATSAPP_CLOUD_*` names from `config_env.py:523-533` and `WHATSAPP_CLOUD_ALLOWED_USERS`. Move the secrets to `.env`, which also closes the argv-secret exposure the decision note calls "unfixable". Don't write `allow_from`/`dm_policy` keys the user left blank. Update the decision note, whose premise was true at v2026.8.31 but is now stale.

### S07-F4 · P2 · SOURCE · NEW (related: `tasks/t-fc4d3a6f.md`, which covers only the failure *message*)
- Claim: Scarf's Webhook platform setup form only writes `WEBHOOK_ENABLED` to `.env`. Every `hermes webhook` verb is gated on `platforms.webhook.enabled` in config.yaml alone. So enabling webhooks in Scarf (or with Scarf's "Run Setup in Terminal" button, which runs `hermes gateway setup` and is also env-only) never unlocks the Webhooks tab.
- Scarf: `scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/WebhookSetupViewModel.swift:48-54`; `scarf/scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift:89-91` (`detectNotEnabled`); `scarf/scarf/Features/Webhooks/Views/WebhooksView.swift:103-140` (setup-required state → `hermes gateway setup`).
- Hermes @v2026.9.24: `hermes_cli/webhook.py:44-55` (`_is_webhook_enabled` reads `cfg_get(cfg, "platforms", "webhook")["enabled"]` only); `:105-107` (every action prints `_setup_hint()` and returns). The gateway itself does accept the env flag (`gateway/config_env.py:318-327`), and Hermes's own wizard writes only env (`hermes_cli/setup_platforms.py:241`). The root inconsistency is upstream, but Scarf's form is the path that leaves the user stuck.
- Failure scenario: The user enables Webhooks in Platforms → Webhook and saves ("Saved — restart gateway to apply"). The gateway listener comes up on 8644, but the Webhooks tab still shows "Webhook platform not enabled", and Subscribe fails with the setup hint's last line.
- Suggested fix: have the Webhook form also `config set platforms.webhook.enabled true|false`, and keep `WEBHOOK_PORT`/`WEBHOOK_SECRET` in `.env`.

### S07-F5 · P2 · SOURCE · NEW
- Claim: The iOS Webhooks list parser expects each subscription name on a non-indented line. `hermes webhook list` indents every line (`  ◆ name`, `    URL: …`), so iOS never parses any subscription. It shows "Couldn't parse webhook list output" whether or not subscriptions exist, including the "No dynamic webhook subscriptions." case.
- Scarf: `scarf/Scarf iOS/Webhooks/WebhooksView.swift:127-172` (the parser opens a record only when `!line.hasPrefix(" ")`, at `:152`); `:94-97` sets `lastError` when parsed is empty and output isn't.
- Hermes @v2026.9.24: `hermes_cli/webhook.py:208-234` (`_cmd_list`: `"  No dynamic webhook subscriptions."`, `"  ◆ {name}"`, `"    URL:     …"`, `"    Events:  …"`, `"    Deliver: …"`).
- Failure scenario: A host has two subscriptions, and ScarfGo's Webhooks screen shows an error with an empty list. A host with none shows the same parse error instead of the empty state.
- Suggested fix: use the shared `HermesWebhookList.parse` and `isEmptyListing`, which already handle the real format on Mac.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `gateway start|stop|restart` | argv | ScarfCore `Services/HermesCLIOutcome.swift:1777`; `GatewayViewModel.swift` runServiceAction | `hermes_cli/gateway.py:5108-5112` | OK (verdict: S15) |
| `gateway status` markers `✓ Gateway is running`, `✗ Gateway is not running`, `via the default-profile multiplexer`, `(Running manually, not as a system service)` | argv/output | `GatewayViewModel.swift` isGatewayRunning/isServiceLoaded/isServedByMultiplexer | `hermes_cli/gateway.py:5039,5056-5057,5064` | OK |
| `gateway list` (`✓/✗ name (current) — PID n / served by the default multiplexer / not running`) | argv/output | `HermesGatewayListService.swift:51-132` | `hermes_cli/gateway.py:1610-1643` | OK |
| `gateway_state.json` top-level (`pid`, `gateway_state`, `exit_reason`, `updated_at`, `start_time`) | file | `HermesFileService.swift:157-189`; `GatewayViewModel.swift:276-300` | `gateway/status.py:1055-1120` | OK |
| `gateway_state.json` `platforms.<p>.state` | file | `GatewayViewModel.swift:296` | `gateway/status.py:1110` | OK |
| `gateway_state.json` `platforms.<p>.connected/error` | file | `HermesConfig.swift:2280-2289` | none (keys are `state`/`error_message`) | FINDING-F1 |
| named-profile `gateway_state.json` | file | `HermesPathSet.swift:73` | `gateway/status.py:1236-1291` | FINDING-F2 |
| `pairing list` table parse | argv/output | `GatewayViewModel.swift` parsePairing | `hermes_cli/pairing.py:22-53` | OK |
| `pairing approve -- <p> <request-id>` / `pairing revoke -- <p> <uid>` | argv | `GatewayViewModel.swift` approvePairing/revokeUser | `hermes_cli/pairing.py:56-90` | OK |
| `<platform>.allowed_channels` (slack/mattermost/discord), `telegram|dingtalk.allowed_chats`, `matrix.allowed_rooms` | config (direct YAML) | `GatewayConfigWriter.swift`, `GatewayAllowlistKind.swift:105-111` | `gateway/config_loader.py:219-238` (root block → extra); slack `adapter.py:6259`, discord `:4864`, mattermost `:499`, telegram `:5775`, matrix `:873`, dingtalk `:265` | OK |
| `display.busy_ack_enabled` | config | `GatewayBehaviorViewModel.swift` save | `gateway/run.py:1959-1962` | OK |
| `<platform>.gateway_restart_notification` | config | `GatewayBehaviorViewModel.swift` restartNotificationKey | `gateway/config.py:446-478` (typed, top-level-or-extra), `config_loader.py:215` | OK |
| `_SHARED_KEYS` roster mirror | model | `HermesPlatformSharedKeys.swift:5-17` | `gateway/config_loader.py:201-215` | OK (identical) |
| `hermes config set -- <key> <value>` (all forms) | argv | `PlatformSetupHelpers.swift:~120-131` | `hermes_cli/config.py:3479-3560` | OK (judge: S05/S15) |
| TELEGRAM_BOT_TOKEN/ALLOWED_USERS/HOME_CHANNEL/WEBHOOK_URL/PORT/SECRET; `telegram.require_mention/reactions/disable_topic_auto_rename`; `platforms.telegram.extra.rich_messages/status_indicator/ignore_root_dm` | env/config | `TelegramSetupViewModel.swift:79-120` | `config_env.py:513-516`; telegram `adapter.py:566,649,3142-3150,7090,7236,7252` | OK |
| DISCORD_BOT_TOKEN/ALLOWED_USERS/HOME_CHANNEL(_NAME)/ALLOW_BOTS/REPLY_TO_MODE; `discord.require_mention/free_response_channels/auto_thread/reactions/history_backfill`; `platforms.discord.extra.allow_any_attachment` | env/config | `DiscordSetupViewModel.swift:78-122` | `config_env.py:156-163,517-519`; discord `adapter.py:4914,7270-7300` | OK |
| SLACK_BOT_TOKEN/APP_TOKEN/ALLOWED_USERS/HOME_CHANNEL(_NAME); `platforms.slack.reply_to_mode/require_mention/extra.reply_in_thread/extra.reply_broadcast` | env/config | `SlackSetupViewModel.swift:38-64` | `config_env.py:280-292,535`; `config.py:446`; slack `adapter.py:1779,2277,4202` | OK |
| WHATSAPP_ENABLED/MODE/ALLOWED_USERS/ALLOW_ALL_USERS; `whatsapp.unauthorized_dm_behavior/reply_prefix`; bare `unauthorized_dm_decline_message`; `hermes whatsapp` | env/config/argv | `WhatsAppSetupViewModel.swift:63-134` | `config_env.py:267-277`; whatsapp `adapter.py:283,393`; `gateway/config.py:626,789`; `hermes whatsapp --help` (LIVE) | OK |
| `platforms.whatsapp_cloud.enabled` + `extra.{phone_number_id,access_token,verify_token,app_secret,app_id,waba_id,api_version,dm_policy,allow_from}` | config | `WhatsAppCloudSetupViewModel.swift:56-104` | `whatsapp_cloud.py:168-195`; `config_env.py:523-533` | FINDING-F3 |
| SIGNAL_* (HTTP_URL, ACCOUNT, ALLOWED_USERS, GROUP_ALLOWED_USERS, HOME_CHANNEL, ALLOW_ALL_USERS); `platforms.signal.extra.require_mention`; local `signal-cli link/daemon` | env/config/argv | `SignalSetupViewModel.swift` | `config_env.py:537-543`; `authz_mixin.py:32-35`; `signal.py:194-196` | OK |
| MATRIX_* (HOMESERVER, ACCESS_TOKEN, USER_ID, PASSWORD, ALLOWED_USERS, HOME_ROOM, ENCRYPTION, RECOVERY_KEY); `matrix.require_mention/auto_thread/dm_mention_threads` | env/config | `MatrixSetupViewModel.swift` | `config_env.py:295-297,550-557`; matrix `adapter.py:877-879,950` | OK |
| MATTERMOST_* (URL, TOKEN, ALLOWED_USERS, HOME_CHANNEL, FREE_RESPONSE_CHANNELS, REPLY_MODE); `mattermost.require_mention` | env/config | `MattermostSetupViewModel.swift:51-107` | `config_env.py:544-549`; mattermost `adapter.py:499,701-704` | OK |
| EMAIL_* (ADDRESS, PASSWORD, IMAP/SMTP host+port, POLL_INTERVAL, ALLOWED_USERS, ALLOW_ALL_USERS, HOME_ADDRESS); `platforms.email.extra.skip_attachments` | env/config | `EmailSetupViewModel.swift:76-136` | `config_env.py:559-563`; email `adapter.py:355` | OK |
| HASS_TOKEN/HASS_URL; `platforms.homeassistant.extra.watch_all/cooldown_seconds` | env/config | `HomeAssistantSetupViewModel.swift` | `config_env.py:558`; homeassistant `adapter.py:109-110` | OK |
| BLUEBUBBLES_* (SERVER_URL, PASSWORD, WEBHOOK_HOST/PORT/PATH, SEND_READ_RECEIPTS, ALLOWED_USERS, ALLOW_ALL_USERS, HOME_CHANNEL) | env | `IMessageSetupViewModel.swift` | `config_env.py:611-624` | OK |
| FEISHU_* (APP_ID, APP_SECRET, DOMAIN, CONNECTION_MODE, ENCRYPT_KEY, VERIFICATION_TOKEN, ALLOWED_USERS) | env | `FeishuSetupViewModel.swift` | `config_env.py:575-582` | OK |
| NTFY_TOPIC/SERVER_URL/TOKEN; `platforms.ntfy.extra.{server,topic,token,publish_topic,markdown}` | env/config | `NtfySetupViewModel.swift` | ntfy `adapter.py:99-128,279` | OK |
| SIMPLEX_* (WS_URL, ALLOWED_USERS, ALLOW_ALL_USERS, AUTO_ACCEPT, GROUP_ALLOWED, HOME_CHANNEL(_NAME)), HERMES_SIMPLEX_TEXT_BATCH_DELAY | env | `SimpleXSetupViewModel.swift` | simplex `adapter.py:7,611`; `config_env.py:156-163` | OK |
| WEBHOOK_ENABLED/PORT/SECRET | env | `WebhookSetupViewModel.swift:42-54` | `config_env.py:318-327` (gateway OK); `hermes_cli/webhook.py:44-55,105` (CLI gate) | FINDING-F4 |
| `webhook list` output (`◆`, `URL:`, `Events:`, `Deliver:`, `Script:`, empty listing) — Mac | argv/output | `HermesWebhookList.swift`; `WebhooksViewModel.swift:89` | `hermes_cli/webhook.py:208-234` | OK |
| `webhook list` — iOS | argv/output | `Scarf iOS/Webhooks/WebhooksView.swift:100-172` | `hermes_cli/webhook.py:208-234` | FINDING-F5 |
| `webhook subscribe [--prompt --events --description --skills --deliver --deliver-chat-id --secret] -- <name>`; parse `Secret:`/`URL:` | argv/output | `WebhooksViewModel.swift` subscribe/parseCreatedSecret | `hermes_cli/webhook.py:113-205`; `--help` (LIVE) | OK (failure-message wording → TRACKED t-fc4d3a6f) |
| `webhook remove|test` | argv | `WebhooksViewModel.swift` remove/test (HermesWebhook*Verdict) | `hermes_cli/webhook.py:237-272` | OK |
| `webhook` not-enabled detection | output | `WebhooksViewModel.swift` detectNotEnabled; iOS twin | `hermes_cli/webhook.py:_setup_hint` ("Webhook platform is not enabled") | OK |
| `auth spotify` (→ login); token check `auth.json providers.spotify.access_token` | argv/file | `SpotifyAuthFlow.swift:170-171,455-466` | `hermes_cli/auth_commands.py:702-710`; `auth_spotify.py:122-137,314-387`; `auth.py:481,786-789`; `--help` (LIVE) | OK |
| authorize-URL detection `https://accounts.spotify.com/authorize?…` | output | `SpotifyAuthFlow.swift:402-409` | `auth_spotify.py:87-96,341-344` | OK |
| Platform roster (`KnownPlatforms`) vs `Platform` enum | model | `HermesTool.swift` | `gateway/config.py:194-217` | OK (missing only `wecom_callback`, `relay` (experimental) and plugins `a2a`/`raft`, P3 at most, not filed) |

## Not audited / couldn't verify
- `HermesGatewayServiceVerdict`, `HermesConfigSet.judge`, `HermesWebhook*Verdict` and `HermesPairingVerdict` marker logic live in `HermesCLIOutcome.swift`, which S15 owns. I only checked the argv and that the markers exist.
- `HermesFileService.restartGateway` (`:1114`) is outside my assigned line range.
- F3: I didn't trace whether gateway-level authz (`gateway/authz_mixin.py`, `pairing.py:69` maps `whatsapp_cloud` → `WHATSAPP_CLOUD_ALLOWED_USERS`) still enforces the env allowlist after the adapter's `allow_from` is overridden. So I don't claim a security exposure, only the adapter-layer override and the explicit disable.
- The type coercion of `hermes config set` values (`_coerce_config_set_value`) is assumed to turn `"true"`/`"false"`/ints into typed YAML. S05 owns it.
- Remote (SSH) behaviour of the local-only spawns (WhatsApp pairing, signal-cli) is refused on remote by design (`PlatformSetupHelpers.remoteOnlyHostNotice`), so I didn't exercise it.
- Minor, not filed: the WhatsApp form defaults `mode` to `"bot"` when `WHATSAPP_MODE` is unset, while Hermes defaults to `self-chat` (`whatsapp/adapter.py:393`). `hermes whatsapp` always writes the key (`hermes_cli/main_platform_setup.py:49,64`), so this only affects hand-made `.env` files.
