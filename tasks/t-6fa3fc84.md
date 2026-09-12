---
id: t-6fa3fc84
title: Slack setup writes a require_mention a top-level slack: block shadows
status: todo
added: 2026-09-10
---

## Description

Found during P20 (`t-6679d648`) while modelling `gateway/config_loader.py`'s shared-key bridge. P20 fixed the READ paths; the matching WRITE paths were out of phase.

`platform_section` (`gateway/config_loader.py:171-180` @ v2026.9.7) picks ONE section to bridge a platform's `_SHARED_KEYS` from: "a top-level `<name>:` block wins; otherwise the block under `gateway.platforms` / `platforms`". A top-level block does not out-rank the nested one key-by-key — it REPLACES it as the bridge source.

- `scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/SlackSetupViewModel.swift:64` writes `platforms.slack.require_mention` and `:65` writes `platforms.slack.extra.reply_in_thread`. Both are `_SHARED_KEYS` members (`config_loader.py:200`). If the user's config.yaml also carries a top-level `slack:` block (which `hermes setup` and Scarf's own `slack.allowed_channels` surfaces can create), Scarf's write is never bridged and never reaches the adapter — the form reports "Saved" and nothing changes. `require_mention` is also exported to `SLACK_REQUIRE_MENTION` by slack's own `_apply_yaml_config` hook (`plugins/platforms/slack/adapter.py:6449`) from the TOP-LEVEL block only, another path Scarf's nested write misses.
- Same class, unverified: `DiscordSetupViewModel.swift:79` and `MatrixSetupViewModel.swift:68` write the top-level spelling, which is correct UNLESS the user has a nested `platforms.<p>:` block and no top-level one — check whether a top-level write in that shape creates a block that then shadows their nested settings for the OTHER shared keys.

The read side already models this: `HermesConfig+YAML.swift`'s `sharedPlatformScalar` resolves the bridge source the way Hermes does, and `HermesP20ConfigDefaultsTests.topLevelSlackBlockShadowsNestedSharedKeys` pins it. The fix is to make the writer pick the spelling in effect, the way P20's `SettingsViewModel.multiplexProfilesKey(isTopLevel:)` does for `multiplex_profiles`.

## Plan



## Artifacts



