---
created: 2026-09-03
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/scarf/Features/Projects, scarf/Packages/ScarfCore/Sources/ScarfCore/Models
source_paths_inferred: false
---

# Projects & Dashboards — First-Class Project Object and Custom Visualizations

Projects are Scarf's organizing principle: each project is a working directory (local or remote), and Scarf displays dashboards, sessions, cron, memory, skills, and more scoped to that project.

## Project as First-Class Object

`ScarfProject` (ScarfCore/Models/) is the canonical record:
- `id: UUID` — stable identifier.
- `name: String` — user-facing name.
- `rootPath: String` — filesystem path (local or remote).
- `modelPresetId: UUID?` — optional pinned model override for chats in this project.
- `createdAt, updatedAt: Date` — timestamps.

Projects are registered in `~/.hermes/scarf/projects.json` (a Scarf-owned config file):
```json
[
  { "name": "my-app", "path": "/path/to/repo", "id": "uuid-1" },
  { "name": "another", "path": "user@host:/home/user/repo", "id": "uuid-2" }
]
```

## Project Cockpit (Multi-Tab Dashboard)

`ProjectCockpitView` (`Features/Projects/Views/ProjectCockpitView.swift:21`) is the unified project interface. Tabs:
- **Dashboard** — Custom widgets (stats, charts, tables, checklists, web views).
- **Sessions** — Project-scoped chat history.
- **Board** (Kanban, if Hermes v0.20+) — Project's task board.
- **Context** — Project config, git metadata, environment.
- **Cron** — Jobs registered to this project.
- **Memory** — Project's MEMORY.md and USER.md.
- **Skills** — Installed skills usable in this project.
- **Templates** — Install/manage project templates.
- **Mini-apps** — Sandboxed HTML/JS/CSS mini-applications.
- **Fleet** (if portfolio mode) — Config sync across servers.

## Custom Dashboards

A project's `.scarf/dashboard.json` defines a live-updating dashboard:
```json
{
  "version": 1,
  "title": "My Project",
  "sections": [
    {
      "title": "Overview",
      "columns": 3,
      "widgets": [
        { "type": "stat", "title": "Coverage", "value": "87%", "icon": "checkmark.shield", "color": "green" },
        { "type": "progress", "title": "Sprint", "value": 0.73, "label": "73% complete" },
        { "type": "chart", "title": "Activity", "data": [...] }
      ]
    }
  ]
}
```

Widget types: `stat`, `progress`, `text`, `table`, `chart`, `list`, `webview`, `markdown_file`, `log_tail`, `cron_status`, `status_grid`, `kanban_summary`, `image`. The dashboard auto-refreshes when the file changes.

## Mini-Apps (Sandboxed Web Content)

Mini-apps are HTML/CSS/JS rendered in a `WKWebView` with a versioned `window.scarf` bridge:
- Live in `<project>/.scarf/miniapps/<id>/`.
- Executed in a strict CSP sandbox with permission gating.
- Can call back into Scarf via `window.scarf.call(method, args)` for read/write operations (rate-limited, logged).
- Permissions are fingerprinted and shown to the user on first open.

[[section-audit-remediation-2026-09]] documents symlink-containment audits for mini-app asset serving.

## Fleet & Portfolio

When the same project (same `rootPath`) appears on multiple servers, Scarf groups them into a **portfolio**. The Fleet panel shows:
- **Config drift** — flags when one server's model pin or cron jobs differ from others.
- **Sync actions** — one-click push of model presets, board state, or cron to the entire fleet.

`FleetService` (ScarfCore/Services/) handles the multi-server aggregation and drift detection.

## Project-Scoped Chat

When starting a new chat in a project:
- Scarf spawns `hermes acp` with `cwd=project.rootPath`.
- Hermes loads AGENTS.md, CLAUDE.md, .cursorrules from the project directory.
- Chat context is automatically project-aware.

On macOS, this is implemented. On iOS (ScarfGo), the process-cwd gap exists — project chat doesn't load context. [[scarfgo-ios-does-not-load-project-context]]

## Testing Projects

`ProjectCockpitViewModel` (`Features/Projects/ViewModels/ProjectCockpitViewModel.swift:19`) handles:
- Loading the selected project's metadata.
- Observing dashboard file changes.
- Dispatching user actions (rename, delete, update model preset).
- Coordinating tab state.

Tests inject a mock `FleetService` and `ProjectStore`.