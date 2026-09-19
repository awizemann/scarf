---
title: GuardedTextFile is the one guard for Scarf's non-JSON hand-authored files
type: note
permalink: scarf/architecture/guardedtextfile-is-the-one-guard-for-scarf-s-non-json-hand
tags: [guarded-write, dataloss, config, architecture]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedTextFile.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedJSONStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/SkillsViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetEnabler.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/TransportPrivateMode.swift, scarf/scarf/Core/Services/HermesEnvService.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-04
updated: 2026-09-10
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations

- [convention] (GW-E2c) An EDITOR over a guarded text file must hold the `Loaded` token, not re-check in the writer: SkillsViewModel keeps `loadedContent: GuardedTextFile.Loaded?`, and a refused load leaves it nil so Save has no path at all. The old `?? ""` loader's empty buffer became unsavable by construction rather than by a check someone could remove #guarded-write
- [gotcha] (GW-F6) `Loaded.init` is `internal` (not `public`) to prevent forging proof tokens from outside ScarfCore. Within the same module, only `load()` and successful-write re-stamping (like SkillsViewModel does at `SkillsViewModel.swift:1281`) may construct it; a public init would let any code forge a blank-buffer token and bypass the guard entirely #guarded-write
- [gotcha] (GW-E2c) After a successful guarded write, REFRESH the token with the bytes just published (`Loaded(text:exists:inspection:)` is available in-module only). A stale token makes the second save in one sitting back up the version from two saves ago #guarded-write

- [architecture] GuardedTextFile wraps GuardedJSONStore.inspect for hand-authored text (config.yaml, .env, MEMORY.md, USER.md): stat+retry proof, one-deep .bak, and write() reachable only via a Loaded returned by load() #guarded-write
- [decision] Zero bytes is a LEGAL state for these files, but Loaded.exists stays true for an empty file — .env's 'create fresh with header' branch must not fire on an existing empty file #dataloss
- [decision] Non-UTF-8 bytes REFUSE rather than quarantine-and-rebuild: these files are the projects.json case (contents exist nowhere else), not the rebuildable-sidecar case #guarded-write
- [gotcha] GuardedTextFile deliberately skips GuardedJSONStore.write's createDirectory: these parents always exist and several call sites (SettingsViewModel.saveDirectYAML) run sync transport I/O on the main actor, where a gratuitous round-trip is a hang (C10) #concurrency
- [gotcha] .env.bak carries the same secrets as .env; TransportPrivateMode.originalBasename already strips .bak/.corrupt- so LocalTransport still enforces 0600 on it #security

- [convention] (GW-F2) The LOAD is the surface a caller must expose, not a `?? ""` convenience on top of it. `HermesFileService.loadMemoryFile`/`loadUserProfileFile` return the `Loaded`; `saveMemory(_:profile:after:)` takes it, so the Mac editor's conflict check and its write share ONE read and one inspection. A caller that re-reads between the check and the write reopens the window the token exists to close #guarded-write
- [gotcha] (GW-F2) Do NOT thread a `Loaded` from an editor's INITIAL load into a save that happens minutes later (iOS `IOSMemoryViewModel` deliberately re-reads): the token's bytes become the `.bak`, so a stale one archives a version the file no longer holds. Thread it only when the read was taken immediately before the write #guarded-write


## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[Guards were applied per-writer, so four shared files each still have one unguarded writer]]
- relates_to [[The transport writeFile grep is not the write surface — helper seams and Data.write stores hide sites]]


## GW-F3 — the guard also owns the serialization (DI H4 + M9)

- [architecture] (GW-F3, DI H4) `GuardedTextFile(context:label:)` is the SERIALIZED initializer — it derives a `RegistryWriteLock` per protected path — while `GuardedTextFile(transport:label:)` takes none. `mutate(path) { loaded in newText? }` is the load-mutate-write entry point that CANNOT be entered without the lock; `withLock(path) { … }` is the manual form for the two flows that genuinely split load and write (the memory editor's conflict check, `HermesFileService`'s MCP publish→re-read→restore). Returning `nil` from mutate's body publishes nothing #guarded-write
- [decision] (GW-F3) LOCKED = the four hermes-GLOBAL files (config.yaml, .env, MEMORY.md, USER.md): each has several writers, at least one not user-driven (launch reconcile, template install, the scarf-projects MCP helper). NOT locked, deliberately = the per-project / per-skill files (AGENTS.md via ProjectContextBlock, SKILL.md via SkillsViewModel, a bot's profile.yaml via BotsService): one user-driven writer each, at a path nobody else shares, and a lock file per project/skill folder would be agent-visible litter in directories Scarf does not own. `GuardedTextFileLockF3Tests.everyWriterOfAProtectedFileGoesThroughTheLock` carries the coverage table AND enforces it against the source #guarded-write
- [gotcha] (GW-F3) A lock around only the PUBLISH is theatre — the `Loaded` the write validates against must be a read taken under the SAME hold, or the read-modify-write window is exactly where it was. This is why `saveMemory` lost its `after:` proof parameter and `MemoryViewModel.save` now calls `HermesFileService.saveMemoryFile(_:target:profile:ifMatches:)`, which does the baseline comparison under the lock and returns `.saved` / `.conflict(onDisk:)` #guarded-write
- [gotcha] (GW-F3) `RegistryWriteLock`'s reentrancy is THREAD-LOCAL, so a hold must never span an `await`. `KanbanToolsetEnabler` had its load and its write in two separate `Task.detached`s — different threads — and had to be collapsed into one detached `applyPlan` before it could hold a lock at all. Any async adopter needs the whole read-modify-write inside ONE detached block #concurrency
- [decision] (GW-F3) `SettingsViewModel.saveDirectYAML` once took the lock with a 2s `acquireTimeout` override (`RegistryWriteLock.withAcquireTimeout`) because that frame was synchronous ON THE MAIN ACTOR (PERF H2 / t-26bf60b8) and the default 60s remote bound would have been a minute of frozen UI (charter C10). **SUPERSEDED (GW-F6 / PERF H2):** the whole read-modify-write now runs in ONE `Task.detached(priority: .userInitiated)` holding `withLock` across both the load and the write, so the override is GONE and this adopter inherits the same acquire bound as every other one. The one-detached-hop rule still binds — `RegistryWriteLock` reentrancy is thread-local. Contention still reports `registryBusy` through the existing failure toast #concurrency
- [decision] (GW-F3) Lock scope is LOCAL serialization, inherited from RegistryWriteLock: one host's processes contend on one lock file. Two Macs pointed at one remote `~/.hermes` stay LAST-WRITE-WINS — an accepted, documented residual. For a remote context the lock file is a LOCAL stand-in in Application Support, so acquiring it adds ZERO SSH round-trips and leaves no litter on the remote host #guarded-write
- [architecture] (GW-F3, DI M9) `.env` has ONE guard implementation again. `KeychainEnvMirror` used to hand-roll `GuardedJSONStore.inspect` + its own zero-byte reclassification + its own write for the same file `HermesEnvService` guarded with `GuardedTextFile`; it is now a thin `mutateEnv` adapter over `GuardedTextFile.mutate`, re-throwing the refusals as its own `EnvMirrorError` cases so callers and tests are unchanged. `envHasExactlyOneGuardImplementation` fails the build if a second `GuardedJSONStore(` appears in either `.env` writer #guarded-write
