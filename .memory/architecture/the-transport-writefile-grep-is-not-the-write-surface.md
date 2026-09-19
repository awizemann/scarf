---
title: The transport writeFile grep is not the write surface — helper seams and Data.write stores hide sites
type: note
permalink: scarf/architecture/the-transport-writefile-grep-is-not-the-write-surface
tags: [transport, dataloss, guarded-write, projects]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift, scarf/scarf/Core/Services/HermesFileService.swift, scarf/scarf/Core/Persistence/ServerRegistry.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GatewayConfigWriter.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift, scarf/scarf/Features/Servers/Views/ManageServersView.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [gotcha] TWO HELPER SEAMS exist but are now properly walled off with explicit naming and enforcement: `ServerContext.unguardedWriteText` and the transport's raw `unguardedWriteFile` primitive. The E0 census found them, but GW-E2a / GW-F5 have since converted all five unsafe read-then-write callers in `SettingsViewModel.saveDirectYAML` and `GatewayConfigWriter.saveList` to use `GuardedTextFile` instead — both now hold the write lock across read-modify-write, surfacing refusals through the same `saveMessage` a write failure does. The remaining `UNGUARDED-WRITE` call sites are marked with line-level annotations (rule 2 in UnguardedWriteScanTests) so they're impossible to miss in review, and the `unguardedWriteText` name itself prevents accidental confusion with protected paths. #dataloss #convention
- [fact] `saveDirectYAML` (P33 refactor) explicitly joins a `writeChain` for intra-process serialization — the guarded lock protects BYTES from other processes, but the chain orders THIS process's own writes against each other. Without the chain, a config write queued by one async task would be overwritten by a concurrent toggle's write/re-read pair. #dataloss
- [gotcha] `ServerRegistry` (servers.json — the user's entire server list) bypassed transports entirely before GW-E2b: `load()` set `entries = []` on ANY read/decode failure and `save()` published via `Data.write(to:options:.atomic)`. That pattern is now CLOSED (5dd8e409): it runs `GuardedSidecarStore` over `LocalTransport`, refuses forever (its rows exist nowhere else), keeps a one-deep `.bak`, and surfaces `ServerRegistry.StoreDamage` as a banner in ManageServersView. #dataloss
- [constraint] A guarded-write scanner must cover THREE idioms, not one: (1) the renamed transport method, (2) the local helper seams (`unguardedWriteText`) with line-level annotation enforcement, and (3) `Data.write(to:)` against a Scarf-owned state path. #convention
- [fact] The remaining local `Data.write` sites are legitimately outside the guarded surface — export staging, user-chosen save panels, diagnostics, and the transports' own internals — so the rule is about Scarf-owned LIVE state, not about Foundation file APIs per se.

## Relations
- relates_to [[Transport atomic-write parity is a per-transport contract, not a property of writeFile]]
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
