---
title: Projects-Amazing — Phase 1 Program (index)
type: note
permalink: scarf-wiki/roadmap/projects-amazing-phase-1-program-index
tags:
- roadmap
- projects
- phase-1
- mini-apps
- index
created: 2026-06-14
updated: 2026-06-14
---

Wiki index for the Phase-1 "make projects amazing" program — positioning Scarf as the native control plane for an agent fleet **by project** (project-lead management + Cowork-style mini-apps), on top of Hermes. Authored 2026-06-14, after the Hermes v0.16 compatibility pass.

## Where the documents live
- **Design tier** (`design/projects-amazing/`, project `scarf-design`):
  - *First-Class Project Model (Phase 1)* — `design/projects-amazing/first-class-project-model-phase-1.md`
  - *Mini-App Bridge Contract (Phase 1)* — `design/projects-amazing/mini-app-bridge-contract-phase-1.md`
- **Memory tier** (`.memory/`, project `scarf`): *Hermes v0.16 Compatibility Decisions* (`.memory/decisions/`) — the foundation this builds on.
- **Task board**: `TASKS.md` items `t-proj-model`, `t-miniapp-bridge`, `t-gw-spike`, `t-v016-extras`, `t-acp-toolsets-up`.

## Decisions locked (2026-06-14)
1. **Project store** → repo-resident `.scarf/project.json` (canonical, portable) + per-server `~/.hermes/scarf/projects.json` fleet index.
2. **Tool/skill scoping** → DEFERRED. ACP `_make_agent` hardcodes `enabled_toolsets`; filed upstream NousResearch/hermes-agent#45955 (issue) + #45958 (PR). Buildable once merged.
3. **Kanban** → board-per-project via Hermes v0.16 multi-board.
4. **Mini-apps** → read-only v1 (kanban writes behind a later permission).

## Build order
First-class Project object → HTML/JS mini-apps (webview + `window.scarf` bridge) → orchestration cockpit (+ gateway-WS spike) → config-as-policy.

## Status
Designed + decided. Implementation lives on the project branch (`feat/projects`); not yet started.
