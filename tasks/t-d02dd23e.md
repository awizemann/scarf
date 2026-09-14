---
id: t-d02dd23e
title: Shared-key reads for the other platforms still expect one hard-coded spelling
status: todo
added: 2026-09-11
---

## Description

Found in P44 while fixing `t-6fa3fc84`. P44 built `HermesPlatformSharedKeys` (`scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPlatformSharedKeys.swift`) — one model of `platform_section` (`gateway/config_loader.py:171-180` @ v2026.9.7) for both the reader and the writers — and routed the shared `hermes config set` executor (`PlatformSetupHelpers.saveForm`) through it. But it deliberately restricted the rewrite to `bridgeResolvedPlatforms = ["slack", "telegram"]`, because those are the ONLY platforms whose READ side resolves the bridge (`HermesConfig+YAML.sharedPlatformScalar`, P20).

Every other platform reads a `_SHARED_KEYS` member from one hard-coded spelling, so its write has the same class of bug `t-6fa3fc84` filed — and moving the write alone would trade half the bug for the other half (the value would reach Hermes and stop reaching the form, so the form would then contradict a setting that IS live). Each needs the read and the write moved in the SAME commit:

- `platforms.signal.extra.require_mention` — read `HermesConfig+YAML.swift:481`, written `SignalSetupViewModel.swift:105`.
- `platforms.whatsapp_cloud.extra.dm_policy` / `.allow_from` — read `:503-504`, written `WhatsAppCloudSetupViewModel.swift:101-102`.
- `discord.require_mention` / `discord.free_response_channels` — read `:445-446`, written `DiscordSetupViewModel.swift:90-91`. This is `t-6fa3fc84`'s second (then-unverified) bullet: a top-level write CREATES a `discord:` block, which then becomes the bridge source for ALL of discord's shared keys and shadows a user's nested `platforms.discord:` ones.
- `matrix.require_mention` — read `:605`, written `MatrixSetupViewModel.swift:76`.
- `mattermost.require_mention` — read at `HermesConfig+YAML.swift`'s `mattermost` block, and **it now HAS a writer**: P51 (`c93c2287`, round-5) moved it off `.env` onto `mattermost.require_mention` in `MattermostSetupViewModel.save()`, because the adapter prefers `config.extra` (`plugins/platforms/mattermost/adapter.py:491-494`, `:504` @ `v2026.9.7`). The "read-only asymmetry; confirm" note above is RESOLVED — it is a read/write pair like the others now, and both halves still sit on the hard-coded top-level spelling, so it belongs in this task's list rather than outside it. P51 also added `MattermostSettings.requireMentionIsSet` (absent vs explicit `false`) and a `.env` read fallback for the absent case; whichever commit moves the reader onto `sharedPlatformScalar` must carry that presence question with it.
- `whatsapp.unauthorized_dm_behavior` / `whatsapp.reply_prefix` — read `:631-632`, written `WhatsAppSetupViewModel.swift:81-82`.
- `gateway_restart_notification` is ALSO a `_SHARED_KEYS` member (`config_loader.py:212`). `GatewayBehaviorViewModel.restartNotificationKey(platform:capabilities:)` writes the top-level `<platform>.gateway_restart_notification` spelling for every wired platform, and `HermesConfig+YAML.swift:422` reads that same top-level path — same class, widest blast radius. (P46b moved slack + telegram; the rest stand.)

The work per platform: move the reader onto `sharedPlatformScalar` / `sharedPlatformBool`, then add the platform to `HermesPlatformSharedKeys.bridgeResolvedPlatforms`. `HermesPlatformSharedKeyWriteP44Tests.theAllowlistMatchesTheReadersThatResolveTheBridge` pins the two sets equal, so a reader converted without the allowlist entry fails immediately — which is the intended forcing function, not an obstacle. `HermesP46Tests.aSharedKeyWhoseReaderIsHardCodedTopLevelIsNotMoved` names discord/matrix/mattermost and will need re-aiming as each moves.

## Plan



## Artifacts



