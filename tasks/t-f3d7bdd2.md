---
id: t-f3d7bdd2
title: Clear the stale shadow a shared-key rewrite leaves behind
status: todo
added: 2026-09-11
---

## Description

`HermesPlatformSharedKeys.resolved` (scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPlatformSharedKeys.swift:153-215) MOVES a `_SHARED_KEYS` write onto the section Hermes bridges from, but it does not MIGRATE: whatever already sits at the source spelling is left behind as a stale shadow.

Hermes ignores it today — only `platform_section`'s chosen section reaches `extra` (`gateway/config_loader.py:171-180`, `:249-283` @ v2026.9.7) — but it is visible in config.yaml and it becomes LIVE the moment the bridge source changes (e.g. a later `hermes setup` adds or removes a top-level `<platform>:` block). At that point the user's config silently reverts to whatever the shadow holds.

Not fixed in P46 because there is no clearing verb: `hermes config unset` is the host-default-picker verb, and `hermes config` has no general delete for an arbitrary key. Clearing the shadow means hand-editing config.yaml through `GuardedTextFile`, which is a different write door with its own managed-host and locking rules.

Scope when picked up:
- decide whether the shadow is cleared at save time (a direct-YAML splice beside the `config set` batch) or surfaced to the user instead
- if cleared: it must go through the same `managedBannerText` bounce `saveDirectYAML` now has, and through `GuardedTextFile`
- a test pinning that a rewrite leaves no readable value at the source spelling

Filed by P46 finding 1 on `fix/whole-surface-audit-r4`.

## Plan



## Artifacts



