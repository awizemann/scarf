---
title: Guards were applied per-writer, so four shared files each still have one unguarded writer
type: note
permalink: scarf/decisions/guards-were-applied-per-writer-so-four-shared-files-each
tags: [dataloss, guarded-write, projects, transport]
source_paths: [scarf/scarf/Core/Services/HermesEnvService.swift, scarf/scarf/Core/Services/ProjectConfigService.swift, scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift, scarf/scarf/Core/Services/KanbanTenantResolver.swift, scarf/scarf/Core/Services/ProjectModelPresetBinding.swift, scarf/scarf/Core/Services/SkillBootstrapService.swift]
source_paths_inferred: false
source_sha: c274e429308eb0a19bbfcae56761d89f056f9091
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-04
reviewed_by: claude-fable-5
---

GW-E0 census (t-8ffcb4d0). The D/W/G-series guarded a FILE by guarding the writer that happened to be in the audit's path. The census shows each of those files has a second writer that was never touched — the concrete evidence for the plan's "guards applied to files, not writers" premise.

## Observations
- [fact] FOUR PARITY GAPS, each a file with one guarded and one unguarded writer: `~/.hermes/.env` (KeychainEnvMirror guarded, `HermesEnvService.setMany` still rebuilds from a failed read into a one-line header), `<project>/.scarf/config.json` (MCP `project_set_config` guarded, `ProjectConfigService.save` not), `MEMORY.md` (installer appendix guarded, `ProjectTemplateUninstaller.stripMemoryBlock` not), `AGENTS.md` (`ProjectContextBlock.writeBlock` guarded, `removeBlock` not). #dataloss
- [gotcha] `<project>/.scarf/manifest.json` has TWO copy-pasted writers — `KanbanTenantResolver.persist` and `ProjectModelPresetBinding.persist` — that both fall back to a `0.0.0` SENTINEL manifest when the read returns nil, and both re-encode through `ProjectTemplateManifest`, dropping unknown keys even on the success path. Convert them as one unit or the loss just moves. #projects
- [gotcha] A THIRD destroy shape has no read-modify-write at all: a version gate decided by inference. `SkillBootstrapService` and `SlashCommandBootstrapService` read `installedVersion` as `fileExists` + `try? readFile` — nil means "missing" — so a blip downgrades a hand-edited SKILL.md to the bundled copy, and the next launch's version check then says "current", so it is never retried. `ProjectUpgradeService`'s `!fileExists(dashboardPath)` placeholder gate is the same family. #dataloss
- [constraint] The rule that generalizes all three: a failed read is never evidence about content. Whether it is spelled `?? ""`, `?? [:]`, `fileExists`, or `try? … else nil`, the writer owes the file the absent-vs-unreadable proof before it publishes.

## Status (2026-09-04)

CLOSED by GW-E2a (config.yaml, .env, MEMORY.md/USER.md) and GW-E2c (everything above: config.json,
AGENTS.md removeBlock, MEMORY.md uninstaller half, manifest.json's two writers, profile.yaml,
SKILL.md editor + both bootstrap gates, mini-app state.json). Zero `UNGUARDED-WRITE(R)` annotations
remain in the transport write surface. `ServerRegistry` (`servers.json`), which bypasses transports entirely and was invisible to the
E1 scanner, was closed separately by GW-E2b (5dd8e409) — guarded over LocalTransport,
refuse-forever, damage banner. Keep this note for the PATTERN it names, not as an open bug list.



## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[The transport writeFile grep is not the write surface — helper seams and Data.write stores hide sites]]
