---
title: Project Upgrade — one-click structure pass + chat enrichment (deterministic ProjectUpgradeService + skills)
type: note
permalink: scarf/decisions/project-upgrade-one-click-structure-pass-chat-enrichment-deterministic-projectupgradeservice-skills
tags: [projects, upgrade, skills, mini-app, decision, phase-1]
created: 2026-06-20
updated: 2026-09-03
---

How "Upgrade Project" was built — the one-click path for the ~1000+ existing installs to bring a basic/legacy project up to the full first-class cockpit experience. Built on `feat/projects` after the Fleet (M3) + cockpit-consolidation work. **Fleet is excluded from upgrade** (per the design + user). Importing Hermes-only projects is **part 2, deferred** — its enumeration design lives in [[Hermes has no project concept — infer working dirs from checkpoints, sessions.cwd, cron, kanban]].

## Observations

- [shape] Upgrade is a **two-layer** flow, mirroring the New Project wizard: (1) a deterministic Swift **structure pass** that guarantees first-class structure, then (2) a **chat hand-off** where the agent *enriches* the project (real dashboard, slash, cron, a starter mini-app). One click runs both. #architecture

- [service] `ProjectUpgradeService` (scarf/scarf/Core/Services, Mac target — composes Mac-target writers) is the deterministic half: it **reuses existing idempotent writers** rather than reinventing — `ProjectStore.derive`/`save` (uuid + `.scarf/project.json` + registry index), `ProjectAgentContextService.refresh` (AGENTS.md managed block), `KanbanTenantResolver.resolveOrMint` (manifest `kanbanTenant`, gated on `hasKanban`), `ProjectScaffolder.makePlaceholderDashboard` (placeholder `dashboard.json`, only if none). Writes `.scarf/upgrade.json` provenance (`upgradeVersion` = `currentUpgradeVersion`) which drives the `needsUpgrade` guard + future re-upgrade on a version bump. Idempotent, BOUNDED (never clobbers a real dashboard or user AGENTS.md content), NON-FATAL (only the identity write aborts; the rest are best-effort/logged). #service

- [ordering-gotcha] **Mint the Kanban tenant BEFORE the identity derive/save, and reflect it into the record** (`record.board = board`). The first cut saved `project.json` first, then minted the tenant into `manifest.json` only — so `ScarfProject.board` stayed `nil` forever (the re-derive paths never fire once `project.json` exists), desyncing the canonical record from the manifest and feeding `nil`/`""` board into the **Fleet drift + apply** machinery. The tenant is name/slug-keyed (NOT uuid-keyed), so minting it before the stable id is safe; a bare `derive` then reads it, and an existing record gets `record.board` set explicitly (a full re-derive would reset `createdAt`/`hostBindings`). Caught by the fresh-eyes review. Regression test: `upgradeWritesBoardIntoRecord`. #gotcha

- [skills] Two bundled Hermes agent skills (in `scarf/scarf/Resources/BuiltinSkills.bundle/`, auto-installed because `SkillBootstrapService` ENUMERATES the bundle, semver-gated):
  - **`scarf-miniapp-author` (NEW)** — the net-new gap. M2 shipped the `scarf-miniapp://` runtime + `window.scarf` bridge but nothing taught the agent to *author* a mini-app. The skill documents the ACTUAL contract (verified against `MiniAppBridge.javaScriptSource`): `scarf.context` (frozen sync object) / `scarf.version` / `scarf.ui.*` / `scarf.store.*` / `scarf.query` / `scarf.kanban.read` / `scarf.file.read` / `scarf.prompt` / `scarf.onEvent`, each with its permission + the sensitive-set (`prompt`/`net`/`file:write`/`kanban:write` default OFF for `generated:true`; `store`/`query:*`/`file:read`/`events` default ON), the `.scarf/miniapps/<id>/` layout (`<id>` == dir name), and a runnable kanban-board example. Doc the API from the SHIM, not the design doc (the design proposed a wider surface than M2 shipped).
  - **`scarf-template-author` (extended → 1.3.0)** — added an "enrich an EXISTING project" mode (read first, replace the placeholder dashboard, add slash/cron, build a starter mini-app via the miniapp skill, BOUNDED). **SUPERSEDED at 2.0.0 (Phase 6, 2026-09-03):** the skill is now tool-first — registration, dashboard writes, slash commands and validation go through the `scarf-projects` MCP tools, and hand-editing `projects.json` survives only as an explicitly-labelled remote-host fallback. See [[The skill is tool-first and Scarf deletes skills that lie about it]]. #skills

- [ui] `AppCoordinator.upgradeProject(_:context:hasKanban:)` is the one entry point: runs the service + `SkillBootstrapService` off-main in a `Task.detached`, then sets `pendingProjectChat`/`pendingInitialPrompt` + `selectedSection = .chat` (the same hand-off slots New Project uses; ChatView drains them). The kickoff prompt uses the `SKILL: scarf-template-author` invocation convention in ENRICH mode. An in-flight guard (`upgradingProjectPaths`, keyed on path) prevents a double-tap from spawning two chat sessions (the review-caught MED). Surfaces: a cockpit **banner** gated on `viewModel.needsUpgrade` (loaded off-main) + a sidebar **context-menu** item. A failed structure pass leaves the banner up (provenance unstamped → `needsUpgrade` stays true) so the user can retry — richer error UI is a follow-up. #ui

- [tests] `ProjectUpgradeServiceTests` (9) — bare→full, idempotency, no-clobber of dashboard/AGENTS, stable-id preservation, capability gating, board-in-record regression, provenance version-bump — all via per-instance `TempHermesHome`. Full app-target bundle 223 green. The skills were verified accurate by a fresh-eyes reviewer cross-checking the documented API against the shim (the example runs end-to-end). #testing

## Relations
- relates_to [[Phase-1 Milestone 3: Fleet and Portfolio dimension — implementation decisions]]
- relates_to [[Phase-1 Milestone 2: Mini-apps — implementation decisions]]
- relates_to [[Hermes has no project concept — infer working dirs from checkpoints, sessions.cwd, cron, kanban]]
- relates_to [[ScarfCore tests inject a temp Hermes home via ServerContext.local(home:)]]
