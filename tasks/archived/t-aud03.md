---
id: t-aud03
title: **[t-aud03]** Kanban tab synchronous I/O on main — FIXED. `ProjectKanbanTab.resolveTenant()` called `KanbanTenantResolver.resolveOrMint(for:)` (synchronous FileManager walk across all projects) inline on the MainActor from `.task`/Retry. Now dispatches via `Task { try await Task.detached { resolver.resolveOrMint(...) }.value }` — `resolver`/`project` are Sendable, @State writes stay on main, and the view's existing ProgressView branch covers the wait. Verified: app BUILD SUCCEEDED, no new warnings.
status: archived
---

## Description



## Plan



## Artifacts



