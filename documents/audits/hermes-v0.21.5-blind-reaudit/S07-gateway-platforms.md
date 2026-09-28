# S07-gateway-platforms — verdict: WORKS-WITH-ISSUES

Scope: Gateway status/start/stop/restart, `gateway list`, gateway_state.json, pairing, per-platform setup forms
(Telegram, Discord, Slack, WhatsApp, WhatsApp Cloud, Signal, Matrix, Mattermost, Email, Home Assistant,
iMessage/BlueBubbles, Feishu, ntfy, SimpleX, Webhook), gateway behaviour section (allowlists, busy-ack,
restart notification), webhooks list/subscribe/remove/test (Mac + iOS), Spotify auth.
Hermes reference: `~/.hermes/hermes-agent-v0215` @ `v2026.9.24`.

The main platforms (Telegram, Discord, Slack, WhatsApp) write the right `.env` names and config keys, at
paths Hermes reads, with value types it accepts. The gateway service verbs and the status and list
parsers match the current CLI output. Every defect found is P2 or P3: a secondary setting that does
nothing, a result shown as failed when it is only pending, or a secondary flow that can't finish.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Gateway status (state.json + `gateway status` text: running / not running / manual / multiplexer / parked / launchd / systemd) | WORKS | — |
| 2 | Gateway start / stop | WORKS | — |
| 3 | Gateway restart (Gateway pane + Platforms "Restart gateway") | DEGRADED | F3 |
| 4 | `gateway list` roster parse | WORKS | — |
| 5 | Pairing list / approve / revoke | WORKS | — |
| 6 | Telegram setup (env + `telegram.*` + `platforms.telegram.extra.*`) | WORKS | — |
| 7 | Discord setup (env + `discord.*`) | WORKS | — |
| 8 | Slack setup (env + `platforms.slack.*`) | DEGRADED | F1 |
| 9 | WhatsApp (bridge) setup | DEGRADED | F2, F7 |
| 10 | WhatsApp Cloud setup | WORKS | — |
| 11 | Signal / Matrix / Email / Home Assistant / ntfy / SimpleX / Webhook-platform setup | WORKS | — |
| 12 | Mattermost setup | DEGRADED | F4 |
| 13 | iMessage (BlueBubbles) setup | DEGRADED | F5 |
| 14 | Feishu setup | WORKS (edge default mismatch) | F7 |
| 15 | Gateway behaviour section (allowlists, busy-ack, restart notification) | WORKS | — |
| 16 | Webhooks list / subscribe / remove / test (Mac) | DEGRADED | F8 (+TRACKED t-fc4d3a6f) |
| 17 | Webhooks list (iOS) | WORKS | — |
| 18 | Spotify sign-in | DEGRADED | F6 |

## Findings

### S07-gateway-platforms-F1 · P2 · SOURCE · NEW
- Claim: Slack's "Reply Mode" picker writes `platforms.slack.reply_to_mode`, which the Slack adapter never reads, so the control does nothing.
- Scarf: `scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/SlackSetupViewModel.swift:73` (written); `scarf/scarf/Features/Platforms/Views/PlatformSetup/SlackSetupView.swift:33` (the picker).
- Hermes @v2026.9.24: `gateway/config.py:422,477` puts the value in `PlatformConfig.reply_to_mode`. The only code that reads it is `plugins/platforms/discord/adapter.py:1111`, `plugins/platforms/telegram/adapter.py:560` and `gateway/run_turn.py:3145` (`getattr(_adapter, "_reply_to_mode", "first")`). `plugins/platforms/slack/adapter.py` has no `reply_to_mode` / `_reply_to_mode` at all. Its YAML bridge (`:6710-6719`) doesn't list it, and there is no `SLACK_REPLY_TO_MODE` in `gateway/config_env.py`. Slack threading is controlled by `extra.reply_in_thread` / `reply_broadcast` (`adapter.py:2277,2717,2781,4202`).
- Failure scenario: the user sets Reply Mode to `off` and saves. The form says "Saved — restart gateway to apply" and reloads showing `off`, but Slack replies thread exactly as before.
- Evidence: `grep reply_to_mode plugins/platforms/slack/adapter.py` finds nothing. The memory note (`hermes-v0-21-1-compatibility-decisions.md:828-834`) says the nested key is "read" via `PlatformConfig`. That is true, but no Slack code reads the field afterwards.
- Suggested fix: remove the picker from the Slack form. "Reply in thread" already covers this behaviour.

### S07-gateway-platforms-F2 · P2 · SOURCE · NEW
- Claim: saving the WhatsApp form with Reply Prefix left blank writes `whatsapp.reply_prefix: ""`, which turns off Hermes's built-in "☤ *Hermes Agent*" header in self-chat mode.
- Scarf: `WhatsAppSetupViewModel.swift:90-93` writes `"whatsapp.reply_prefix": replyPrefix` on every save. An absent key loads as `""` (`HermesConfig+YAML.swift:730` via `str(...)`, `HermesConfig.swift:1060`). `saveForm` sends empty strings as `config set <key> ""` (`PlatformSetupHelpers.swift:51-53`).
- Hermes @v2026.9.24: `hermes_cli/config_defaults.py` comment for `whatsapp:` says `reply_prefix: None = built-in "☤ *Hermes Agent*" header; "" disables`. `reply_prefix` is a `_SHARED_KEYS` member, so it is bridged into `extra` (`gateway/config_loader.py:211`). `plugins/platforms/whatsapp/adapter.py:281` reads `extra.get("reply_prefix")`. `gateway/platforms/whatsapp_common.py:79-80` returns `""` whenever that value is not `None`, before it checks `WHATSAPP_REPLY_PREFIX` or the default. `_coerce_config_set_value` keeps `""` as a string (`hermes_cli/config.py:3248-3266`, no default for the key), and `_strip_default_values` keeps it too (`:1727`).
- Failure scenario: a self-chat WhatsApp user who set up with `hermes whatsapp` opens Scarf's form only to change the allowlist, and saves. From then on the bot's replies in their own chat have no header, so they can't be told apart from the user's own messages. Any `WHATSAPP_REPLY_PREFIX` in `.env` is also ignored now.
- Suggested fix: skip the key when the field is blank and the key was absent on load (the same way WhatsApp Cloud handles `dm_policy`), or unset it.

### S07-gateway-platforms-F3 · P2 · SOURCE · NEW
- Claim: restarting a service-managed gateway while an agent turn is running shows "Gateway restart failed". In fact Hermes has already signalled the gateway and is waiting (by default up to about 30 minutes) for the turn to finish before restarting it.
- Scarf: `GatewayViewModel.swift` (`runServiceAction`, `mutationTimeout` = 60 s) and `HermesFileService.swift:1492-1505` (`restartGateway`, timeout 60). The verdict (`HermesCLIOutcome.swift`, `HermesGatewayServiceVerdict.judge`) turns a timeout into "pending" only when `externallySupervised` is true, and Scarf sets that only for `--external-supervisor` gateways (`HermesGatewayRestartGuard.swift`, `isExternallySupervised`). The launchd and systemd services fall through to `.failed`.
- Hermes @v2026.9.24: `hermes_cli/gateway_launchd.py:744-790` (`launchd_restart`) prints `→ Stopping gateway (PID …) — draining in-flight runs (up to Ns)...`, sends SIGUSR1 and waits `_get_restart_exit_wait_budget()`. That budget is `restart_drain_timeout + restart_after_turn_timeout + 15` (`hermes_cli/gateway.py:3103-3114`, `gateway/restart.py:358-361`), and the default `restart_after_turn_timeout` is `1800` (`hermes_cli/config_defaults.py:103`). The systemd path drains the same way (`hermes_cli/gateway.py:~3283-3315`).
- Failure scenario: on a local Mac with the launchd service, a cron job or chat turn is running and the user saves a platform form and presses Restart. After 60 s Scarf shows the red "Gateway restart failed: Command timed out…". The gateway then restarts once the turn ends (launchd KeepAlive brings it back).
- Suggested fix: extend the existing "supervised restart pending" result to timeouts whose output contains the `draining in-flight runs` line (or `Stopping gateway (PID`), for the service-managed paths too.

### S07-gateway-platforms-F4 · P2 · SOURCE · NEW
- Claim: at v2026.9.24 the `.env` value wins over config.yaml for Mattermost's `require_mention`, but Scarf's form still assumes config.yaml wins. So a `MATTERMOST_REQUIRE_MENTION` line left in `.env` makes the toggle do nothing, and the form shows the wrong value.
- Scarf: `MattermostSetupViewModel.swift:52-85` loads config first and falls back to `.env`; `:101-108` writes config only and leaves the `.env` line as it is. The code comment cites `v2026.9.7` "config.extra FIRST".
- Hermes @v2026.9.24: `plugins/platforms/mattermost/adapter.py:29,503` → `gateway/platforms/_shared.py:106-128` `extra_or_secret`: "explicit env `env` → the profile's YAML `config.extra[key]` → default". It returns the env value whenever that value is non-blank. The YAML→env bridge also never overwrites an existing env var (`_shared.py:162-165`).
- Failure scenario: an earlier Scarf version wrote `MATTERMOST_REQUIRE_MENTION=true` to `.env` (the memory decision records that it did). The user now turns "Require @mention" off and saves. config.yaml gets `mattermost.require_mention: false`, and the form reloads showing off. The gateway still requires @mention because the `.env` value wins.
- Suggested fix: read `.env` first (matching Hermes), and on save either write the `.env` key or remove it.

### S07-gateway-platforms-F5 · P2 · SOURCE · NEW
- Claim: the iMessage (BlueBubbles) "Send read receipts" toggle shows OFF on a default host, where Hermes actually sends receipts, and turning it off can never take effect.
- Scarf: `IMessageSetupViewModel.swift:55` (`parseEnvBool(env[...])`, so an absent value reads as false) and `:69` (`sendReadReceipts ? "true" : ""`, so off unsets the key).
- Hermes @v2026.9.24: `gateway/config_env.py:619` reads `("send_read_receipts", "BLUEBUBBLES_SEND_READ_RECEIPTS", "true", is_truthy_value)`, so an unset variable means `"true"`. `gateway/platforms/bluebubbles.py:122,608` sends a receipt when that is true.
- Failure scenario: the user sees the toggle off, assumes receipts are off, and saves. `.env` loses the line and receipts keep being sent. There is no way to turn them off from Scarf.
- Suggested fix: default to `true` when the variable is absent (as the SimpleX form does for `SIMPLEX_AUTO_ACCEPT`) and write `false` explicitly when the user turns it off.

### S07-gateway-platforms-F6 · P2 · SOURCE · NEW
- Claim: Spotify sign-in can't complete from Scarf in two common cases: a first-time user who has no Spotify client ID yet, and any remote (SSH) server.
- Scarf: `scarf/scarf/Core/Services/SpotifyAuthFlow.swift:165-172` spawns `hermes auth spotify` with no stdin, no `--client-id` and no port forward. `SpotifySignInSheet.swift` has no client-ID field. The Plugins row that opens the sheet is not hidden for remote servers (`PluginsView.swift:265-271`).
- Hermes @v2026.9.24: `hermes_cli/auth_spotify.py:314-326` starts an interactive wizard when there is no client ID. The wizard calls `line_input("Spotify Client ID: ")` (`:293-299`, which falls back to `input()` when not on a TTY, `cli_output.py:48-49`). With no stdin that hits EOF and exits with "Spotify setup cancelled." Once a client ID exists, the OAuth callback listens on the host's own loopback (`DEFAULT_SPOTIFY_REDIRECT_URI = "http://127.0.0.1:43827/spotify/callback"`, `hermes_cli/auth_constants.py:110`). Hermes only prints an SSH-tunnel hint for that (`auth_device_flow.py:185-200`).
- Failure scenario: (a) Local, first use: the Spotify developer dashboard opens, then the sheet fails at once with "exited with status 1 … Spotify setup cancelled." (b) Remote: Scarf opens the authorize URL in the Mac's browser, which redirects to the Mac's own 127.0.0.1:43827 where nothing is listening. The sheet sits on "Waiting for browser approval…" until Hermes's 180 s timeout. In both cases the failure is reported honestly, but the user can't get past it from Scarf.
- Suggested fix: add a Client ID field and pass `--client-id` (Hermes saves it). On remote servers, hide the row or explain that sign-in must be run on the host.

### S07-gateway-platforms-F7 · P3 · SOURCE · NEW
- Claim: two forms show a default that differs from Hermes's own default when the `.env` key is absent, so saving an untouched form changes the running behaviour.
- Scarf: `FeishuSetupViewModel.swift:49` (`FEISHU_DOMAIN` absent → `"lark"`, and saved as `lark` at `:60`); `WhatsAppSetupViewModel.swift:63` (`WHATSAPP_MODE` absent → `"bot"`, and saved at `:84`).
- Hermes @v2026.9.24: `plugins/platforms/feishu/adapter.py:1387` and `gateway/config_env.py:578` default to `"feishu"`. `plugins/platforms/whatsapp/adapter.py:393,505` and `gateway/platforms/whatsapp_common.py:77` default to `"self-chat"`.
- Failure scenario: this only happens when the key was never written. Hermes's own setup commands always write it (`feishu/adapter.py:4360`, `hermes_cli/main_platform_setup.py:49,64`), so it needs a hand-written `.env`. In that case a Feishu (China) bot is switched to the Lark endpoint, or a self-chat bridge is switched to bot mode.
- Suggested fix: use Hermes's defaults (`feishu`, `self-chat`).

### S07-gateway-platforms-F8 · P3 · SOURCE · NEW (related to TRACKED t-fc4d3a6f)
- Claim: on the Mac, a `hermes webhook list` that fails to run (SSH down, timeout, crash) shows "No webhook subscriptions" instead of an error. iOS already tells these cases apart.
- Scarf: `scarf/scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift` `load()` ignores the exit code and uses `HermesWebhookList.parse` (empty on anything it doesn't recognise), not `HermesWebhookList.listing` (which has an `.unparsed` case). The empty state is at `WebhooksView.swift:34,153`. iOS uses `listing` and shows an error (`Scarf iOS/Webhooks/WebhooksView.swift:87-112`).
- Hermes @v2026.9.24: `hermes_cli/webhook.py:208-235` (the list format, which the parser matches).
- Failure scenario: an SSH timeout on a remote server makes it look as if all subscriptions are gone. t-fc4d3a6f tracks only the "platform not enabled" case.
- Suggested fix: switch to `HermesWebhookList.listing` and show the `.unparsed` / failed-run error, as iOS does.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `gateway status` text markers (✓ running / ✗ not running / manual / multiplexer) | argv+parse | GatewayViewModel.swift (`fetchGatewayStatus`, `isGatewayRunning`, `isServiceLoaded`) | hermes_cli/gateway.py:5019-5069 | OK |
| parked status line | parse | HermesGatewayParkedStatus.swift | hermes_cli/gateway_profile_lifecycle.py:82-98 | OK |
| `gateway start/stop/restart` argv + verdict markers | argv | HermesCLIOutcome.swift (HermesGatewayServiceVerdict), GatewayViewModel.swift | hermes_cli/gateway.py:4763-4830,4909-4962; gateway_launchd.py:656-790 | OK (restart timeout: FINDING-F3) |
| Restart guard (`gateway status`, `status`, state.json argv) | argv+file | HermesGatewayRestartGuard.swift | hermes_cli/gateway.py:5047-5064 | OK |
| `gateway list` | argv+parse | HermesGatewayListService.swift | hermes_cli/gateway.py:1609-1640 | OK |
| gateway_state.json keys pid/gateway_state/exit_reason/updated_at/platforms.*.state/served_profiles | file | GatewayViewModel.swift, HermesFileService.swift:155-226, HermesGatewayStateProjection.swift | gateway/status.py:1075-1120 | OK (`start_time` is an int at the tag; Scarf reads it as String → nil, but it is never displayed) |
| `pairing list/approve/revoke` | argv+parse | GatewayViewModel.swift | (S13/pairing owner) | OK |
| TELEGRAM_* env (BOT_TOKEN, ALLOWED_USERS, HOME_CHANNEL, WEBHOOK_URL/PORT/SECRET) | env | TelegramSetupViewModel.swift:97-104 | gateway/config_env.py:513-516; telegram/adapter.py:3142-3150 | OK |
| telegram.require_mention/reactions/disable_topic_auto_rename; platforms.telegram.extra.rich_messages/status_indicator/ignore_root_dm | config | TelegramSetupViewModel.swift:105-120 | telegram/adapter.py:7208-7260,566,649 | OK |
| DISCORD_* env (BOT_TOKEN, ALLOWED_USERS, HOME_CHANNEL[_NAME], ALLOW_BOTS, REPLY_TO_MODE) | env | DiscordSetupViewModel.swift:96-103 | gateway/config_env.py:155-170; discord/adapter.py:7311-7314 | OK |
| discord.require_mention/free_response_channels/auto_thread/reactions/history_backfill; platforms.discord.extra.allow_any_attachment | config | DiscordSetupViewModel.swift:104-122 | discord/adapter.py:7280-7300; config_defaults.py:1519-1560 | OK |
| SLACK_* env | env | SlackSetupViewModel.swift:64-70 | slack/adapter.py:1779,6693-6706; config_env.py | OK |
| platforms.slack.require_mention / extra.reply_in_thread / extra.reply_broadcast | config | SlackSetupViewModel.swift:74-76 | slack/adapter.py:6201,2717,2277 | OK |
| platforms.slack.reply_to_mode | config | SlackSetupViewModel.swift:73 | (no Slack reader) | FINDING-F1 |
| WHATSAPP_ENABLED/MODE/ALLOWED_USERS/ALLOW_ALL_USERS | env | WhatsAppSetupViewModel.swift:83-88 | whatsapp/adapter.py:393,505; authz_mixin.py:32-35 | OK (MODE default: FINDING-F7) |
| whatsapp.unauthorized_dm_behavior; unauthorized_dm_decline_message | config | WhatsAppSetupViewModel.swift:89-106 | config_loader.py:102-103,209 | OK (spelling TRACKED t-d02dd23e) |
| whatsapp.reply_prefix | config | WhatsAppSetupViewModel.swift:92 | whatsapp_common.py:75-84 | FINDING-F2 |
| `hermes whatsapp` pairing terminal (local only) | argv | WhatsAppSetupViewModel.swift:121-136 | hermes_cli/main_platform_setup.py | OK |
| WHATSAPP_CLOUD_* env + platforms.whatsapp_cloud.{enabled,extra.*} | env+config | WhatsAppCloudSetupViewModel.swift:190-276 | gateway/config_env.py:523-533; whatsapp_cloud.py:55,182 | OK |
| SIGNAL_* env + platforms.signal.extra.require_mention | env+config | SignalSetupViewModel.swift | platforms/signal.py:194-196; config_env.py | OK |
| MATRIX_* env + matrix.require_mention/auto_thread/dm_mention_threads | env+config | MatrixSetupViewModel.swift:65-83 | matrix/adapter.py:873-950,3125-3134 | OK |
| MATTERMOST_* env | env | MattermostSetupViewModel.swift:90-97 | mattermost/adapter.py:121,499-506 | OK |
| mattermost.require_mention (env-vs-config precedence) | config | MattermostSetupViewModel.swift:84,106 | _shared.py:106-128; mattermost/adapter.py:503 | FINDING-F4 |
| EMAIL_* env + platforms.email.extra.skip_attachments | env+config | EmailSetupViewModel.swift | email/adapter.py:355; config_env.py | OK |
| HASS_URL/HASS_TOKEN + platforms.homeassistant.extra.watch_all/cooldown_seconds | env+config | HomeAssistantSetupViewModel.swift:71-81 | homeassistant/adapter.py:106-110 | OK |
| BLUEBUBBLES_* env (server, password, webhook host/port/path, allowlist, home) | env | IMessageSetupViewModel.swift:59-71 | config_env.py:611-624; bluebubbles.py:118-122 | OK |
| BLUEBUBBLES_SEND_READ_RECEIPTS | env | IMessageSetupViewModel.swift:55,69 | config_env.py:619 | FINDING-F5 |
| FEISHU_* env | env | FeishuSetupViewModel.swift:56-67 | config_env.py:578; feishu/adapter.py:1387 | OK (DOMAIN default: FINDING-F7) |
| NTFY_* env + platforms.ntfy.extra.* | env+config | NtfySetupViewModel.swift | ntfy/adapter.py:99-128,279,316-319 | OK |
| SIMPLEX_* / HERMES_SIMPLEX_TEXT_BATCH_DELAY env | env | SimpleXSetupViewModel.swift | simplex/adapter.py:102-104,600-611; _shared.py:209-229 | OK |
| WEBHOOK_ENABLED/PORT/SECRET + platforms.webhook.enabled | env+config | WebhookSetupViewModel.swift:74-88 | hermes_cli/webhook.py:44-56; config_env.py | OK |
| `hermes config set <key> <value>` per key + HermesConfigSet judge | argv | PlatformSetupHelpers.swift:125-153 | hermes_cli/config.py:3248-3266,3747-3753 | OK |
| Shared-key section resolution | config | HermesPlatformSharedKeys.swift | gateway/config_loader.py:182-191,208-224 | OK |
| Allowlists `<platform>.allowed_channels/allowed_chats/allowed_rooms` (direct YAML) | config | GatewayBehaviorViewModel.swift, GatewayConfigWriter.saveList, GatewayAllowlistKind.swift | slack/adapter.py:6718; mattermost/adapter.py:704; matrix/adapter.py:873,3129; dingtalk/adapter.py:267,704; config_loader.py:212 | OK |
| display.busy_ack_enabled; `<platform>.gateway_restart_notification` | config | GatewayBehaviorViewModel.swift:~130-140 | gateway/run.py:1962; gateway/config.py:478; run_shutdown.py:875-877 | OK |
| Platform "configured" detection (top-level / nested / identifying env) | file | PlatformsViewModel.swift:107-230 | config_loader.py:139-191 | OK |
| `webhook list` parse | argv+parse | HermesWebhookList.swift; WebhooksViewModel.swift | hermes_cli/webhook.py:208-235 | OK (Mac failure display: FINDING-F8) |
| `webhook subscribe` argv (+ `Secret:`/`URL:` parse) | argv | WebhooksViewModel.swift | hermes_cli/webhook.py:113-205; LIVE `--help` | OK (not-enabled message TRACKED t-fc4d3a6f) |
| `webhook remove` / `webhook test` verdicts | argv | HermesCLIOutcome.swift:2832-2930 | hermes_cli/webhook.py:237-272 | OK |
| iOS `webhook list` | argv+parse | Scarf iOS/Webhooks/WebhooksView.swift:87-121 | hermes_cli/webhook.py:208-235 | OK |
| `gateway setup` Terminal launch (profile HERMES_HOME, ssh -t) | argv | GatewaySetupTerminalCommand.swift | LIVE `hermes gateway --help` | OK |
| `auth spotify` + auth.json `providers.spotify.access_token` | argv+file | SpotifyAuthFlow.swift:165-172,455-468 | hermes_cli/auth_spotify.py:314-390 | FINDING-F6 |

## Not audited / couldn't verify
- Webhook subscriptions for a named profile served by the default multiplexer: Scarf never passes `--route-profile`. Whether a subscription written under `-p <profile>` is served at `/p/<profile>/webhooks/<name>` was not traced.
- The URL printed by `webhook list` comes from `platforms.webhook.extra.port`, while Scarf writes the port only to `WEBHOOK_PORT`. The displayed URL may therefore show 8644 while the listener uses the `.env` port. This is Hermes's display, relayed as-is; not treated as a Scarf defect.
- systemd `gateway status` output (remote Linux) was traced only as far as the fallback to `gateway_state` there. The launchd and "no service" branches were read in full.
- The view-level behaviour of the pairing embedded terminals (WhatsApp/Signal) was not exercised. Remote contexts disable those buttons by design.
- No live gateway commands were run (brief restriction); `--help` probes confirmed the argv for webhook subscribe, gateway list/restart and auth spotify.
