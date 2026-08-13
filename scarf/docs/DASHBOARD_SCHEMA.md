# Scarf Project Dashboard Schema

Scarf can render project dashboards from a JSON file. Place a `dashboard.json` file at `.scarf/dashboard.json` in your project root, and register the project in Scarf.

## Registration

Projects are registered in `~/.hermes/scarf/projects.json`:

```json
{
  "projects": [
    { "name": "my-project", "path": "/path/to/my-project" }
  ]
}
```

You can also add projects from the Scarf UI via the Projects section.

## Dashboard File

Create `.scarf/dashboard.json` in your project root:

```json
{
  "version": 1,
  "title": "My Project",
  "description": "Optional description",
  "updatedAt": "2026-03-31T14:00:00Z",
  "sections": [
    {
      "title": "Section Name",
      "columns": 3,
      "widgets": []
    }
  ]
}
```

## Widget Types

### stat — Key metric display

```json
{
  "type": "stat",
  "title": "Test Coverage",
  "value": "87.3%",
  "icon": "checkmark.shield",
  "color": "green",
  "subtitle": "+2.1% from last week",
  "sparkline": [78.1, 80.4, 82.0, 85.9, 87.3]
}
```

- `value`: String or number
- `icon`: SF Symbol name (optional)
- `color`: red, orange, yellow, green, blue, purple, pink, teal, indigo, mint, brown, gray (optional)
- `subtitle`: Secondary text (optional)
- `sparkline`: Array of numbers plotted as a tiny trend line under the value (optional). Needs **at least 2 values** to render — fewer are silently ignored.

### progress — Progress bar

```json
{
  "type": "progress",
  "title": "Sprint Progress",
  "value": 0.73,
  "label": "73% complete",
  "color": "blue"
}
```

- `value`: Number between 0.0 and 1.0
- `label`: Text below the bar (optional)
- `color`: Named color (optional)

### text — Rich text block

```json
{
  "type": "text",
  "title": "Release Notes",
  "content": "**v2.4.1** — Fixed auth timeout\n\n- Bug fix for session handling",
  "format": "markdown"
}
```

- `content`: Text content
- `format`: "markdown" or "plain" (default: plain)

### table — Data table

```json
{
  "type": "table",
  "title": "Recent Deploys",
  "columns": ["Date", "Env", "Status"],
  "rows": [
    ["Mar 30", "prod", "success"],
    ["Mar 29", "staging", "success"]
  ]
}
```

### chart — Line, bar, or pie chart

```json
{
  "type": "chart",
  "title": "Tests Over Time",
  "chartType": "line",
  "series": [
    {
      "name": "Passing",
      "color": "green",
      "data": [
        { "x": "Mon", "y": 142 },
        { "x": "Tue", "y": 145 }
      ]
    }
  ]
}
```

- `chartType`: "line", "bar", or "pie"
- `series[].color`: Named color (optional)
- For pie charts, each series becomes a slice

### list — Checklist

```json
{
  "type": "list",
  "title": "TODO Items",
  "icon": "checklist",
  "items": [
    { "text": "Write tests", "status": "done" },
    { "text": "Update docs", "status": "active" },
    { "text": "Deploy", "status": "pending" }
  ]
}
```

- `status` (optional): free-form string, matched leniently against a known vocabulary (case-insensitive; unrecognized values render as a plain trailing badge instead of an icon):
  - `success` (also `ok`, `up`, `green`, `passing`)
  - `warning` (also `warn`, `yellow`, `degraded`)
  - `danger` (also `down`, `error`, `failed`, `failure`, `red`, `critical`)
  - `info` (also `active`, `blue`)
  - `pending` (also `queued`, `waiting`, `scheduled`)
  - `done` (also `complete`, `completed`, `finished`)
  - `neutral` (also `muted`, `gray`)

### webview — Embedded web browser

```json
{
  "type": "webview",
  "title": "Project Dashboard",
  "url": "http://localhost:8000",
  "height": 500
}
```

- `url`: Any URL — local servers, file paths, or remote pages
- `height`: Height in points (optional, default: 400)

When a dashboard includes a webview widget, Scarf adds a tabbed interface: **Dashboard** shows all normal widgets, **Site** displays the web content full-canvas. The webview widget is automatically filtered out of the Dashboard tab's grid layout.

### markdown_file — Render a markdown file from disk

```json
{
  "type": "markdown_file",
  "title": "Weekly Report",
  "path": "reports/weekly.md"
}
```

- `path`: File path relative to the project root (the directory containing `.scarf/`). Must not contain `..` segments. Rendered through the same markdown pipeline as the `text` widget.
- File is re-read automatically whenever anything under `.scarf/` changes.

### log_tail — Tail the last N lines of a file

```json
{
  "type": "log_tail",
  "title": "Uptime Checks",
  "path": "reports/uptime.log",
  "lines": 20
}
```

- `path`: File path relative to the project root, no `..` segments
- `lines`: Number of trailing lines to show (optional, default 20, clamped to 1–200)
- ANSI escape codes are stripped before display
- In-place appends to an existing file don't trigger a refresh on their own — have the writing cron job also touch `dashboard.json` after each run

### cron_status — Hermes cron job status + output tail

```json
{
  "type": "cron_status",
  "title": "Nightly Build",
  "jobId": "nightly-build",
  "lines": 5
}
```

- `jobId` (required): Matches a `HermesCronJob.id`, visible in the Cron tab
- `lines`: Number of trailing output lines to show (optional, default 5, clamped to 1–40)
- Read-only — shows last-run / next-run / state and a short output tail; Run/Pause/Resume stay on the Cron tab
- Refreshes automatically on cron state changes or `.scarf/` file changes

### status_grid — Compact grid of status cells

```json
{
  "type": "status_grid",
  "title": "Services",
  "gridColumns": 6,
  "cells": [
    { "label": "api", "status": "success", "tooltip": "All checks passing" },
    { "label": "worker", "status": "warning" },
    { "label": "db", "status": "danger" }
  ]
}
```

- `cells`: Array of `{ label, status, tooltip }` — `status` and `tooltip` are optional
- `status` uses the same vocabulary as the `list` widget's `items[].status` (see above)
- `gridColumns`: Overrides the auto-fit column count (optional; auto-fit aims for ~6 per row, floor 1, cap 12 unless explicitly overridden up to 20). Distinct from the `table` widget's `columns` field.

### kanban_summary — Top Kanban tasks for the project

```json
{
  "type": "kanban_summary",
  "title": "Kanban",
  "value": 3
}
```

- `value`: Number of task rows to show (optional, default 3)
- Reads the project's Kanban tenant from `.scarf/manifest.json`; shows nothing (with "no tasks" copy) until the Kanban tab has been opened at least once for the project
- Shows running + blocked + todo tasks sorted by priority, plus a glance-stats footer; polls every 10 seconds while visible

### image — Local file or remote image

```json
{
  "type": "image",
  "title": "Architecture Diagram",
  "path": "docs/architecture.png",
  "height": 300
}
```

- `path`: Local file relative to the project root, no `..` segments — takes priority over `url` when both are set
- `url`: Remote image URL, used only when `path` is absent
- `height`: Max display height in points (optional)
- Local images refresh automatically via the `.scarf/` directory watch; remote images are loaded once per appearance

## Agent Instructions

To have your Hermes agent generate a dashboard, include these instructions:

> Analyze the project and create a `.scarf/dashboard.json` file with relevant metrics,
> status indicators, and visualizations. Use the Scarf dashboard schema with sections
> containing stat, progress, text, table, chart, list, webview, markdown_file, log_tail,
> cron_status, status_grid, kanban_summary, and image widgets. Register the project
> in `~/.hermes/scarf/projects.json` if not already registered.

The agent can update the dashboard file at any time — Scarf watches for changes and re-renders automatically.
