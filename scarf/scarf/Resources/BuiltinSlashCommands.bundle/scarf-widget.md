---
name: scarf-widget
description: Add a single widget to the active project's dashboard
argumentHint: <widget kind, e.g. "sqlite_query" or "command_output">
version: 1.0.0
---

The user wants to add ONE widget to the active project's `dashboard.json`. Don't redesign the whole dashboard — that's `/scarf-dashboard`. This is a focused, narrow add.

Read the active project from this chat's `<!-- scarf-project -->` AGENTS.md block. If no project is active, ask the user which project to update.

Requested widget kind (if given): {{argument | default: "(ask the user)"}}

Available widget kinds (from `~/.hermes/skills/scarf/scarf-template-author/SKILL.md` § Widget Catalog):

- **text** — static label or header
- **markdown** — rendered Markdown from inline content or a file path
- **file_glob** — list of files matching a glob, with optional preview
- **command_output** — runs a shell command, renders stdout (auto-refresh on watched paths)
- **sqlite_query** — runs a SQL query against a SQLite database, renders as a table
- **recent_messages** — recent Hermes session messages, filterable by session or tenant
- **kanban_summary** — top-N tasks for the project's Kanban tenant
- **chart** — line/bar chart from a data source

Workflow:

1. Identify the widget kind. If the user named one, use it; otherwise ask, listing the options above with one-line examples.
2. Ask for the required parameters for that kind (e.g. for `sqlite_query`: db path, query, columns to render).
3. Read the current `dashboard.json`, append the new widget to the appropriate section (or create a new section if needed), and write it back: if the `scarf-projects` MCP tools are available, prefer `project_update_dashboard` (`project`, `dashboard`) — it validates against Scarf's real dashboard schema and widget catalog before anything is written, so a bad shape is refused instead of landing on disk. Only if those tools are NOT available, fall back to writing `dashboard.json` directly.
4. Tell the user the change is live — Scarf's file watcher re-renders the Projects tab automatically.

Don't reformat the rest of the file. Preserve existing widget ordering and section structure unless the user explicitly asks otherwise.
