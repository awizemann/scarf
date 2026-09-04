---
name: scarf-dashboard
description: Design or edit the active project's dashboard.json (widgets, layout, refresh)
argumentHint: <what to change, e.g. "add a recent-bugs widget">
version: 1.0.0
---

The user wants to design or edit a Scarf project's `dashboard.json`. The active project (if any) is identified by the path in this chat's `<!-- scarf-project -->` AGENTS.md block — read it first.

If no project is currently active (this is a global chat), ask the user which project to work on. List the registered project paths from `~/.hermes/scarf/projects.json` if needed.

User's request: {{argument | default: "(no specific change — ask the user what they want to do)"}}

Workflow:

1. Read the current `<project>/.scarf/dashboard.json`.
2. Understand the user's intent (add a widget? rearrange? change a query? add a section?).
3. Reference the widget vocabulary documented in `~/.hermes/skills/scarf/scarf-template-author/SKILL.md` § Widget Catalog. Supported widget `kind` values include: `text`, `markdown`, `file_glob`, `command_output`, `sqlite_query`, `recent_messages`, `kanban_summary`, `chart`. Each has a typed schema.
4. Propose the change as a JSON diff or a complete updated file. Confirm with the user before writing.
5. Write the updated dashboard: if the `scarf-projects` MCP tools are available, prefer `project_update_dashboard` (`project`, `dashboard`) — it validates against Scarf's real dashboard schema and widget catalog before anything is written, so a bad shape is refused instead of landing on disk. Only if those tools are NOT available, fall back to writing `dashboard.json` directly. Scarf's file watcher will pick up the change automatically and re-render the Projects tab.

Don't break existing widgets the user didn't ask you to change. If the dashboard.json file is malformed, fix only what's needed for your change to land and tell the user about the broader issues.
