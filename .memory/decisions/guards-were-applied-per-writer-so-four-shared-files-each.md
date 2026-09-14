---
title: Guards were applied per-writer, so four shared files each still have one unguarded writer
type: note
permalink: scarf/decisions/guards-were-applied-per-writer-so-four-shared-files-each
tags: [dataloss, guarded-write, projects, transport]
source_paths: [scarf/scarf/Core/Services/HermesEnvService.swift, scarf/scarf/Core/Services/ProjectConfigService.swift, scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift, scarf/scarf/Core/Services/KanbanTenantResolver.swift, scarf/scarf/Core/Services/ProjectModelPresetBinding.swift, scarf/scarf/Core/Services/SkillBootstrapService.swift]
source_paths_inferred: false
source_sha: 59fffa1977b7454a28cb7b72fd94baf09b565948
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-08
reviewed_by: audit:claude-code (background)
---

GW-E0 census (t-8ffcb4d0). The D/W/G-series guarded a FILE by guarding the writer that happened to be in the audit's path. The census revealed each of those files had a second writer that was not yet guarded — the concrete evidence for the plan's "guards applied to files, not writers" premise.

## Observations
- [fact] FOUR PARITY GAPS IDENTIFIED and subsequently closed by GW-E2a/E2c: (1) `~/.hermes/.env` had KeychainEnvMirror guarded but HermesEnvService.setMany rebuilding from a failed read into a one-line header — closed in GW-E2a, now uses `guardedMutate` with `GuardedTextFile` lock cover; (2) `<project>/.scarf/config.json` had MCP `project_set_config` guarded but `ProjectConfigService.save` not — closed in GW-E2c, now uses `inspectDecoding` with refuse-on-unreadable; (3) MEMORY.md installer appendix guarded but `ProjectTemplateUninstaller.stripMemoryBlock` not — closed in GW-E2c, now uses `GuardedTextFile.withLock`; (4) AGENTS.md `ProjectContextBlock.writeBlock` guarded but `removeBlock` not — closed in GW-E2c, both now guard via `GuardedTextFile` / `GuardedJSONStore` with proof-based reads. #dataloss
- [gotcha] `<project>/.scarf/manifest.json` had TWO copy-pasted writers — `KanbanTenantResolver.persist` and `ProjectModelPresetBinding.persist` — that both fell back to a `0.0.0` SENTINEL manifest when the read returned nil, and both re-encoded through `ProjectTemplateManifest`, dropping unknown keys even on the success path. Converted as one unit by GW-E2c. #projects
- [gotcha] A THIRD destroy shape had no read-modify-write at all: a version gate decided by inference. `SkillBootstrapService` and `SlashCommandBootstrapService` read `installedVersion` as `fileExists` + `try? readFile` — nil meant "missing" — so a blip downgraded a hand-edited SKILL.md to the bundled copy, and the next launch's version check then said "current", so it was never retried. Closed by GW-E2c with proof-based absent-vs-unreadable discrimination. #dataloss
- [constraint] The rule that generalizes all three: a failed read is never evidence about content. Whether it is spelled `?? ""`, `?? [:]`, `fileExists`, or `try? … else nil`, the writer owes the file the absent-vs-unreadable proof before it publishes.

## Status (2026-09-04)

CLOSED by GW-E2a (config.yaml, .env, MEMORY.md/USER.md) and GW-E2c (everything above: config.json,
AGENTS.md removeBlock, MEMORY.md uninstaller half, manifest.json's two writers, profile.yaml,
SKILL.md editor + both bootstrap gates, mini-app state.json). Zero `UNGUARDED-WRITE(R)` annotations
remain in the transport write surface. `ServerRegistry` (`servers.json`), which bypasses transports entirely and was invisible to the
E1 scanner, was closed separately by GW-E2b (5dd8e409) — guarded over LocalTransport,
refuse-forever, damage banner. Keep this note for the PATTERN it names and the closure history.

## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[The transport writeFile grep is not the write surface — helper seams and Data.write stores hide sites]]
