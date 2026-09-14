---
title: Setup forms write the resolved default; Settings treats absence as a sentinel
type: note
permalink: scarf/decisions/setup-forms-write-the-resolved-default-settings-treats
tags: [platforms, settings, config, hermes]
source_paths: [scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift]
source_paths_inferred: false
source_sha: 698bee2966bf21228c03b00df7fe0105d7e61781
created: 2026-09-10
updated: 2026-09-12
reviewed: 2026-09-12
reviewed_by: claude-opus-5
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
