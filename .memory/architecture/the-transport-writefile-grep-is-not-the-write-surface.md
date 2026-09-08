---
title: The transport writeFile grep is not the write surface — helper seams and Data.write stores hide sites
type: note
permalink: scarf/architecture/the-transport-writefile-grep-is-not-the-write-surface
tags: [transport, dataloss, guarded-write, projects]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift, scarf/scarf/Core/Services/HermesFileService.swift, scarf/scarf/Core/Persistence/ServerRegistry.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GatewayConfigWriter.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift]
source_paths_inferred: false
source_sha: c274e429308eb0a19bbfcae56761d89f056f9091
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-04
reviewed_by: claude-fable-5
---

GW-E0 (t-8ffcb4d0) census. Enforcing guarded writes by renaming `ServerTransport.writeFile` catches 42 sites — and misses whole classes of writer that destroy the same files. Recorded so a future "we renamed the method, we're covered" claim gets checked against this.

## Observations
- [gotcha] TWO HELPER SEAMS hide destroy-shaped writers from any `.writeFile(` grep: `ServerContext.writeText` and `HermesFileService.writeFile(_:content:)`. Renaming the transport method annotates the WRAPPER while the read-then-write lives in its callers — `SettingsViewModel.saveDirectYAML` and `GatewayConfigWriter.saveList` both do `context.readText(path) ?? ""` on `~/.hermes/config.yaml`, splice, and publish, so one dropped SSH round-trip publishes a config.yaml holding only the section being edited. #dataloss
- [gotcha] `ServerRegistry` (servers.json — the user's entire server list) bypasses transports entirely: `load()` sets `entries = []` on ANY read/decode failure and `save()` publishes the whole list via `Data.write(to:options:.atomic)`. That is the projects.json bug verbatim on a file no transport-level enforcement can ever see. CLOSED in GW-E2b (5dd8e409): it now runs `GuardedJSONStore` over `LocalTransport`, refuses forever (its rows exist nowhere else), keeps a one-deep `.bak`, and surfaces `ServerRegistry.StoreDamage` as a banner in ManageServersView. #dataloss
- [constraint] A guarded-write scanner must cover THREE idioms, not one: the renamed transport method, the local text-helper seams (`writeText(`, `writeFile(_:content:)`), and `Data.write(to:)` against a Scarf-owned state path. #convention
- [fact] The remaining local `Data.write` sites are legitimately outside the guarded surface — export staging, user-chosen save panels, diagnostics, and the transports' own internals — so the rule is about Scarf-owned LIVE state, not about Foundation file APIs per se.

## Relations
- relates_to [[Transport atomic-write parity is a per-transport contract, not a property of writeFile]]
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
