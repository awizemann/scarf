---
title: GuardedTextFile is the one guard for Scarf's non-JSON hand-authored files
type: note
permalink: scarf/architecture/guardedtextfile-is-the-one-guard-for-scarf-s-non-json-hand
tags: [guarded-write, dataloss, config, architecture]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedTextFile.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedJSONStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetEnabler.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GatewayConfigWriter.swift, scarf/scarf/Core/Services/HermesEnvService.swift, scarf/scarf/Core/Services/HermesFileService.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift]
source_paths_inferred: false
source_sha: d0bc77bd0c89f2596dcfc69d532f257420f50029
created: 2026-09-04
updated: 2026-09-04
---

GW-E2a. `~/.hermes/config.yaml` had FIVE independent read-modify-write writers, each carrying its own private read (`readText(path) ?? ""`, `readFile(...) ?? nil`, `try? readFile ... else header`). That is the per-writer disease the GW arc exists to kill: the guard gets applied to a FILE by whichever writer someone audited, and the next writer of the same file reopens the hole. `GuardedTextFile` (Services/GuardedTextFile.swift, beside GuardedJSONStore) is now the single shared guard for the non-JSON side. `load` returns a `Loaded` (text + `exists` + the inspection) and `write` is only reachable with a `Loaded`, so carrying the proof is a type-level precondition rather than a convention a reviewer has to notice.

## Observations

- [convention] (GW-E2c) An EDITOR over a guarded text file must hold the `Loaded` token, not re-check in the writer: SkillsViewModel keeps `loadedContent: GuardedTextFile.Loaded?`, and a refused load leaves it nil so Save has no path at all. The old `?? ""` loader's empty buffer became unsavable by construction rather than by a check someone could remove #guarded-write
- [gotcha] (GW-E2c) After a successful guarded write, REFRESH the token with the bytes just published (`Loaded(text:exists:inspection:)` is public). A stale token makes the second save in one sitting back up the version from two saves ago #guarded-write

- [architecture] GuardedTextFile wraps GuardedJSONStore.inspect for hand-authored text (config.yaml, .env, MEMORY.md, USER.md): stat+retry proof, one-deep .bak, and write() reachable only via a Loaded returned by load() #guarded-write
- [decision] Zero bytes is a LEGAL state for these files, but Loaded.exists stays true for an empty file — .env's 'create fresh with header' branch must not fire on an existing empty file #dataloss
- [decision] Non-UTF-8 bytes REFUSE rather than quarantine-and-rebuild: these files are the projects.json case (contents exist nowhere else), not the rebuildable-sidecar case #guarded-write
- [gotcha] GuardedTextFile deliberately skips GuardedJSONStore.write's createDirectory: these parents always exist and several call sites (SettingsViewModel.saveDirectYAML) run sync transport I/O on the main actor, where a gratuitous round-trip is a hang (C10) #concurrency
- [gotcha] .env.bak carries the same secrets as .env; TransportPrivateMode.originalBasename already strips .bak/.corrupt- so LocalTransport still enforces 0600 on it #security

## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[Guards were applied per-writer, so four shared files each still have one unguarded writer]]
- relates_to [[The transport writeFile grep is not the write surface — helper seams and Data.write stores hide sites]]
