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
  "subtitle": "+2.1% from last week"
}
```

- `value`: String or number
- `icon`: SF Symbol name (optional)
- `color`: red, orange, yellow, green, blue, purple, pink, teal, indigo, mint, brown, gray (optional)
- `subtitle`: Secondary text (optional)

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

- `status`: "done" (checkmark), "active" (filled circle), "pending" (empty circle)

## Agent Instructions

To have your Hermes agent generate a dashboard, include these instructions:

> Analyze the project and create a `.scarf/dashboard.json` file with relevant metrics,
> status indicators, and visualizations. Use the Scarf dashboard schema with sections
> containing stat, progress, text, table, chart, and list widgets. Register the project
> in `~/.hermes/scarf/projects.json` if not already registered.

The agent can update the dashboard file at any time — Scarf watches for changes and re-renders automatically.
