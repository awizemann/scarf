---
name: scarf-template-author
description: Scaffold a new Scarf project — dashboard, optional configuration schema, optional cron job, and AGENTS.md — from a short conversational interview with the user. Output is immediately usable locally and cleanly exportable as a .scarftemplate bundle.
version: 1.0.0
author: Alan Wizemann
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [Scarf, templates, scaffolding, dashboard, authoring]
    homepage: https://github.com/awizemann/scarf/wiki/Project-Templates
prerequisites:
  commands: [hermes]
---

# Scarf Template Author

Scaffold a new Scarf-compatible project from a conversational interview. The output is both (a) a working project on disk the user can register with Scarf and use immediately, and (b) correctly shaped to be exported as a `.scarftemplate` bundle via Scarf's Export flow later.

## When to invoke this skill

Activate when the user says things like:

- *"Create a new Scarf project that watches / tracks / reports on …"*
- *"Scaffold a dashboard for …"*
- *"Set up a project that runs a daily check on …"*
- *"Help me author a Scarf template."*
- *"Build me a Scarf project to monitor …"*

Do **not** activate for pure reference questions like *"what widget types does Scarf support?"* or *"how does Scarf handle secrets?"* — answer those inline from the reference sections below.

Also do not activate when the user explicitly wants to edit an existing project's dashboard — that's a plain file edit, not a scaffold.

## How a Scarf project is shaped on disk

A Scarf project is just a directory registered in `~/.hermes/scarf/projects.json`. For Scarf to render a useful dashboard and for the project to be exportable as a `.scarftemplate`, it needs these files at minimum:

```
<project>/
├── .scarf/
│   ├── dashboard.json       # REQUIRED for dashboard rendering
│   └── manifest.json        # OPTIONAL — required only if the project declares a config schema or you want to export cleanly
├── AGENTS.md                # Cross-agent instructions (agents.md standard) — ship this for every project
└── README.md                # User-facing explanation
```

If the project will have a scheduled job, ALSO register a cron entry via `hermes cron create`. For an exportable bundle, also author `cron/jobs.json` in the staging directory — that's where Scarf's exporter will pick jobs up from.

Secrets never land in `dashboard.json` or `config.json`. At install time, Scarf routes secret-type config values to the macOS Keychain; `config.json` stores `keychain://service/account` URIs. When scaffolding from scratch (no install), the user either manages secrets via the post-install Configuration editor after export, or stashes them in their `~/.hermes/config.yaml` if they're Hermes-level secrets rather than project-level.

## The interview

Ask these questions in order. Don't batch. Each answer shapes the next question.

### 1. Purpose and data source

- *"In one sentence — what does this project do?"*
- *"Where does its data come from? Files, a URL, a shell command's output, an API call, a database, a spreadsheet?"*

Goal: figure out whether the project is **passive** (user maintains some files, dashboard reflects them), **pull-based** (we fetch from an HTTP endpoint or CLI tool on a schedule), or **push-based** (something external writes to a file we watch).

### 2. Refresh cadence

- *"How often should it refresh? Every hour? Daily? Weekly? Only when I ask?"*

If "only when I ask" → no cron job; user invokes the agent manually. If any scheduled cadence → cron job.

Map to cron expressions:
- Every hour: `0 * * * *`
- Daily at 9 AM: `0 9 * * *`
- Weekly Monday 9 AM: `0 9 * * 1`
- Every 15 minutes: `*/15 * * * *`

### 3. What the dashboard shows

Explain the seven widget types (see Widget Catalog below) in plain English, then ask which ones feel right. Offer concrete suggestions based on the purpose:

- Counting things (open PRs, failing tests, up/down sites) → `stat` widgets.
- A list of items with status → `list` with `text` + `status` per item.
- Time-series data → `chart` with `line` or `bar` type.
- Rows × columns of heterogeneous data → `table`.
- A live URL (useful for monitoring a site) → `webview`. **Including a webview widget exposes a Site tab** next to the Dashboard tab — worth noting to the user.
- A progress bar for something with a clear 0-to-N scale → `progress`.
- Static help / markdown → `text` with `format: "markdown"`.

### 4. Configuration needs

- *"Does this project need anything configurable by the user — URLs to watch, API tokens, thresholds, a list of accounts?"*

If yes → design a config schema. Fields map to seven types (see Config Schema Design below). Remember: **secret fields never have defaults**; that's a hard validator rule.

If no → skip `.scarf/manifest.json`; the project works but won't have a Configuration form.

### 5. Target agents

- *"Which agents will operate this project? Just Claude Code? Also Cursor / Codex / Aider / other?"*

For v1 just write `AGENTS.md` — every modern agent reads it, and if you need a specific shim (CLAUDE.md, GEMINI.md, .cursorrules), add it as a symlink to AGENTS.md so content stays in sync.

## Widget Catalog (JSON shapes)

All widgets require `type` and `title`. Type-specific fields:

### `stat` — single metric
```json
{ "type": "stat", "title": "Sites Up", "value": 0,
  "icon": "checkmark.circle.fill", "color": "green", "subtitle": "responded 2xx/3xx" }
```
`value` accepts number OR string (`WidgetValue` enum). `icon` is an SF Symbol name. `color` is one of: `green`, `red`, `blue`, `orange`, `yellow`, `purple`, `gray`.

### `progress` — 0.0 to 1.0 progress bar
```json
{ "type": "progress", "title": "Test Coverage", "value": 0.72, "label": "72% of statements" }
```

### `text` — markdown or plain text block
```json
{ "type": "text", "title": "Quick Start", "format": "markdown",
  "content": "**1.** Click + in the Projects sidebar.\n\n**2.** ..." }
```
`format` is `"markdown"` or `"plain"`.

### `table` — columns × rows of strings
```json
{ "type": "table", "title": "Failing Tests",
  "columns": ["Test", "Duration", "Last Passed"],
  "rows": [["testFoo", "4.2s", "Apr 20"], ["testBar", "0.9s", "Apr 18"]] }
```
Every row MUST have the same length as `columns`.

### `chart` — line / bar / area / pie with series
```json
{ "type": "chart", "title": "Requests / day", "chartType": "line",
  "xLabel": "Date", "yLabel": "Count",
  "series": [{
    "name": "staging",
    "color": "blue",
    "data": [{"x": "Apr 20", "y": 142}, {"x": "Apr 21", "y": 189}]
  }]
}
```
`chartType` is `"line"`, `"bar"`, `"area"`, or `"pie"`.

### `list` — items with optional status badge
```json
{ "type": "list", "title": "Watched Sites",
  "items": [
    { "text": "https://example.com", "status": "up" },
    { "text": "https://example.org", "status": "down" }
  ]
}
```
`status` values: `"up"`, `"down"`, `"pending"`, `"ok"`, `"warn"`, `"error"` — render as coloured badges.

### `webview` — embedded live URL
```json
{ "type": "webview", "title": "First Watched Site",
  "url": "https://awizemann.github.io/scarf/", "height": 420 }
```
**Important:** including any `webview` widget in a dashboard exposes a **Site** tab next to the Dashboard tab in the project view. Useful for templates that watch something renderable. The agent can update `url` on cron runs to keep the Site tab in sync with config (e.g., set it to `values.sites[0]`).

## Config Schema Design

If the project needs user-configurable values, design a schema. Put it in `<project>/.scarf/manifest.json` with this shape:

```json
{
  "schemaVersion": 2,
  "id": "author/project",
  "name": "My Project",
  "version": "1.0.0",
  "description": "Short one-liner.",
  "contents": { "dashboard": true, "agentsMd": true, "config": 2 },
  "config": {
    "schema": [
      { "key": "sites", "type": "list", "itemType": "string", "label": "Sites",
        "required": true, "minItems": 1, "maxItems": 25,
        "default": ["https://example.com"] },
      { "key": "api_token", "type": "secret", "label": "API Token", "required": true }
    ],
    "modelRecommendation": {
      "preferred": "claude-haiku-4",
      "rationale": "Short-running, tool-light workload — haiku is plenty."
    }
  }
}
```

Note: `contents.config` is the **count of schema fields**, not a boolean. In the example above it's `2` because there are two fields.

### Field types and constraints

| Type | Rendered as | Constraint keys |
|---|---|---|
| `string` | Text field | `pattern` (regex), `minLength`, `maxLength` |
| `text` | Multi-line editor | `minLength`, `maxLength` |
| `number` | Number field | `min`, `max` |
| `bool` | Toggle | — |
| `enum` | Segmented (≤4) / Dropdown (>4) | `options: [{value, label}]` (REQUIRED) |
| `list` | Repeatable rows | `itemType: "string"` (required), `minItems`, `maxItems` |
| `secret` | Password field, routes to Keychain | — |

Every field takes `key` (required), `label` (required), `description` (optional — markdown), `required` (bool), `default` (optional; type matches the field type).

### Writing good descriptions

Descriptions render inline with markdown support (bold, italic, code, links). Keep them short — a single line or two is ideal.

**Always use markdown link syntax for URLs**, never bare `https://…` — the Configuration sheet's inline text renderer doesn't word-break mid-URL, so a raw URL in a description will force that whole description's width to the URL's character length. Older Scarf versions clipped the sheet in that case; current versions wrap correctly, but the visible text is still cleaner with named links.

```json
// ✓ Good — short label, URL in the href
"description": "Token with `repo` scope. Get one [from the GitHub tokens page](https://github.com/settings/tokens)."

// ✗ Bad — raw URL bloats the visible text
"description": "Token with `repo` scope. Get one at https://github.com/settings/tokens"
```

Same rule for long file paths, API endpoints, or any other unbreakable token — wrap them in inline code (backticks) if they have to appear verbatim, and prefer markdown links otherwise.

### Hard rules

- **Secret fields MUST NOT have a `default`.** The validator rejects the manifest if they do — a default makes no sense because the Keychain entry doesn't exist yet at install time.
- **Enum fields MUST have non-empty `options`.**
- **List fields MUST have `itemType: "string"`** in v1 (only itemType supported).
- **Field keys MUST be unique** within a schema.
- **`schemaVersion` MUST be 2** when a `config` block is present; it stays 1 if there's no config.
- **`contents.config`** must equal the actual count of schema fields — a claim mismatch is rejected.

## Cron Job Design

If the project has a scheduled task, register a cron job via `hermes cron create` AND — if you expect the user to export this as a `.scarftemplate` — author a `cron/jobs.json` in the staging layout so the exporter picks it up.

### Staging shape (for exportable templates)

```
<project>/
├── .scarf/
├── AGENTS.md
├── README.md
└── cron/
    └── jobs.json
```

Where `cron/jobs.json` is:

```json
[
  {
    "name": "Check site status",
    "schedule": "0 9 * * *",
    "prompt": "Read {{PROJECT_DIR}}/.scarf/config.json — get values.sites and values.timeout_seconds — then HTTP GET each URL with that timeout, write the results to {{PROJECT_DIR}}/status-log.md, and update {{PROJECT_DIR}}/.scarf/dashboard.json's stat widgets by title (Sites Up, Sites Down, Last Checked). Reply with a one-line summary."
  }
]
```

### Gotchas

- **Hermes does not set a CWD when firing cron jobs.** Relative paths in the prompt resolve against wherever the Hermes process happens to be running, not the project. Always use `{{PROJECT_DIR}}` in the prompt — the installer substitutes the absolute path at install time. This is THE most common template-author mistake.
- **Cron jobs created by the installer start paused.** Their name is auto-prefixed with `[tmpl:<template-id>]`. The user enables them from Scarf's Cron sidebar when ready.
- **Registering a cron job for a user's local (non-exported) project:** run `hermes cron create --name "<descriptive name>" "<schedule>" "<prompt>"` directly, substituting the absolute `<project>` path for `{{PROJECT_DIR}}` yourself. Then `hermes cron pause <id>` so it doesn't run until the user opts in.

### Schedule quick reference

| Cadence | Expression |
|---|---|
| Every 15 minutes | `*/15 * * * *` |
| Hourly at :00 | `0 * * * *` |
| Daily at 9 AM | `0 9 * * *` |
| Weekly Monday 9 AM | `0 9 * * 1` |
| First of the month, 9 AM | `0 9 1 * *` |

## Writing the files

After the interview, write files in this order.

### Step 1 — confirm parent directory

Ask: *"Where should I create the project? Give me an absolute path — I'll make a `<project-name>` directory inside it."*

Make sure the parent exists and is writable. Make sure `<parent>/<project-name>` does NOT already exist. If it does, ask whether to pick a different name or bail.

### Step 2 — create the skeleton

```bash
mkdir -p <parent>/<project-name>/.scarf
```

### Step 3 — write `dashboard.json`

Use the Widget Catalog above. Always include:

- `version: 1`
- `title` (the project's display name)
- `description` (a one-liner shown under the title)
- `sections` (array; each has `title`, optional `columns` (1–4, default 3), `widgets`)

Keep section titles short. Group related widgets. First section is usually "Current Status" or similar with the key stats.

### Step 4 — write `manifest.json` (only if the project has a config schema)

Put the full manifest shape from Config Schema Design above. Use `schemaVersion: 2`, match `contents.config` to the actual field count, and ensure every secret field has no `default`.

If there's no config schema, skip this file — the project still works, it just won't have a Configuration button. You can add it later.

### Step 5 — write `AGENTS.md`

Every scaffolded project needs an `AGENTS.md` that covers:

- **Purpose** — what the project does.
- **Layout** — which files exist and what they're for.
- **Configuration** — if there's a config schema, document every field: what it's for, what valid values look like, what happens when it's missing.
- **Dashboard** — list every widget the cron job (if any) updates, by title. If the cron updates a webview widget's URL, document that explicitly.
- **Cron behaviour** — what the cron job does, what it reads, what it writes, what its exit criteria are.
- **Chat prompts** — common user questions and how to answer them (e.g., *"What's the status of my sites?"* → "read the top section of `status-log.md` and summarise").
- **What NOT to do** — e.g., *don't modify `.scarf/config.json` yourself; tell the user to open the Configuration button.*

Use `{{PROJECT_DIR}}` placeholders in AGENTS.md only if the template will be installed through the installer (which substitutes the token). For a hand-scaffolded local-only project, substitute the absolute path yourself — `{{PROJECT_DIR}}` only resolves at install time.

### Step 6 — write `README.md`

User-facing. Keep it short:

- One-paragraph purpose.
- How to install / first run (for an unexported project: "click + in Scarf's Projects sidebar").
- How to trigger the cron job manually (Cron sidebar → Run Now).
- A pointer at `AGENTS.md` for agents.

### Step 7 — register the cron job (if any)

For a local non-exported project:

```bash
hermes cron create --name "<descriptive name>" "<schedule>" "<prompt with absolute project dir substituted>"
# Then pause it so it doesn't fire until the user's ready:
hermes cron pause <newly-created-job-id>
```

Read the id back from `hermes cron list --json` or parse the create output.

For an exportable template (one you're staging in `templates/<author>/<name>/staging/`): just author `cron/jobs.json` — the installer registers + pauses at install time, and prefixes the name with `[tmpl:<id>]`.

### Step 8 — register the project with Scarf

Tell the user: *"I've written the files. Click the **+** button in Scarf's Projects sidebar and pick `<absolute-project-dir>`. The dashboard will appear."*

Do NOT edit `~/.hermes/scarf/projects.json` directly — Scarf owns that file and reloads it on its own. The UI path is safer.

### Step 9 (optional) — log to the Template Author project's list

If the user has the `awizemann/template-author` project installed (the one that shipped this skill), append an entry to its `dashboard.json`'s `Scaffolded Projects` list widget:

```json
{ "text": "<absolute-project-dir> — <one-line purpose>", "status": "ok" }
```

This gives the user a running audit trail of everything you've scaffolded for them. Preserve every other field in the dashboard as-is.

## Testing your scaffold

### Minimum smoke test

1. Tell the user to click **+** in Scarf's Projects sidebar and pick the directory.
2. Dashboard appears — sanity check every widget renders correctly.
3. If there's a cron job: click the job in Scarf's Cron sidebar → **Run Now**. The agent executes the prompt; dashboard updates when it finishes.

### Configuration-form test (only if schema was declared)

To verify the Configuration form renders, you need to *install* the project as a template — scaffolded projects don't go through the installer, so the form never runs. Export the project first:

1. Projects → Templates → **Export "&lt;name&gt;" as Template…** → save the `.scarftemplate` somewhere.
2. Projects → Templates → **Install from File…** → pick the bundle → the Configure step should render the form you designed.
3. Cancel the install (the preview sheet has a Cancel button) — you just wanted to verify the form shape.

### Catalog validation (only if publishing)

If the user plans to submit this to the public catalog at `awizemann.github.io/scarf/templates/`:

```bash
# From the repo root
./scripts/catalog.sh check
```

Validates every template in `templates/<author>/<name>/` against the Python validator — the same one the PR CI uses. Catches schema issues, claim mismatches, size violations, common secret patterns.

## Common pitfalls

Things to check before declaring the scaffold done:

- [ ] Every cron prompt uses `{{PROJECT_DIR}}` (for exported) OR an absolute path (for local-only). Relative paths will fail.
- [ ] `contents.config` in the manifest equals the actual field count. Claim mismatch = rejected.
- [ ] No `default` on any `secret` field.
- [ ] Every enum field has non-empty `options`.
- [ ] Every list field has `itemType: "string"`.
- [ ] Every table widget has rows of length equal to `columns`.
- [ ] Every webview widget has an https URL that renders something meaningful even pre-first-run (Scarf homepage is a decent placeholder).
- [ ] `dashboard.json` has `version: 1` at the top.
- [ ] `AGENTS.md` documents every config field, every updated widget, and the cron behaviour — the user relies on it as the source of truth when things drift.
- [ ] **No raw URLs in field descriptions.** Use `[link text](https://…)` markdown syntax instead — raw URLs read as long unbreakable tokens in the Configuration sheet. Same rule for long paths and other unbreakable strings; wrap in `` ` `` if they must appear verbatim.

## Reference — source of truth files

- **Dashboard widget schema** — `scarf/scarf/Core/Models/ProjectDashboard.swift` in the Scarf repo. If you need exact field types or defaults, read it.
- **Config schema + validation** — `scarf/scarf/Core/Models/TemplateConfig.swift` and `scarf/scarf/Core/Services/ProjectConfigService.swift`.
- **Exporter behaviour** — `scarf/scarf/Core/Services/ProjectTemplateExporter.swift`. Verifies what files the exporter will pick up from a live project and what it'll carry into a bundle.
- **Installer contract** — `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift`. Verifies what `{{PROJECT_DIR}}` substitution covers and where installed files land.
- **Catalog validator** — `tools/build-catalog.py` in the Scarf repo. Run with `./scripts/catalog.sh check` for the same rules CI uses.
- **Worked example** — `templates/awizemann/site-status-checker/staging/` in the Scarf repo. Complete end-to-end: dashboard with stats + list + webview, a config schema with a list + a number, a cron job, an AGENTS.md that documents every moving part. Read it first whenever you're unsure how a piece should look.
- **User-facing docs** — [Project Templates wiki page](https://github.com/awizemann/scarf/wiki/Project-Templates).
