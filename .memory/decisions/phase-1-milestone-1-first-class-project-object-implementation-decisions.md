---
title: Phase-1 Milestone 1: First-Class Project Object — implementation decisions
type: note
permalink: scarf/decisions/phase-1-milestone-1-first-class-project-object-implementation-decisions
tags: [projects, phase-1, milestone-1, decision, scarfproject, architecture]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ScarfProject.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift]
source_sha: c09ee3811bd75bae2d7416178d880f5d5b8c64b6
created: 2026-06-15
updated: 2026-09-03
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

How Milestone 1 (the first-class `ScarfProject`) was actually built, and the non-obvious calls a future agent must know before touching the model, the registry, or the fleet/portfolio work. Built on `feat/projects` per the impl spec.

## Observations
- [model] `ScarfProject` (ScarfCore/Models) is the canonical record: `id: UUID`, name, rootPath, created/updatedAt, modelPresetId, scopedToolsets/Skills (empty — deferred), board, cronJobIds, memoryNamespace, secretsScope, templateLockRef, hostBindings. Codable is hand-written, lenient + additive (decodeIfPresent + defaults; minimal `{id,name,rootPath}` decodes; unknown keys ignored) with ISO-8601 string dates — self-contained, no decoder-strategy dependency. #scarfproject
- [id-decision] `ProjectEntry.id` STAYS the display name (`var id: String { name }`). The stable UUID was added as a SEPARATE `uuid: UUID?` metadata field, NOT by retyping `id` to UUID. Why: `id`/name is load-bearing for SwiftUI selection (`selectedProjectName`), `.sheet(item:)`, and ForEach across the whole app; retyping would ripple through selection/equality everywhere — risky and out of M1 scope. `ProjectEntry` Equatable/Hashable are hand-written to EXCLUDE `uuid` (logical identity = name+path+folder+archived) so back-filling the UUID never disturbs selection highlight or sheet identity. Canonical stable id lives on `ScarfProject.id`; `ProjectEntry.uuid` mirrors it. **Fleet/portfolio (Phase-1 #4) keys on the UUID, not the name.** #decision #gotcha
- [store] `ProjectStore` (ScarfCore/Services) mirrors `ProjectDashboardService` (context + transport, all nonisolated). Canonical record = `<project>/.scarf/project.json`; the existing `~/.hermes/scarf/projects.json` registry is the fast-list INDEX (extended with `ProjectEntry.uuid`) — do NOT create a parallel index. `save()` writes the record + upserts the registry uuid (idempotent — only writes when changed). `list()` = registry rows → `load()` each (derive on the fly when no record). #store
- [migration] `ProjectStore.derive()` (no-arg) is the additive/idempotent/non-destructive migration: per registry row missing a record OR a uuid, derive from existing on-disk state + persist; steady state writes nothing. Triggered three ways: eager best-effort from `ProjectsView.task` (off-main `Task.detached`), lazy per-project from the cockpit (load-or-derive-and-save), and explicitly at scaffold time. `derive(from: entry)` is the pure per-entry builder. #migration
- [refresh] `ProjectAgentContextService.refresh(for: ProjectEntry)` KEPT its signature (callers unchanged) but now builds a `ScarfProject` via `load ?? derive` and renders from it. It does NOT persist — render-only, to avoid chat-start file churn. Migration/persistence happens via cockpit + scaffolder + the ProjectsView eager pass. #refresh
- [renderblock] `renderBlock` now takes `ScarfProject` (the inversion). The object is the source of truth for identity/board/templateLockRef; but template id/version, config-field names, slash commands, and cron schedule display are STILL read from disk via `rootPath` because the object stores references, not resolved detail. SECRET-SAFE config-fields line preserved verbatim. Cron line matches BOTH `[proj:<uuid>]` and legacy `[tmpl:<templateId>]`. Rendered block is byte-identical to pre-M1 for installed templates (idempotency + Template E2E stay green). #renderblock
- [secrets] `secretsScope` = `config.json` keys whose value is a `keychain://…` ref — NAMES only, never values (SECRET-SAFE). ScarfCore can't see the Mac-target manifest/config Codable types, so `ProjectStore` uses lightweight JSON projections, same trick as `KanbanTenantReader` / `ProjectModelPresetReader`. #secret-safe
- [cockpit] `ProjectCockpitView` is a `DashboardTab.cockpit` tab inside the Projects feature (not a new sidebar section). Header (name/path/model badge/host badges) + panel bar reusing `ProjectSessionsView` + `ProjectKanbanTab` (gated on `hasKanban`) + 5 new lightweight read-only panels (Context/Cron/Memory/Secrets/Templates). Backed by `ProjectCockpitViewModel` (one off-main load). #cockpit
- [deferred] Tool/skill scoping NOT built — `scopedToolsets`/`scopedSkills` always empty; ACP adapter hardcodes `enabled_toolsets`, no per-session seam. Unblocks on NousResearch/hermes-agent#45958. Mini-apps = Milestone 2 (will add `ScarfProject.miniApps` + the `scarf-miniapp://` bridge). #deferred
- [done] Installer parity gap CLOSED (in commit 9be1e2f): `ProjectTemplateInstaller.registerProject` mints the uuid and `install()` writes `.scarf/project.json` after the lock file lands, symmetric with the scaffolder. Phase 3 (9be1e2f) then removed the underlying hazard — `derive(from:)` no longer mints a fresh random uuid per call; see [[Project ids are derived from (host, path), never minted on a read]]. #done
- [tests] ScarfCore: 637 pass incl. new `ScarfProjectTests` (4) + `ProjectStoreTests` (8). App: `ProjectAgentContextServiceTests` 13/13 (SECRET-SAFE + IDEMPOTENT held), `ProjectScaffolderTests` 3/3. See [[Fast test-iteration commands (swift test vs xcodebuild)]]. #testing

## Relations
- relates_to [[ScarfCore tests inject a temp Hermes home via ServerContext.local(home:)]]
- relates_to [[Fast test-iteration commands (swift test vs xcodebuild)]]
