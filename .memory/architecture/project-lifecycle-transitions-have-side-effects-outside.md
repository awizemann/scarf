---
title: Project lifecycle transitions have side effects outside projects.json
type: note
permalink: scarf/architecture/project-lifecycle-transitions-have-side-effects-outside
tags: [projects, lifecycle, doctor, uninstall, archive]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectLifecycleService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectsViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDoctorService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift, scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift]
source_paths_inferred: false
source_sha: 4dd744dcd1ee5a2de5612d0b0e89ff85a6225757
created: 2026-09-04
updated: 2026-09-27
reviewed: 2026-09-08
reviewed_by: audit:claude-code (background)
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
while the sidebar showed the new one. Scope of the fix (S11-F4, verified
2026-09-27): see [[Project-Scoped Chat and AGENTS.md Context]]'s gotcha on the refresh reaching only new sessions.

## Observations
- [decision] Rename propagates registry -> <root>/.scarf/project.json through ProjectStore.save, AFTER the registry write and best-effort: the registry save is what the user sees, and an unreachable record must not roll back a rename that landed. The rebuilt registry row carries uuid AND extra (R16a: dropping extra lost the archivePausedCronJobIds record, so unarchive after rename resumed nothing) #projects
- [decision] Removal is keyed by uuid (falling back to normalized path), never by display name — name-keyed removal deleted every row sharing a name, which is exactly the duplicateName state the doctor reports as individually resolvable #projects
- [decision] Removal revokes the project's mini-app grants and strips the managed AGENTS.md block; archive does NEITHER — archive pauses cron and drops the project from dashboardPaths/projectScarfDirs, because unarchive cannot restore a revoked consent decision #projects
- [decision] Archive pauses only the attributed jobs Hermes would fire (`is_job_runnable`: enabled + no pause marker) and records their ids on the registry row (`extra["archivePausedCronJobIds"]`, ProjectEntry.archivePausedCronJobIDs) in the same write as `archived`; restore resumes only recorded ids still paused, then clears the record. Archive always writes the record (`[]` = paused nothing). A row archived by an older Scarf has NO record → restore resumes nothing but shows a notice counting the project's paused jobs (via mutationError). Pause/resume failures and an unreadable jobs.json surface as mutationError; each transition awaits the previous one's `cronFollowUp` before reading jobs, and re-archiving merges the existing record (R04 S11-F2 — the old restore resumed every tagged job, switching on template jobs created paused) #projects #cron
- [decision] The managed AGENTS.md block (ManagedBlockInput.projectId) tells the agent to name cron jobs `"[proj:<uuid>] <label>"` — Scarf attributes jobs to a project ONLY by that name prefix, never by workdir (R04 S11-F5). The block's `--workdir` is NOT capability-gated: its floor is v0.12.0 (`--workdir` first at hermes_cli/main.py @ v2026.4.30, absent @ v2026.4.23; = `hasCronWorkdir`), and the block renderer (ProjectStore.agentContextBlockInput) has no capabilities, so gating it would need plumbing through the Mac and iOS callers #projects #cron
- [decision] Doctor gained recordNameMismatch (medium, safe repair renameRecordFromRegistry) and recordPathDivergence (high, REPORT-ONLY — every writer addresses a project by record.rootPath, so a move/copy has no safe automatic answer) #doctor
- [gotcha] Template uninstall must delete <root>/.scarf/project.json: leaving it makes the doctor call the folder an unlisted project and offer to ADOPT it, re-registering the uninstalled project under its original uuid with its [proj:<uuid>] cron tags intact #projects

## Relations
- relates_to [[Project Doctor reconciles three sources of truth and repairs only via existing writers]]
- relates_to [[Project ids are derived from (host, path), never minted on a read]]
- relates_to [[Integrity is not authenticity: agent-writable Scarf sidecars need a Keychain-held MAC]]
- relates_to [[Project-Scoped Chat and AGENTS.md Context]]
