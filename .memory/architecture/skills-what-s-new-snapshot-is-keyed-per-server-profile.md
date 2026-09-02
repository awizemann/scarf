---
title: Skills "What's New" snapshot is keyed per (server, profile)
type: note
permalink: scarf/architecture/skills-what-s-new-snapshot-is-keyed-per-server-profile
tags: [ios, scarfgo, profiles, skills, issue-120, snapshot]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SkillSnapshotService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesProfileScope.swift, scarf/Scarf iOS/Skills/SkillsView.swift, scarf/scarf/Features/Skills/Views/SkillsView.swift]
source_sha: 6f67608679153925b5c6d55816c917ddd76bc3a2
created: 2026-06-25
updated: 2026-06-25
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

Resolves the cosmetic bug deferred from the #120 B4 integration audit: after per-connection profile switching landed, the Skills tab "What's New" pill bled across Hermes profiles (and across servers on iOS).

## Observations
- [bug] Each Hermes profile is an independent `HERMES_HOME` with its OWN `skills/` dir, but the last-seen snapshot baseline was keyed by `serverID` only — and on iOS by a FIXED context UUID (`...A1`), not the real server. So switching profiles diffed the new profile's skills against the old profile's baseline → a bogus "N new / M changed" pill. The skills LIST was always correct (it rides on `remoteHome`); only the diff indicator lied. #bug
- [fix] `SkillSnapshotService` gained an optional `profile: String?` (normalized via `HermesProfileScope` in `init`). The storage key is now `SkillSnapshotService.storageKey(for:scope:)` = bare `<serverID.uuidString>` for default/nil/invalid, or `<uuid>.<name>` for a named profile. Backends (`Mac` file / `iOS` UserDefaults / `InMemory`) compose the key from it; the `scope:` params are additive (default nil), so no caller broke. #fix
- [gotcha] iOS `SkillsView` deliberately builds its view-model on the FIXED `sharedContextID` (`...A1`) so the Skills tab reuses ONE pooled SSH connection. That id must NEVER be used for identity-bearing state. The snapshot now reads the INJECTED `@Environment(\.serverContext)` — which `ScarfGoTabRoot` sets to `effectiveConfig.toServerContext(id: serverID)` (real serverID + profile-scoped `remoteHome`) — and derives the profile via `HermesProfileScope.profileName(forHome: serverContext.paths.home)`. Conflating the pool-key id with the identity id is exactly what caused the cross-server bleed. #gotcha
- [helper] `HermesProfileScope.profileName(forHome:)` is the inverse of `resolveHome`: `<root>/profiles/<name>` → normalized `<name>`; any root home → nil. Re-validates through `normalize`, so a malformed trailing component fails safe to nil (default). #helper
- [migration] Default profile keeps the bare `<serverID>` key → existing Mac/iOS baselines resolve unchanged (no migration, no spurious "everything new"). iOS migrates off the old fixed-`A1` key gracefully: the first post-upgrade read is empty → `previousSnapshotEmpty` → the view silently primes instead of flashing a pill. The orphaned `A1` UserDefaults entry is harmless. #migration
- [mac] Mac uses the relaunch + `active_profile` model and its local `ServerContext.paths.home` stays at the root (`SidebarView.swift` "ServerContexts don't read active_profile"), so `profileName` returns nil there → unchanged key. The Mac call site still passes the derived profile for symmetry and for remotes whose `remoteHome` points directly at a profile dir. #mac
- [tests] `SkillSnapshotServiceTests` (InMemory backend): independent per-profile baselines, no false diff on switch, switch-back preserves baseline, cross-server isolation, default/invalid normalization, real-delta detection, storageKey contract. `HermesProfileScopeTests` extended with `profileName` cases + `resolveHome→profileName` round-trip. Full ScarfCore `swift test` green (677 tests); `scarf mobile` builds for iOS 26.x. #tests

## Relations
- relates_to [[Decision: ScarfGo profile switching via per-connection scoping (Design B, #120)]]
- relates_to [[Hermes profile / HERMES_HOME resolution (source-verified v0.16)]]
- relates_to [[ScarfGo iOS Companion App]]
