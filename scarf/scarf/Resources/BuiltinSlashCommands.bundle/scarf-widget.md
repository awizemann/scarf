---
name: scarf-widget
description: Add a single widget to the active project's dashboard
argumentHint: <widget type, e.g. "log_tail" or "status_grid">
version: 1.1.0
---

The user wants to add ONE widget to the active project's `dashboard.json`. Don't redesign the whole dashboard — that's `/scarf-dashboard`. This is a focused, narrow add.

Read the active project from this chat's `<!-- scarf-project -->` AGENTS.md block. If no project is active, ask the user which project to update.

Requested widget type (if given): {{argument | default: "(ask the user)"}}

Available widget types — the widget's `type` field (from `~/.hermes/skills/scarf/scarf-template-author/SKILL.md` § Widget Catalog):

- **stat** — one big number with an optional label/trend
- **progress** — a progress bar (`value`)
- **text** — static text or Markdown (`content`)
- **table** — rows and columns (`columns`, `rows`)
- **chart** — line/bar chart (`series`)
- **list** — a list of items (`items`)
- **webview** — an embedded web page (`url`)
- **markdown_file** — renders a Markdown file from the project (`path`)
- **log_tail** — the last lines of a log file in the project (`path`)
- **cron_status** — a Hermes cron job's schedule and last run (`jobId`)
- **image** — an image from the project or a URL (`path` or `url`)
- **status_grid** — a grid of status cells (`cells`)
- **kanban_summary** — top tasks for the project's Kanban tenant

Workflow:

1. Identify the widget type. If the user named one, use it; otherwise ask, listing the options above with one-line examples.
2. Ask for the required fields for that type (in parentheses above; e.g. for `log_tail`: the log file's `path` inside the project). No other `type` values exist — Scarf refuses a widget whose `type` is not in this list.
3. Read the current `dashboard.json`, append the new widget to the appropriate section (or create a new section if needed), and write it back: if the `scarf-projects` MCP tools are available, prefer `project_update_dashboard` (`project`, `dashboard`) — it validates against Scarf's real dashboard schema and widget catalog before anything is written, so a bad shape is refused instead of landing on disk. Only if those tools are NOT available, fall back to writing `dashboard.json` directly.
4. Tell the user the change is live — Scarf's file watcher re-renders the Projects tab automatically.

Don't reformat the rest of the file. Preserve existing widget ordering and section structure unless the user explicitly asks otherwise.
