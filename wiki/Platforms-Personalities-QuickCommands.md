---
title: Platforms-Personalities-QuickCommands
type: note
permalink: scarf-wiki/platforms-personalities-quick-commands
created: 2026-05-29
updated: 2026-05-29
---

# Platforms / Personalities / Quick Commands

Three separate Configure-section items grouped together because they all shape how Hermes presents itself.

## Platforms

Native GUI setup for all 13 messaging platforms Hermes supports — no more hand-editing `.env` and `config.yaml`:

Telegram, Discord, Slack, WhatsApp, Signal, Email, Matrix, Mattermost, Feishu, iMessage, Home Assistant, Webhook, CLI.

**Per-platform forms:**

- Credentials → `~/.hermes/.env` via [`HermesEnvService`](Core-Services) (preserves comments, supports non-destructive unset by commenting-out).
- Behavior toggles → `~/.hermes/config.yaml` via the typed config struct.
- WhatsApp + Signal pairing use an inline SwiftTerm terminal for QR scan and `signal-cli` daemon management.

Connectivity dots next to each platform reflect the gateway's last reported status:

- **Green** — connected and healthy.
- **Orange** — configured but offline.
- **Grey** — not configured.
- **Red** — error (a `fatal` platform, or one retrying with a reason; the reason is shown).

The dots read the per-platform `state` / `error_message` Hermes writes to `gateway_state.json`. For a named profile served by the default profile's multiplexer (the normal v0.21.x setup), Scarf reads the root `~/.hermes/gateway_state.json` and uses that profile's `<profile>:<platform>` entries, as Hermes does.

**WhatsApp Cloud** reads its credentials from both `.env` (`WHATSAPP_CLOUD_*`, where `hermes whatsapp-cloud` puts them) and `platforms.whatsapp_cloud.extra` in config.yaml, and saves new credentials to `.env`. It never writes `enabled: false` because a field is blank, and it leaves the allowlist and DM policy where they already live. **Webhook** writes both `WEBHOOK_ENABLED` and `platforms.webhook.enabled`; the `hermes webhook` commands (and Scarf's Webhooks tab) check only the config key.

A few forms follow Hermes's own defaults and precedence rather than the file layout:

- **Slack** has no "Reply Mode" picker. Hermes's Slack adapter never reads `reply_to_mode` (only Discord and Telegram do); Slack threading is **Reply in thread** and **Reply broadcast**.
- **WhatsApp** writes `whatsapp.reply_prefix` only when you type a prefix or config.yaml already has the key. A blank field over no key keeps Hermes's built-in "☤ Hermes Agent" header (or `WHATSAPP_REPLY_PREFIX`). An empty value that is already saved turns the header off, and **Use Hermes Default** removes the key (`hermes config unset`, Hermes 0.19+). Mode defaults to `self-chat`, which is Hermes's default.
- **Mattermost** "Require @mention": from Hermes 0.21.3 a `MATTERMOST_REQUIRE_MENTION` line in `.env` overrides config.yaml. The form shows that value and says so. Saving writes config.yaml and comments the `.env` line out, so the toggle works on both older and newer hosts.
- **iMessage (BlueBubbles)** "Send read receipts" is on when `.env` has no value (Hermes's default), and turning it off writes `false`.
- **Feishu** domain defaults to `feishu`, which is Hermes's default.

The platform list is data-driven, so platforms Hermes added after 1.6 — Feishu, Microsoft Teams, Tencent Yuanbao, Google Chat, LINE Messaging API, SimpleX Chat, and now **ntfy** — auto-appear when the connected host advertises them.

### ntfy _(v2.10.0+, Hermes v0.15+)_

**ntfy** is the 23rd gateway platform — push notifications via a [ntfy.sh](https://ntfy.sh) topic URL, **no account required**. The setup form writes `platforms.ntfy.extra.{topic, server, publish_topic, token, markdown}` to `config.yaml`: a topic name (required), an optional self-hosted server URL (defaults to the public ntfy.sh), an optional separate publish-topic, an optional access token for protected topics, and a markdown toggle. Gated on `HermesCapabilities.hasNtfyPlatform`.

### Per-platform behavior flags _(v2.10.0+, Hermes v0.15+)_

v0.15 adds a handful of per-platform toggles surfaced in each platform's setup form:

- **Telegram** — `disable_topic_auto_rename` (stop Hermes from renaming forum topics) + `ignore_root_dm` (ignore DMs sent outside a topic thread).
- **Discord** — `allow_any_attachment` (accept attachment types beyond images).
- **Signal** — group-only `require_mention` (only respond in group chats when explicitly mentioned).

## Personalities

A personality is a `SOUL.md` file that shapes Hermes's voice, defaults, and internal rules. Personalities live under `~/.hermes/personalities/<name>/`.

**What you can do here:**

- List defined personalities.
- Pick the active one — written to `display.personality` in `config.yaml`.
- Edit `SOUL.md` inline with markdown preview. ⌘S saves.
- Create / rename / delete personalities.

Switching personality takes effect on the next agent turn in the **Hermes CLI, TUI and messaging gateways** — no restart needed. **It does not change Scarf chat**: Hermes applies the personality overlay only on those surfaces (`resolve_ephemeral_system_prompt`, `hermes_cli/personality.py:118-124`, read by `cli_init_mixin.py:249`, `gateway/run_config_loaders.py:99`, `tui_gateway/server.py:2384-2385` @ v2026.9.24), and the ACP adapter Scarf chats through builds its agent without it (`acp_adapter/session.py:487-530`). The screen says so under the picker. `SOUL.md` is part of every system prompt, so editing it does shape Scarf chats.

## Quick Commands

Custom `/command_name` shell shortcuts. You define a name, a shell command (with optional arg substitution), and an optional description. Hermes runs them from the CLI (`hermes chat`), the TUI and the messaging gateways (`cli.py:1219-1233`, `gateway/run_inbound.py:812,1033` @ v2026.9.24). **Scarf chat does not run them**: its ACP adapter has no quick-command lookup, so a typed `/name` reaches the model as an ordinary prompt. Scarf's chat slash menu therefore doesn't list them.

**Safety:** the editor scans for dangerous patterns (`rm -rf`, `mkfs`, fork bombs, sudo, suspicious eval) and warns before saving. The check is heuristic — it's a guard against typos, not a sandbox.

Quick Commands live in `config.yaml` under the `quick_commands` key. Scarf saves a new command's name in lowercase: every Hermes surface lowercases what you type before looking it up (`cli.py:1213-1222`, `gateway/platforms/event.py:105` @ v2026.9.24), so a key saved as `Deploy` could never run. Editing an existing command keeps its key.

## Related pages

- [Memory & Skills](Memory-and-Skills) — memory is profile-scoped, personality is config-scoped.
- [Gateway / Cron / Health / Logs](Gateway-Cron-Health-Logs) — the gateway reads platform configs to decide what to connect to.
- [Hermes Paths](Hermes-Paths) — where `.env`, `config.yaml`, and `personalities/` live.

---
_Last updated: 2026-09-28 — new Quick Command names are saved lowercase. Previously 2026-09-26 — Quick Commands run in the Hermes CLI, TUI and gateways, not in Scarf chat. Previously 2026-05-28 — Scarf v2.10.0 (ntfy as 23rd gateway platform + per-platform behavior flags for Telegram / Discord / Signal)_