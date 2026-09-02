---
title: Kanban Board Architecture (v2.7.5)
type: note
permalink: scarf/features/kanban-board-architecture-v2.7.5
tags: [kanban, drag-drop, tenants]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/KanbanError.swift, scarf/scarf/Core/Services/KanbanTenantResolver.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanTenantReader.swift, scarf/scarf/Features/Kanban/ViewModels/KanbanBoardViewModel.swift, scarf/scarf/Features/Kanban/Views/KanbanBoardView.swift]
source_sha: 466bb7f11b7652ac99876183d0968269cddcac38
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

## Observations
- [sidebar] Kanban moved from Manage → Monitor in SidebarView (between .activity and remaining Monitor entries) — it's runtime WIP, not configuration #navigation
- [hermes-constraint] Hermes has NO `update` verb — priority/title/body/tenant are write-once on `kanban create`. Mutations are state transitions (assign/claim/complete/block/unblock/archive) or new comments. Inline card-title editing is impossible at the wire level #constraints
- [hermes-constraint] Hermes Kanban is ONE global SQLite DB at ~/.hermes/kanban.db with no project_id column. Closest namespace is optional `tenant TEXT`. Scarf hijacks it: each project gets a `scarf:<slug>` tenant minted on first kanban interaction #constraints #tenants
- [hermes-constraint] No within-column position field — drag-to-reorder inside a column has no persistence path and is DISABLED. Sort key is `priority DESC, created_at DESC` (matches dispatcher run order). Cross-column drag is the only persisted gesture #constraints
- [hermes-constraint] No file-watch/webhooks — polling at 5s while foregrounded. Live `watch` streaming deferred; future hasKanbanWatch flag will gate #constraints
- [columns] Hermes status enum has 7 values; board collapses to 5 columns: Triage / Up Next (todo+ready) / Running / Blocked / Done. Triage hides when empty. v0.15 adds Scheduled + Review columns (collapsed when empty) #columns
- [service] KanbanService is a Sendable actor in ScarfCore — pure I/O, no UI state. Wraps every v0.12 verb. Each method dispatches via Task.detached(priority:.utility). Errors land in KanbanError → inline banners (not modal alerts). 'no matching tasks' stdout → [] #service
- [transitions] KanbanService.plan(for: KanbanTransition) is a pure function mapping (from, to) → verb sequence. e.g. (.upNext,.running)→[.claim], (.blocked,.running)→[.unblock,.claim]. Forbidden transitions throw KanbanError.forbiddenTransition with user-facing reasons (Done is terminal; Triage is specifier-promoted only) #transitions
- [tenant] KanbanTenantResolver (Mac) mints `scarf:<slug>` on first kanban interaction, persisting to <project>/.scarf/manifest.json's optional kanbanTenant: String?. Tenants are IMMUTABLE across rename. Bare projects get a sentinel manifest (id: scarf/<project-id>, version: 0.0.0); ProjectAgentContextService refuses to surface sentinels as a Template line. Cross-platform reader: KanbanTenantReader in ScarfCore #tenants
- [agent-injection] ProjectAgentContextService.renderBlock adds 'Kanban tenant' line to AGENTS.md scarf-managed block when tenant exists. ChatViewModel.startACPSession calls refresh(for:) before opening every project chat — agent learns to pass --tenant scarf:<slug> on every create. Misuse falls through to global Untagged group, acceptable v2.7.5 behavior #agents
- [view-model] KanbanBoardViewModel (@MainActor + @Observable) holds column-grouped tasks. Optimistic-merge for drag-drops: in-flight move records optimisticOverrides[taskId]=newStatus, mutates local array immediately, clears only when poll confirms. Without this, a stale poll can clobber a card the user just dragged #concurrency
- [inspector] KanbanInspectorPane is a 420pt SIDE-PANE, not modal — so the user can keep dragging cards after inspecting one #ux
- [v015-additions] v0.15 adds: server-side --sort (priority/created/status/assignee/title/updated), promote/schedule/purge/swarm verbs, global --board <slug> plumbing, branchName/workflowTemplateId/currentStepKey/modelOverride task fields (model_override is show-only), worktree:<path> workspace variant, session-scoped board via ACP session_id (replaces tenant + time-window approximation) #v0.15
- [gating] Single flag HermesCapabilities.hasKanban (>= 0.12.0) gates all 27 v0.12 verbs together. hasKanbanV015 gates the v0.15 maturation wave. hasKanbanSessionFilter gates the chat-scoped board. Global Kanban sidebar + per-project Kanban tab stay on hasKanban (tenant-scoped) — only chat-scoped surface requires v0.15 #gating
- [iOS] Read-only board on iOS — ScarfGoKanbanView renders the 5 columns as a horizontally-paged Picker of single-column lists (HIG-friendly on iPhone). No mutations, no drag-drop in v2.7.5. Card titles use semantic .headline (not ScarfFont) so Dynamic Type works; chrome uses ScarfBadge for fixed visual weight #ios
- [anti-patterns] Don't add within-column reorder via client-side ordering sidecar — diverges from dispatcher run order. Don't try to mutate priority/title/body post-create (no verb). Don't drop cards from .done into anything (Done is terminal). Don't call transport.runProcess directly from view bodies — route through KanbanService so polling + writes share concurrency model #pitfalls

## Relations
- uses_capability [[Hermes Capability Gating Pattern]]
- relates_to [[Project-Scoped Chat and AGENTS.md Context]]
