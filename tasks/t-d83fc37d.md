---
id: t-d83fc37d
title: B13 Env-first platform settings: forms show/write values Hermes reads from .env first
status: doing
added: 2026-09-27
---

## Description

After B12 (current phases done). Same bug as S07-F4 Mattermost (fixed in B05) across other platform forms: Hermes reads .env before config.yaml for these keys, so Scarf's toggle is inert and the form shows the wrong value when .env holds the variable. Plan: documents/plans/hermes-v0215-blind-reaudit-remediation-plan.md § B13. Scope list + Hermes citations + lessons from the reverted B05 attempt are in that section.

## Plan



## Artifacts

Branch fix/hermes-v0215-blind-b13: 05f9c54f (Discord+Telegram env-first forms, allowlist, iOS rows, strings), 2563ae91 (JSON-list env allowlist). Tests: ScarfCore PlatformEnvSettingB13Tests (8), scarfTests DiscordEnvFirstB13Tests/TelegramEnvFirstB13Tests/AllowlistEnvFirstB13Tests (8, incl. round trip through Hermes v0.21.5 loader). Memory: B13 section appended to architecture/a-platform-s-shared-keys-are-bridged-from-one-section-so. Remaining: Matrix, Ntfy, Slack/Mattermost allowlists.

