---
title: Guarded writes for shared JSON: mutate the graph, one store per file, prove absence before creating
type: note
permalink: scarf/architecture/guarded-writes-for-shared-json-mutate-the-graph-one-store
tags: [guarded-write, dataloss, projects, architecture]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedSidecarStore.swift, scarf/scarf/Core/Persistence/ServerRegistry.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantStore.swift, scarf/scarf/Core/Services/ProjectManifestStore.swift, scarf/scarf/Core/Services/ProjectConfigService.swift, scarf/scarf/Core/Services/KanbanTenantResolver.swift, scarf/scarf/Core/Services/ProjectModelPresetBinding.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedJSONStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppStore.swift, scarf/scarf/Core/Services/SkillBootstrapService.swift]
source_paths_inferred: false
source_sha: 40e8ab1f137314b4c9199b2bf8ce8addbef95980
created: 2026-09-04
updated: 2026-09-07
reviewed: 2026-09-11
reviewed_by: claude-opus-5
---

GW-E2c (t-b889e8e7). Converting the last destroy-shaped writers in the projects/skills/bots surface produced three patterns worth reusing, all of them about the shape of the fix rather than the guard itself.

## Observations
- [convention] To preserve unknown keys in a shared JSON file, decode to `JSONValue`, mutate the OBJECT GRAPH, re-encode — never re-encode through the typed model. ProjectConfigService.save and ProjectManifestStore both do this; it needs no `extra:` field on the shared model and survives keys the app has never heard of, nested ones included #guarded-write
- [architecture] `ProjectManifestStore` (Mac target) is the ONE guarded writer of `<project>/.scarf/manifest.json`; KanbanTenantResolver and ProjectModelPresetBinding both go through its `setField(_:to:for:sentinel:)`. The sentinel-manifest closure fires only on PROVEN absence, so a failed read can no longer mint a 0.0.0 stub over a real template manifest #projects
- [decision] `GuardedJSONStore.probeExistence` answers create-if-missing gates with two independent probes (fileExists, then stat) that must agree before a path is called empty. `if !fileExists { write }` is the same inference bug as `?? []` in a different hat, and the present path still answers on the first probe, so proof costs nothing when the file is there #dataloss
- [gotcha] A guard's `.bak` lands in a directory something else may LIST. SkillBootstrapService's new SKILL.md.bak showed up in the Skills file picker until SkillsScanner filtered `.bak`; check the readers of a directory before adding a backup to it #guarded-write
- [gotcha] Two source-scanning tests broke on this diff, neither by testing the changed behavior: HermesFileServiceConfigParityTests matched `GuardedTextFile(` ... `paths.configYAML` spanning a whole file (now matches `label: "config.yaml"`), and the E1 scanner's `annotated > 20` floor was a budget on an allowlist designed to shrink #testing

## Relations
- relates_to [[Guards were applied per-writer, so four shared files each still have one unguarded writer]]
- relates_to [[GuardedTextFile is the one guard for Scarf's non-JSON hand-authored files]]
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]


## GW-E3 (t-ecaccef5): the discipline became a conformance, not a convention

Commit c274e429. New type: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedSidecarStore.swift` (protocol + `GuardedDamagePolicy`), whose doc comment IS the adoption guide; `GuardedJSONStore`'s header now ends with a pointer to it. Three adopters migrated with their suites unedited: `MiniAppGrantStore`, `ProjectManifestStore` (`.quarantineAndRebuild`), `ServerRegistry` (`.refuseForever`).

- [decision] THE REBUILDABLE-VS-IRREPLACEABLE SPLIT IS A PROPERTY OF THE FILE, so it is a per-adopter declaration (`static var damagePolicy: .refuseForever | .quarantineAndRebuild`) and is deliberately NOT defaulted — a store that forgets to choose does not compile. The default implementations honour it, which is the point: `.refuseForever` must reclassify `.quarantined → .unreadable` in TWO places (the decode failure and the SIZE CAP), and the size-cap branch is the one a hand-rolled adopter forgets. `ServerRegistry` had written both by hand; the migration deletes them. #guarded-write #dataloss
- [decision] `GuardedJSONStore.Inspection.quarantineCopy` is new and survives the reclassification: the write is refused, but the user still has to be told where their bytes went — `ServerRegistry.StoreDamage.quarantinePath` is rendered as a banner. A refusal that loses the copy path is a refusal nobody can act on.
- [decision] NO SINGLE `mutate {}` CHOKEPOINT WAS IMPOSED. The invariant worth encoding is "a publish validates against the SAME inspection the in-memory state was built from", and two shapes satisfy it: the closure shape (`ProjectManifestStore`, `MiniAppGrantStore` — inspect/mutate/publish in one call, nothing held so nothing can go stale) and the held-inspection shape (`ServerRegistry` — many small `@MainActor` mutators each ending in `save()`). Forcing the first would have made the second lie about its shape. #guarded-write
- [decision] `publish(_:to:after:)` takes an OPTIONAL inspection and throws `GuardedStoreError.refusedUninspectedWrite` on `nil`. That is what makes the held shape safe: `ServerRegistry` used to seed `lastInspection = .absent`, so "never inspected" was indistinguishable from "proven absent" — i.e. writable. Unreachable today (its `init` loads), which is exactly why it needed to be structural rather than remembered.
- [constraint] The protocol requires `nonisolated var transport` and does NOT require `Sendable`, so a `@MainActor final class` (`ServerRegistry`) and an adopter with a computed `context.makeTransport()` (the two ScarfCore/Mac structs) both conform without changing when their transport is built. A `Sendable` requirement or a stored-property requirement would have excluded one of them.
- [gotcha] Non-vacuity of the two source-text scanners was re-proven empirically, not assumed: an unannotated `unguardedWriteFile(` injected into the new file failed `UnguardedWriteScanTests.everyUnguardedWriteCallSiteIsAnnotated`, and a throwaway `GuardedTextFile(… label: "config.yaml")` writer failed `AllConfigWritersParityTests.everyConfigWriterFileIsRegistered`. Both canaries were then removed. A scanner that stops biting is worse than no scanner. #testing



## GW-F6: `config.json` joins the conformers, and what conforming actually bought

Commit 10c3475f. `ProjectConfigService` is now a `GuardedSidecarStore` with `.refuseForever` declared — the fourth conformer, alongside `ServerRegistry` (`.refuseForever`), `MiniAppGrantStore` and `ProjectManifestStore` (`.quarantineAndRebuild`).

- [fact] The bug conformance fixed is the exact one the protocol's header warns about: running `GuardedJSONStore` directly, `config.json` treated undecodable bytes as `.quarantined`/writable and rebuilt from `root = [:]`, dropping every `keychain://` reference and orphaning the secrets. Declaring the policy made the three existing `if case .unreadable` branches cover the decode failure too, with no new branch — which is the whole argument for declaring rather than hand-rolling. #dataloss
- [gotcha] Conforming a type that already had a `maxBytes`-shaped constant: keep the old spelling as a computed alias (`configMaxBytes` → `maxBytes`) rather than renaming call sites, because a sibling file (`manifest.json`) deliberately borrows the same ceiling and the shared-cap comment is load-bearing.
- [convention] Section 4 (unknown keys) is a doc obligation, not just a code one: `MiniAppStore`'s `state.json` now DECLARES that its `[String: String]` model preserves every key but not a non-string value shape (that decodes-fails into quarantine), matching the way `servers.json` declares its deliberate skip.
