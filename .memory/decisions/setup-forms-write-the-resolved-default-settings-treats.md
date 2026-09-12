---
title: Setup forms write the resolved default; Settings treats absence as a sentinel
type: note
permalink: scarf/decisions/setup-forms-write-the-resolved-default-settings-treats
tags: [platforms, settings, config, hermes]
source_paths: [scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift]
source_paths_inferred: false
source_sha: ca6ae1e8832242f31b5c6ccdd3b390186b1af8cb
created: 2026-09-10
updated: 2026-09-10
reviewed: 2026-09-10
reviewed_by: claude-opus-5
---

Round-3 product decision 9 (Alan, 2026-09-10), shipped in P33 as a doc comment on `PlatformSetupForm` plus this note. No behaviour change — the two surfaces already differed, and the difference was intentional and undocumented.

A platform setup form is a "set up this platform" gesture: it writes the WHOLE block explicitly, resolved defaults included (`api_version: "v20.0"`, `dm_policy: "open"`, `enabled: true|false`), because the block is authored as a unit, a half-written platform block is a platform that half-starts, and the form IS the record of the decision. Settings edits ONE key at a time, where absence is a SENTINEL ("Host default") that must survive an unrelated save: writing the resolved default there would freeze today's Hermes default into the file and silently opt the user out of the host's future one.

If a form ever needs Settings' posture, it needs a sentinel of its own first.

## Observations
- [decision] A platform setup form writes its whole config.yaml block on Save, resolved defaults included; Settings writes only the key the user edited and treats absence as a "Host default" sentinel #platforms #settings
- [invariant] A sentinel row in Settings is a no-op write; a setup form has no sentinel, so it may not adopt Settings' posture without inventing one #settings
- [gotcha] The two postures look inconsistent from outside and the inconsistency is load-bearing: freezing today's Hermes default into config.yaml opts the user out of the host's future default #config

## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[GuardedTextFile is the one guard for Scarf's non-JSON hand-authored files]]
