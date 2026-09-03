---
title: Phase-1 Milestone 3: Fleet and Portfolio dimension — implementation decisions
type: note
permalink: scarf/decisions/phase-1-milestone-3-fleet-and-portfolio-dimension-implementation-decisions
tags: [projects, phase-1, milestone-3, fleet, portfolio, config-as-policy, decision, cron]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/FleetService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectPortfolio.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/FleetApplyPlan.swift, scarf/scarf/Features/Projects/ViewModels/FleetApplyExecutor.swift, scarf/scarf/Core/Services/KanbanTenantResolver.swift, scarf/scarf/Features/Projects/Views/CockpitFleetPanel.swift]
source_paths_inferred: false
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
created: 2026-06-20
updated: 2026-06-20
reviewed: 2026-09-03
reviewed_by: audit:claude-code (background)
---

How Milestone 3 (the Fleet/Portfolio dimension — Phase-1 item #4) was built: a portfolio that groups the same project across servers by stable id, per-host config **drift**, and **apply-to-fleet** (config-as-policy). Built on `feat/projects`, incremental + tested per step, mirroring M1/M2. Read alongside the design's "Fleet dimension" section + "Decisions (locked 2026-06-14)".

## Observations

- [architecture] `FleetService` (ScarfCore/Services) gathers `ScarfProject`s across an **injected** `[ServerContext]` (the Mac target passes `ServerRegistry.allContexts` — ScarfCore can't see `ServerRegistry`, which lives in the app target) and groups them by stable `ScarfProject.id` via the pure `ProjectPortfolio.build(from:)`. Output: `ProjectPortfolio { [FleetProject{ id, name, materializations:[FleetMaterialization{serverId, serverDisplayName, project}], drift:FleetDrift }] }`. Read-only; disk/SFTP → call off-main. #fleet

- [transient-id] **CRITICAL, caught by the fresh-eyes spec-conformance review.** `FleetService.portfolio()` deliberately does NOT call `ProjectStore.list()`. `list()` falls back to `derive(from:)`, which mints a **fresh random UUID** for a registry row that has neither a `project.json` record nor a registry `uuid` (the M1 transient-id trap). A per-gather random id can never group across hosts → the project would surface as a flickering single-host phantom that changes identity every reload. The gather (`stablyIdentifiedProjects`) instead: load the record (stable id) → else derive ONLY when the registry entry already carries a `uuid` (stable) → else **skip the row**. Skipped rows acquire a stable id through normal migration (opening the project/cockpit, or the per-host eager `derive()` pass in `ProjectsView.task`, which only runs on the *current* server) and then appear in the fleet. #gotcha #fleet

- [drift] `FleetDrift.compute` flags a field as drifted when ≥2 distinct values across a group's materializations. Fields: `name`, `modelPreset`, `board`, `cron`, `memoryNamespace`, `miniApps` (compared as the Set of ref ids). **Cron is compared by COUNT, not by id** — `cronJobIds` are host-local job ids that differ per host even for the same logical jobs, so id-equality would always read as drift; count is the honest coarse signal (known false-negative: two hosts with N *different* jobs read as in-sync). Single-host projects never drift. #drift

- [config-source-of-truth] Runtime config lives in `<project>/.scarf/manifest.json` (`modelPresetID`, `kanbanTenant`), NOT in `project.json` (which is the derived index/record). So **apply-to-fleet writes the manifest** via the existing Mac-target writers, then re-derives + saves `project.json` so the Fleet panel reflects the change. Writers reused: `ProjectModelPresetBinding.bind` (model) and `KanbanTenantResolver.setTenant` (board — a **new** explicit-slug setter added for fleet; `resolveOrMint` only mints from the project *name*, which is wrong for copying a source slug verbatim). Both are transport-aware, idempotent, sentinel-mint when bare. #apply

- [apply-scope] Apply pushes **model + board + cron**. Tool/skill scoping stays DEFERRED (locked decision #2, upstream NousResearch/hermes-agent#45958) — `FleetApplyField` has no tools/skills case. Per field:
  - **model**: overwrite-safe (reversible re-bind). Applicable only when the source has a preset bound.
  - **board**: ADDITIVE — `FleetApplyPlan.disposition` emits `.apply` only for targets with NO existing tenant; a target with a different existing board is `.skip("kept to protect its tasks")` (overwriting would orphan its board tasks). `setTenant` is the low-level setter and WILL clobber if asked — the additive guard lives entirely in the plan, not the setter.
  - **cron**: recreate the source's `[proj:<id>]` jobs on each target via `hermes cron create`, with prompts **path-rewritten** source-root→target-root. The user chose this over deferring cron (the spec wanted it). #apply

- [cron-path-rewrite] `FleetApplyPlan.rewriteCronPrompt` is the pure, unit-tested core of the risky bit: Hermes runs cron with no CWD, so prompts are fully-qualified with the source host's absolute project path, which is wrong on a target where the repo lives elsewhere. The rewriter is **boundary-aware** — only replaces the root when followed by `/`, whitespace, a quote, or end-of-string, so `/work/proj` never matches inside `/work/proj2` and unrelated text is never corrupted (conservative: under-replaces on exotic trailing punctuation like `…/proj.`). Created jobs are **created-then-paused** (mirror `ProjectTemplateInstaller`) so a fleet push never silently arms autonomous cron on a remote. Idempotent: skip by job name, including a within-pass dedupe for duplicate source names. Pause failures are surfaced in the result message (not just logged) since an unpaused created job is live on a remote the user must see. #cron

- [cron-fidelity-gap] A loaded `HermesCronJob` exposes no `repeat`/`repeatCount`, so `--repeat` (and `model`, `workdir`, `timeout*`, `noAgent`, `contextFrom`) are NOT forwarded to recreated jobs — only `--name`, `--deliver`, `--skill`, schedule, prompt. A bounded source job becomes unbounded on the target. Documented limitation, not fixable without extending the model + knowing the jobs.json repeat shape. #deferred

- [split] Pure plan/drift/path-rewrite in ScarfCore (`ProjectPortfolio`, `FleetService`, `FleetApplyPlan` — all unit-tested incl. rewriter edge cases); the I/O executor (`FleetApplyExecutor`) is Mac-target (reuses the writers + `hermes cron create`, maps `serverId`→`ServerContext` via the injected contexts). **NON-FATAL**: every field write and every target is isolated in its own catch; one failing write / unreachable host / missing context becomes a per-field/per-target result, never aborts the rest. #architecture

- [ui] Fleet is a new `CockpitPanel` case (`.fleet`, last panel) in `ProjectCockpitView` (which now also reads `@Environment(ServerRegistry.self)`). `CockpitFleetPanel` renders the per-project slice: materializations (host badge / path / per-host config readout with drifted fields tinted) + a drift callout + an "Apply to Fleet…" button gated on `isMultiHost && !applicableFields.isEmpty`. `FleetApplySheet` is the pick-fields/pick-hosts + live plan preview + off-main execute + results view. `FleetPanelViewModel`/`FleetApplyViewModel` mirror `ProjectCockpitViewModel`'s off-main `Task.detached` load shape. The panel clears its VM at the top of `.task(id:)` so a project switch never shows the prior project's fleet. #ui

- [testing] ScarfCore 696 green incl. `FleetServiceTests` (13 — grouping, drift per field, canonical name, transient-id skip, disk gather) + `FleetApplyPlanTests` (11 — dispositions, additive board guard, path-rewrite edge cases). Mac: `FleetApplyExecutorTests` (model+board apply effect end-to-end via a temp-home `.local(home:)`, additive board no-clobber, unregistered-server NON-FATAL) + `KanbanTenantResolverSetTenantTests` (3). **Cron apply execution + true-remote serverId routing are build-verified only** — `ServerContext.local(home:)` keeps the fixed local id so it can't stand in for two distinct servers, and cron needs the `hermes` CLI; the rewriter core is unit-tested instead. Mirrors M2's "bridge build-verified only" posture. #testing

- [review] A fresh-eyes parallel advisory review (4 agents: ScarfCore pure logic, executor safety, spec-conformance, SwiftUI/VMs) ran at code-complete and caught real bugs that were then fixed: the transient-id HIGH (above); duplicate-source-cron-name double-create; pause-failure invisibility; the `.task(id:)` cross-project stale frame; and a lying `Phase: Equatable` (replaced with an `isApplying` computed). The pattern held — it caught real issues, as in M1/M2. #review

- [deferred] (1) No standalone fleet-WIDE portfolio destination — the portfolio model/service exist + are tested, but the only consumer is the per-project `CockpitFleetPanel` (the design's explicitly-endorsed "or a cockpit Fleet panel" option). (2) No per-push teardown/lock manifest — reversibility is per-facet (model re-bind, cron paused+removable), not a single undo. (3) Tool/skill scoping still deferred (hermes-agent#45958). #deferred

## Relations
- relates_to [[Phase-1 Milestone 1: First-Class Project Object — implementation decisions]]
- relates_to [[Phase-1 Milestone 2: Mini-apps — implementation decisions]]
- relates_to [[Fast test-iteration commands (swift test vs xcodebuild)]]
- relates_to [[ScarfCore tests inject a temp Hermes home via ServerContext.local(home:)]]
