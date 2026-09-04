---
title: Agents break projects because there is no structured write path — 2026-09 live evidence
type: note
permalink: scarf/operations/agents-break-projects-because-there-is-no-structured-write
tags: [projects, stability, skills, registry, investigation]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift, scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md]
source_paths_inferred: false
source_sha: 009fb67fd0ec860cb5f61ec1d8e6060477025c90
created: 2026-09-03
updated: 2026-09-03
---

## Observations
- [fact] Live ~/.hermes (2026-09-03): registry entry shabubox-seo-tracker carries a non-UUID uuid string an agent invented while hand-appending to projects.json per scarf-template-author SKILL.md step 8; the project also lacks .scarf/project.json and upgrade.json #registry
- [gotcha] A hallucinated skill ~/.hermes/skills/scarf/scarf-project-workflows/ (2026-06-08, predates the real bundled skills) documents fake CLIs (scarf install/deploy, hermes scarf-project-auditing) and a wrong dashboard schema, and competes with the real skills for activation — a major driver of agent-broken projects #skills
- [gotcha] Malformed projects.json makes ProjectDashboardService.loadRegistry return an EMPTY registry (log-only), emptying every project surface at once, and a subsequent UI save persists the empty list over the file — no quarantine, backup, or user-visible error #fragility
- [fact] No project CRUD is exposed to agents: all mutators (add/scaffold/install/rename/archive/upgrade) are Swift services behind the UI; agents mutate projects only via raw file writes guided by skill prose #architecture
- [idea] 2026-09-03 investigation recommends: Layer A defensive self-healing (quarantine + per-entry salvage decode + atomic writes + reconciliation Doctor), then Layer B a Scarf-shipped scarf-projects MCP server wrapping ProjectStore/ProjectDashboardService as validated tools; full report in documents/reports/2026-09-03-projects-stability-investigation.md #roadmap

## Relations
- relates_to [[Phase-1 Milestone 1: First-Class Project Object — implementation decisions]]
- relates_to [[Hermes has no project concept — infer working dirs from checkpoints, sessions.cwd, cron, kanban]]
- relates_to [[Project Upgrade — one-click structure pass + chat enrichment (deterministic ProjectUpgradeService + skills)]]


## Outcome (2026-09-03, same day)

- [done] The full plan landed on feat/projects-first-class in 9 commits (0d4741e..04ac924): registry salvage/quarantine/chokepoint refusal, error surfacing, deterministic (host,path) identity, Project Doctor, bundled scarf-projects MCP server (auto-registered locally), tool-first skill 2.0.0 + bad-skill denylist, plus two remediation batches from a fresh-eyes branch audit. ScarfCore 1984 + scarfTests 659 green. #projects
- [fact] The P7 full-surface audit (documents/reports/2026-09-03-projects-full-surface-audit.md) found the remaining exposure is mostly OLD surface: adjacent registries (grants/session map) destroy-on-read-failure, trust anchored in agent-writable files (template.lock.json, keychain refs), iOS Citadel writeFile NOT atomic (truncates in place), and ~55-70 SSH round-trips per watcher tick. Remediation tasks: S1 t-f227bb0f, D1 t-3b855719, D3 t-a6f22379 (urgent); S2/D2 t-a2c169f0, PF t-45594d27 (high); AX t-44d4ad5b (medium). #roadmap
