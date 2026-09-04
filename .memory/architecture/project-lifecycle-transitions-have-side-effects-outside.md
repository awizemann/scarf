---
title: Project lifecycle transitions have side effects outside projects.json
type: note
permalink: scarf/architecture/project-lifecycle-transitions-have-side-effects-outside
tags: [projects, lifecycle, doctor, uninstall, archive]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectLifecycleService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectsViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDoctorService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift, scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift]
source_paths_inferred: false
source_sha: 78cccf7a762b94fa125f4d9d8753c58ec19df3cd
created: 2026-09-04
updated: 2026-09-04
---

D2 (t-a2c169f0). Adding a project touched half a dozen stores; removing,
renaming and archiving each touched exactly one. `ProjectLifecycleService`
is now the single place those transitions are spelled out, so a new caller
gets the whole set rather than the half it remembered. Everything in it is
best-effort and reports rather than throws: none of it may fail a mutation
the registry already committed.

The rename half is the one users could see indirectly: the record's `name`
is what `renderAgentContextBlock` injects into every chat opened in the
project, so a registry-only rename told the agent the OLD name forever
while the sidebar showed the new one.

## Observations
- [decision] Rename propagates registry -> <root>/.scarf/project.json through ProjectStore.save, AFTER the registry write and best-effort: the registry save is what the user sees, and an unreachable record must not roll back a rename that landed #projects
- [decision] Removal is keyed by uuid (falling back to normalized path), never by display name — name-keyed removal deleted every row sharing a name, which is exactly the duplicateName state the doctor reports as individually resolvable #projects
- [decision] Removal revokes the project's mini-app grants and strips the managed AGENTS.md block; archive does NEITHER — archive pauses cron and drops the project from dashboardPaths/projectScarfDirs, because unarchive cannot restore a revoked consent decision #projects
- [decision] Doctor gained recordNameMismatch (medium, safe repair renameRecordFromRegistry) and recordPathDivergence (high, REPORT-ONLY — every writer addresses a project by record.rootPath, so a move/copy has no safe automatic answer) #doctor
- [gotcha] Template uninstall must delete <root>/.scarf/project.json: leaving it makes the doctor call the folder an unlisted project and offer to ADOPT it, re-registering the uninstalled project under its original uuid with its [proj:<uuid>] cron tags intact #projects

## Relations
- relates_to [[Project Doctor reconciles three sources of truth and repairs only via existing writers]]
- relates_to [[Project ids are derived from (host, path), never minted on a read]]
- relates_to [[Integrity is not authenticity: agent-writable Scarf sidecars need a Keychain-held MAC]]
