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
- **Red** — error.

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
- Pick the active one — written to `personality:` in `config.yaml`.
- Edit `SOUL.md` inline with markdown preview. ⌘S saves.
- Create / rename / delete personalities.

Switching personality takes effect on the next agent turn — no restart needed.

## Quick Commands

Custom `/command_name` shell shortcuts. You define a name, a shell command (with optional arg substitution), and an optional description; the command becomes invocable from anywhere Hermes accepts commands.

**Safety:** the editor scans for dangerous patterns (`rm -rf`, `mkfs`, fork bombs, sudo, suspicious eval) and warns before saving. The check is heuristic — it's a guard against typos, not a sandbox.

Quick Commands live in `config.yaml` under the `quick_commands` key.

## Related pages

- [Memory & Skills](Memory-and-Skills) — memory is profile-scoped, personality is config-scoped.
- [Gateway / Cron / Health / Logs](Gateway-Cron-Health-Logs) — the gateway reads platform configs to decide what to connect to.
- [Hermes Paths](Hermes-Paths) — where `.env`, `config.yaml`, and `personalities/` live.

---
_Last updated: 2026-05-28 — Scarf v2.10.0 (ntfy as 23rd gateway platform + per-platform behavior flags for Telegram / Discord / Signal)_