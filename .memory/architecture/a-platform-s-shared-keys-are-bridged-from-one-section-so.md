---
title: A platform's shared keys are bridged from ONE section, so the writer must pick the spelling in effect
type: note
permalink: scarf/architecture/a-platform-s-shared-keys-are-bridged-from-one-section-so
tags: [hermes, gateway, config, platforms, verification]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPlatformSharedKeys.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift, scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift]
source_paths_inferred: false
source_sha: 720dbdc26d8e55d9c470297b4108454262ab4d45
created: 2026-09-11
updated: 2026-09-13
reviewed: 2026-09-13
reviewed_by: claude-opus-5
---

`platform_section` (`gateway/config_loader.py:171-180` @ v2026.9.7) picks ONE section per platform to bridge `_SHARED_KEYS` (`:197-213`) from: "a top-level `<name>:` block wins; otherwise the block under `gateway.platforms` / `platforms`". `_bridged_keys` (`:224-239`) copies that section's members into the platform's `extra` with `extra.update(bridged)`, and the adapters read them from `extra` (`_slack_require_mention`, `plugins/platforms/slack/adapter.py:5917-5926`).

The trap is that a top-level block does not out-rank the nested one key by key — it REPLACES it as the bridge source. This is NOT the same question as `merge_platform_sections` (`:121-160`), which merges `gateway.platforms.*`, `platforms.*` and `gateway.<platform>` but deliberately NOT a bare top-level `<name>:` block (`:149-152`).

P20 modelled this on the READ side (`HermesConfig+YAML.sharedPlatformScalar`); the write side stayed hard-coded until P44 (`t-6fa3fc84`), so `SlackSetupViewModel`'s `platforms.slack.require_mention` reached nobody on any config carrying a top-level `slack:` block — and the save bar said "Saved". `HermesPlatformSharedKeys` is now the single model both halves call, and the rewrite happens once at the shared `hermes config set` executor rather than in fifteen forms.

## Observations
- [gotcha] A top-level `<platform>:` block REPLACES the nested one as the shared-key bridge source rather than out-ranking it key by key, so a nested write onto such a config is read by nobody #hermes
- [constraint] Writing a shared key at the wrong spelling is invisible: `config set` succeeds, Scarf banners Saved, and the adapter never sees the value — only the bridge source reaches `extra` #verification
- [convention] Resolve the spelling at SAVE time in the shared executor, not per form and not at load time — a form can sit open across a `hermes setup` run that adds the top-level block #scarf
- [constraint] A writer may only be moved onto the bridge once its READER resolves the bridge too — and the unit of that permission is the `(platform, key)` PAIR, not the platform. P44's platform-scoped `bridgeResolvedPlatforms` moved `slack.gateway_restart_notification`, whose reader is a flat `boolTrueDefault("slack.gateway_restart_notification")` (`HermesConfig+YAML.swift:695`), and `GatewayBehaviorViewModel`'s toggle became WRITE-ONLY on every nested-only config. P46 replaced it with `bridgeResolvedKeys` — exactly the three `sharedPlatform*` call sites (slack `require_mention`, slack `reply_in_thread`, telegram `require_mention`) — and the parity test now scans BOTH arguments of each call #scarf
- [gotcha] A `config set` BATCH is not one write, so the bridge source must be resolved against the file AS THE BATCH WILL LEAVE IT. `TelegramSetupViewModel` sends bare `telegram.require_mention` (shared) beside bare `telegram.reactions` (not shared, so untouched): resolved against the PRE-save file the shared key moved to `platforms.telegram.…` while the unshared one CREATED the top-level `telegram:` block — which is then the bridge source, and `require_mention` is not in it. The batch invalidated its own resolution. Any bare `<platform>.<anything>` in the batch now pins the prefix to `<platform>` (P46) #verification
- [todo] `resolved()` MOVES, it does not MIGRATE: the value at the source spelling is left behind as a stale shadow that Hermes ignores today and reads the day the bridge source changes. Not clearable through `hermes config` (no delete for an arbitrary key) — t-f3d7bdd2 #roadmap #scarf
- [gotcha] An EXPLICITLY EMPTY top-level block still wins. `slack: {}` is a `dict` to PyYAML, so `platform_section` takes it as the bridge source (`gateway/config_loader.py:175` @ v2026.9.7) and the nested `platforms.slack.*` keys are never bridged. `bridgeSourcePrefix` asked `maps[section]?.isEmpty == false` and resolved BOTH the read and the write side to the wrong section; P44b changed it to `maps[section] != nil`, which is exactly `isinstance(section, dict)` — the flat parse records an inline flow map either way, and a bare `slack:` header still records nothing and still loses #verification
- [todo] signal, whatsapp_cloud, discord, matrix and whatsapp still read one hard-coded spelling — t-d02dd23e #roadmap. (mattermost's `require_mention` left this list in P51b; `gateway_restart_notification` left it for slack/telegram in P46b.)

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Hermes Capability Gating Pattern]]


## P46b — the allowlist grows by TWO, and the hazard it does not close

- [decision] **`gateway_restart_notification` joined `bridgeResolvedKeys` for `slack` and
  `telegram`** (`a856d981`). P46 correctly kept it OUT while its Scarf reader was a flat
  `boolTrueDefault("<p>.gateway_restart_notification")` — but leaving the WRITE bare is not
  neutral: on a nested-only host `GatewayBehaviorViewModel`'s toggle CREATED the top-level
  `slack:` block, `platform_section` then bridged from it (`gateway/config_loader.py:171-180` @
  `v2026.9.7`), and `platforms.slack.require_mention` stopped reaching `extra`. The reader moved
  onto `sharedPlatformScalar` for those two platforms — the only ones whose OTHER shared keys are
  bridge-resolved, i.e. the only ones a created block can un-bridge anything on — so the write now
  lands wherever the bridge source already is and creates nothing. The other six keep the flat
  spelling; moving them would need their reads moved in the same commit, which is this note's own
  honest-half rule.
- [gotcha] **A key that is about to be MOVED does not count as evidence of a top-level block.**
  `resolved()`'s `batchTopLevel` (P46's "resolve against the file as the batch will LEAVE it")
  counted every bare two-segment key in the batch, including the shared one it was about to
  rewrite — so `slack.gateway_restart_notification` pinned the prefix to `slack` and the rewrite
  resolved straight back onto the block it exists to avoid creating. It now skips keys `split(key:)`
  accepts.
- [todo] **The hazard this type does NOT close — `t-f655c541`.** Any bare
  `<platform>.<UNSHARED>` key still creates the block: `telegram.reactions`,
  `telegram.disable_topic_auto_rename`, and — outside the `config set` path entirely —
  `GatewayConfigWriter.saveList`'s direct-YAML `<platform>.allowed_channels` / `allowed_chats` /
  `allowed_rooms`, the last of which is itself a `_SHARED_KEYS` member. Documented on the type
  under "The hazard this type does NOT close" #platforms


## P51b — mattermost joins, and the P46b lesson had one more instance

- [decision] **`mattermost.require_mention` joined `bridgeResolvedKeys`, reader and writer in
  the same commit.** P51 moved this key from `.env` to config.yaml and left BOTH halves on the
  bare top-level spelling. Internally consistent — the Scarf round trip worked — and externally
  wrong for exactly P46b's reason: on a nested-only host the bare write CREATES the top-level
  `mattermost:` block, which `platform_section` (`gateway/config_loader.py:171-180` @
  `v2026.9.7`) then takes as the bridge source, so every `platforms.mattermost.<shared key>`
  beside it stops reaching `extra`. The reader (`HermesConfig+YAML`, both the resolved value and
  the new `requireMentionIsSet` PRESENCE field) is on `sharedPlatformScalar` /
  `sharedPlatformBool` now and the pair is on the allowlist. Option (b), the same remedy
  `gateway_restart_notification` took #platforms
- [gotcha] **A PRESENCE field must be asked at the same precedence as the VALUE.**
  `requireMentionIsSet` was `values["mattermost.require_mention"] != nil` — a flat lookup beside
  a bridge-resolved read would have fired the `.env` fallback for a key that IS there (nested)
  and not fired for one that is not. Both questions go through `sharedPlatformScalar` #config-parsing
- [fact] The review that found this described the mechanism as "`resolved()` moves every shared
  key in `names`, so the write already lands nested and the flat reader snaps it back". That is
  not what the code does: `split(key:)` has matched the `(platform, key)` PAIR against
  `bridgeResolvedKeys` since P46b, so the key was not being moved at all. The REMEDY the review
  asked for was right; the failure mode it named was not. The real one is the sibling
  un-bridging above #verification



## P57 — the LAST way a block was faked, and it was Scarf's own flat parse

- [gotcha] **A flat dotted key made `isBlock` answer yes, and PyYAML says no.** P44b fixed
  `slack: {}` by asking `maps[section] != nil` instead of `?.isEmpty == false`, which is exactly
  `isinstance(section, dict)` for the map cases. What survived was the DESCENDANT-PREFIX arm
  beside it: a hand-edited top-level `slack.enabled: true` is recorded by `parseNestedYAML` as
  `values["slack.enabled"]`, which matches the `slack.` prefix — so `isBlock("slack")` was true
  and `bridgeSourcePrefix` answered `slack`. PyYAML keeps that line as the INDEPENDENT top-level
  key `"slack.enabled"`, so `yaml_cfg.get("slack")` is `None`, `isinstance(None, dict)` is False,
  and `platform_section` (`gateway/config_loader.py:171-180` @ `v2026.9.7`) falls through to
  `gateway.platforms.slack` / `platforms.slack`. The form therefore READ from a section the
  adapter never sees and, worse, `resolved()` WROTE there — creating the real top-level block and
  un-bridging every nested shared key beside it, which is `t-f655c541`'s hazard reached by a
  READ rather than by an unshared write #platforms
- [fact] **The parser already knew; `ParsedYAML` just did not say.** `parseNestedYAML` has
  tracked `dottedLiteralPaths` since P38 for the last-wins purge (a flat dotted sibling must not
  be swept when a `gateway:` block re-opens). P57 promoted it to a public `ParsedYAML` member and
  `isBlock` excludes those paths AND their descendants — `slack.enabled:` opened as a block
  header is `{"slack.enabled": {…}}` to PyYAML, still not a `slack` dict, so its children are no
  better evidence than the key itself. No Scarf writer emits a dotted key, so this is hand-edited
  configs only #verification
