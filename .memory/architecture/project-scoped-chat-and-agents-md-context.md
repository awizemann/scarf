---
title: Project-Scoped Chat and AGENTS.md Context
type: note
permalink: scarf/architecture/project-scoped-chat-and-agents-md-context
tags: [projects, chat, acp, agents-md]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SessionAttributionService.swift, scarf/scarf/Core/Services/ProjectAgentContextService.swift, scarf/scarf/Features/Projects/Views/ProjectSessionsView.swift]
source_sha: 2e1a26f6834951023226883f24f70a495897d440
created: 2026-05-29
updated: 2026-09-27
reviewed: 2026-09-04
reviewed_by: audit:claude-code (background)
---

## Observations
- [feature] v2.3 adds per-project Sessions tab + 'New Chat' button that spawns `hermes acp` with cwd=project.path. ProjectSessionsView lives at Features/Projects/Views/ #projects
- [attribution-sidecar] Session-to-project attribution is persisted in a Scarf-owned sidecar at ~/.hermes/scarf/session_project_map.json. ACP wire protocol has NO project-metadata hook (extra params silently dropped); state.db has NO cwd column. Sidecar is Scarf's source of truth. Managed by SessionAttributionService (moved into ScarfCore: Packages/ScarfCore/Sources/ScarfCore/Services/SessionAttributionService.swift; model SessionProjectMap.swift) #attribution
- [context-mechanism] Hermes auto-reads a context file from the session's cwd at startup with priority order: .hermes.md → HERMES.md → AGENTS.md → CLAUDE.md → .cursorrules (first match wins, 20KB cap). Scarf writes a managed block into <project>/AGENTS.md before opening the session via ProjectAgentContextService.swift #mechanism
- [block-shape] Block delimited by `<!-- scarf-project:begin -->` and `<!-- scarf-project:end -->` markers; `ProjectAgentContextService.renderBlock(for: ScarfProject)` is now the renderer (apply/splice logic moved to ScarfCore `ProjectContextBlock`). It emits: project name, dir, dashboard path, template (if installed), config field NAMES, registered cron jobs (attributed via ScarfCore `ProjectCronAttribution`: the first-class `[proj:<id>]` tag, a template job `[tmpl:<id>] [proj:<id>] …` for THIS project only (R12), or a legacy untagged `[tmpl:<id>] …`), project slash commands (if any `<project>/.scarf/slash-commands/*.md` exist), Kanban tenant (if minted), uninstall manifest path (if lock present), PLUS a STATIC `### Scarf platform reference` section (dashboard widget vocab, project slash commands, Kanban tenant rule, per-project model preset, typed config schema, cron, skills, export). Anything outside markers is preserved #format
- [invariant] SECRET-SAFE: block surfaces field NAMES, never VALUES. Secret fields render as `field_name (secret — name only, value stored in Keychain)`. Keychain ref URI and plaintext value never appear. Auditable by `refreshListsFieldNamesNotValues` in ProjectAgentContextServiceTests #security
- [invariant] IDEMPOTENT: two refreshes with unchanged state produce byte-identical output. Write skipped entirely when no delta, avoiding file-watcher churn #correctness
- [invariant] BOUNDED: everything outside markers is preserved on every refresh. Template-author AGENTS.md content lives safely below the block #correctness
- [invariant] NON-FATAL: ChatViewModel.startACPSession calls refresh with `try?` + log. Failed write doesn't block chat from starting; worst case is session loses project awareness #resilience
- [ordering-rule] Refresh MUST be called BEFORE client.start() so the block lands before Hermes's session-boot context scan. Skipping this ordering = agent sees stale context from previous refresh, or nothing on fresh projects #pitfalls
- [gotcha] The refresh only reaches NEW sessions (and a resume whose session/load falls back to session/new). A resumed session with history reuses the system prompt Hermes stored at creation, rebuilt only on a model/provider/cwd mismatch (`_restore_or_build_system_prompt` / `_stored_prompt_matches_runtime`, agent/conversation_loop.py:681-730,815-838 @ v2026.9.24) — cron, slash-command and project-name changes apply to new chats. Mac ChatViewModel and iOS ChatController still refresh before resume; comments corrected in R10 (S11-F4) #pitfalls
- [fact] Project model presets are applied on BOTH platforms through ScarfCore `ProjectModelPresetApplier.apply` (off-main manifest read, then `session/set_model`), after session/new and session/load. iOS never applied them before R10 (S11-F3). The block's model-preset line no longer claims the preset "already applied" — it says Scarf applies it when the chat opens and a refusal leaves the config.yaml default #presets
- [template-contract] Catalog templates should include an AGENTS.md with operational instructions. Authors leave the scarf-project region alone — Scarf populates it. The block is refreshed on BOTH chat-start AND template install (commit 4415849; previously chat-start only). Everything below is template-owned and preserved #templates
- [known-caveat] If any PARENT directory of the project contains .hermes.md or HERMES.md, those SHADOW the project's AGENTS.md (higher in priority order). No fix in v2.3 — deferred pending input on handling authored .hermes.md files #caveats

## Relations
- relates_to [[project-templates-scarftemplate]]
- relates_to [[kanban-board-architecture-v2-7-5]]
- relates_to [[Model Presets Feature]]
