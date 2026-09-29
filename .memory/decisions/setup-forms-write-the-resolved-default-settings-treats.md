---
title: Setup forms write the resolved default; Settings treats absence as a sentinel
type: note
permalink: scarf/decisions/setup-forms-write-the-resolved-default-settings-treats
tags: [platforms, settings, config, hermes]
source_paths: [scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift]
source_paths_inferred: false
source_sha: ebfef32ea30937a78516be06e7bba5bbf07f0ac3
created: 2026-09-10
updated: 2026-09-27
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

Round-3 product decision 9 (Alan, 2026-09-10), shipped in P33 as a doc comment on `PlatformSetupForm` plus this note. No behaviour change — the two surfaces already differed, and the difference was intentional and undocumented.

A platform setup form is a "set up this platform" gesture: it writes the WHOLE block explicitly, resolved defaults included (`api_version: "v20.0"`, `dm_policy: "open"`, `enabled: true|false`), because the block is authored as a unit, a half-written platform block is a platform that half-starts, and the form IS the record of the decision. Settings edits ONE key at a time, where absence is a SENTINEL ("Host default") that must survive an unrelated save: writing the resolved default there would freeze today's Hermes default into the file and silently opt the user out of the host's future one.

If a form ever needs Settings' posture, it needs a sentinel of its own first.

## Observations
- [decision] A platform setup form writes its whole config.yaml block on Save, resolved defaults included; Settings writes only the key the user edited and treats absence as a "Host default" sentinel #platforms #settings
- [invariant] A sentinel row in Settings is a no-op write; a setup form has no sentinel, so it may not adopt Settings' posture without inventing one #settings
- [gotcha] The two postures look inconsistent from outside and the inconsistency is load-bearing: freezing today's Hermes default into config.yaml opts the user out of the host's future default #config
- [invariant] Round-4 P44/P44b: a setup form must also write the SHARED-KEY SPELLING Hermes actually bridges from, resolved at save time by `HermesPlatformSharedKeys.bridgeSourcePrefix`. Writing the nested spelling onto a config that carries a top-level `<platform>:` block (`slack: {}` included — an empty dict still wins) succeeds, banners Saved, and the adapter never sees the value. See [[A platform's shared keys are bridged from ONE section, so the spelling has to be resolved at save time]] #platforms #verification

## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[GuardedTextFile is the one guard for Scarf's non-JSON hand-authored files]]


## P51 — "the whole block" is bounded by the ROW, and by which file wins (`c93c2287`)

Round-5, P51. Three corrections to how far "writes the WHOLE block explicitly" reaches.

- [invariant] **"The whole block" means the rows this HOST renders, not every key the form
  knows.** `DiscordSetupViewModel.save()` wrote `discord.history_backfill` and
  `platforms.discord.extra.allow_any_attachment` unconditionally while the VIEW gated both rows
  on capabilities — so a pre-v0.14 host got a `history_backfill` it was never shown, and every
  v0.18+ host got an `allow_any_attachment` nothing reads, stamped over whatever the file held
  from a toggle that was never on screen. That is not the resolved-default posture, it is a
  write with no user decision behind it. Telegram's `load(capabilities:)` shape is the rule:
  the form captures the host's capability set at load and `save` writes only the windowed keys
  whose row it rendered. `capabilities` is REQUIRED, never defaulted — a defaulted overload
  lets the Reload button silently reset it to `.empty` and change the next batch #platforms
- [gotcha] **A capability window can have a CEILING.** `discord.allow_any_attachment` is live
  only in [v0.15.0, v0.18.0): the adapter stopped CALLING
  `_discord_allow_any_attachment` at `v2026.7.1` while the getter lingered to `v2026.8.31`, and
  at `v2026.9.7` the key is a documented no-op. Count by CALL SITE — grepping the symbol puts
  the window's end three releases late. Retiring the row was rejected on C1: a v0.15–v0.17 host
  honours it #capability-gating
- [exception] **B05 (S07-F2/F4/F5/F7): "resolved default" means HERMES's default, and a key
  whose ABSENCE means something is never written blank.** WhatsApp `reply_prefix`: absent = the
  built-in header, `""` = no header (`whatsapp_common.py:75-84` @ v2026.9.24), so the form writes it
  only when typed or already present (presence via raw config text) and "Use Hermes Default" is a
  gated `config unset`. BlueBubbles read receipts: absent env = on, so off writes `false`. Feishu
  domain / WhatsApp mode now default to Hermes's `feishu` / `self-chat`. Mattermost: the adapter's
  preferred side FLIPPED to env at v0.21.3 (next bullet is the pre-0.21.3 truth); the form now
  writes config.yaml and comments the env line out so both bands agree.
- [invariant] **A form must write the side the ADAPTER prefers, and read the other as a
  fallback.** `MattermostSetupViewModel` READ `mattermost.require_mention` from config.yaml and
  WROTE `MATTERMOST_REQUIRE_MENTION` to `.env`, so the toggle snapped back on the next load —
  and on any config carrying the key the write was inert anyway, because `_extra_or_env`
  consults `config.extra` FIRST (`plugins/platforms/mattermost/adapter.py:491-494`, `:504` @
  `v2026.9.7`). One side, both directions. To keep the `.env` half reachable for the ABSENT-key
  case Hermes actually uses it in, `MattermostSettings` gained `requireMentionIsSet` — raw
  beside normalised, the `approvalModeRawScalar` shape — because the resolved `requireMention`
  collapses absence into `true` and cannot answer "is the key there?". Nothing is migrated
  silently: the fallback is a READ, and only a Save writes config #platforms #config
- [gotcha] **An early `guard` over one of two independently-proven reads throws away the
  other.** `NtfySetupViewModel.load` opened with `guard let cfg = snapshot.config?.ntfy else
  { return }`, so an unreadable config.yaml discarded a `.env` half that HAD been proved — P37
  finding 5's failure through the mirror. The guard moves below the `.env` assignments; the
  latched `loadRefusal` still refuses the Save
- [convention] **The forms' config scalars are refused for control characters at ONE door**,
  `commitSave`, not per form: the hazard belongs to "free text into a config.yaml scalar" and
  fifteen per-form checks are fifteen chances to miss the sixteenth. It is a VISIBILITY guard —
  these keys go out through `hermes config set`, so HERMES emits them with PyYAML and the file
  stays loadable; the damage is a value the user cannot see and Hermes never matches



## R07 — a resolved default that SHADOWS another source is not written (2026-09-26)

Hermes v0.21.5 audit, S07-F3/F4. The "write the whole block, resolved defaults included" posture stops where a written key would OVERRIDE a value that lives somewhere the form did not use to show. WhatsApp Cloud wrote `enabled: false`, `dm_policy: open` and `allow_from: ""` on every Save and broke setups made by Hermes's own `hermes whatsapp-cloud` wizard, which keeps everything in `.env`.

- [invariant] **A key that shadows another source is written only when it is already there or the user changed it.** At v2026.9.24: an explicit `platforms.<x>.enabled: false` beats env credentials (`gateway/config_env.py:182-207`); a config `allow_from` wins by PRESENCE, even empty, over `WHATSAPP_CLOUD_ALLOW_FROM`/`_ALLOWED_USERS` (`gateway/platforms/whatsapp_common.py:113-128`); a written `dm_policy` replaces the adapter's allowlist-derived default (`gateway/platforms/whatsapp_cloud.py:186-190`). `WhatsAppCloudSetupViewModel` writes `enabled: true` when the form holds the required pair, `false` only over an existing key when BOTH required fields are cleared, and `allow_from`/`dm_policy` only where they already live (or on a user change) #platforms #config
- [fact] **WhatsApp Cloud creds are an env bridge, gated on the PAIR.** `WHATSAPP_CLOUD_PHONE_NUMBER_ID` + `_ACCESS_TOKEN` must both be in `.env` for ANY `WHATSAPP_CLOUD_*` value to apply; then env overrides the config copies (`gateway/config_env.py:523-533`, `_Cred` at `:231-249`). Same bridge since the platform shipped (v2026.6.19, `gateway/config.py`). So the form writes new credentials to `.env` (off argv), but keeps a legacy config-held pair in config — moving part of it would strand the rest #platforms
- [gotcha] **`hermes config set` refuses a plain string over an existing YAML list** (`_refuse_container_type_mismatch`, `hermes_cli/config.py:3316-3335` @ v2026.9.24, verified with the real CLI). A form that reads a list-form key must write it back as a list literal (`["a", "b"]`, `[]`) #config
- [gotcha] **Webhook: the gateway listens on `WEBHOOK_ENABLED` (env), but every `hermes webhook` verb checks ONLY `platforms.webhook.enabled` in config.yaml** (`hermes_cli/webhook.py:54-55,105-107`, same since v2026.3.30). `hermes gateway setup` writes only the env flag. `WebhookSetupViewModel` writes both, and `false` only over an existing key #platforms
