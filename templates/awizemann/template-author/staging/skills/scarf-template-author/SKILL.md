---
name: scarf-template-author
description: Scaffold a new Scarf project OR enrich an existing one after a Scarf "Upgrade Project" — dashboard, optional configuration schema, optional cron job, AGENTS.md, and (via the scarf-miniapp-author skill) a starter mini-app — from a short conversational interview. Output is immediately usable locally and cleanly exportable as a .scarftemplate bundle.
version: 2.0.0
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

## READ THIS FIRST — use the `scarf-projects` tools, don't hand-edit Scarf's files

Scarf ships an MCP server called **`scarf-projects`**. When you can see its tools, they are the **only** way you register a project, write a dashboard, add a slash command, or check a project's health. They are not a convenience wrapper — they are the same code Scarf's own UI runs, so a write that goes through them cannot produce a shape Scarf can't read.

| What you want to do | Tool | Required arguments |
|---|---|---|
| See every project on this machine | `project_list` | *(none)* — optional `includeArchived` (bool, default true) |
| Inspect one project in full | `project_get` | `project` |
| Register an existing directory as a Scarf project | `project_register` | `name`, `path` |
| Write or replace `.scarf/dashboard.json` | `project_update_dashboard` | `project`, `dashboard` |
| Add a `/command` to a project | `project_add_slash_command` | `project`, `name`, `description`, `body` |
| Reconcile and report on project health | `project_validate` | *(none)* — optional `project`, `repair` |

Notes that save you a retry:

- `project` accepts a display **name** or an **absolute path**. `~` is never expanded — pass the resolved path.
- `dashboard` takes the complete document, as a JSON object or as a string containing one. It **replaces** the file, so if you are enriching rather than authoring from scratch, read the existing `.scarf/dashboard.json` first and send it back whole. (`project_get` reports whether a dashboard exists and parses, and where it lives — it does not hand you its contents; read the file for that.)
- `project_add_slash_command` also takes optional `argumentHint`, `model`, `tags` (array of strings) and `overwrite` (bool, default false).
- `project_validate` takes `repair: true` to apply only the repairs Scarf considers safe.
- A tool that refuses tells you **why**, by JSON path for a bad dashboard (`sections[0].widgets[0].type: unknown widget type`), and writes nothing. Read the reason and fix your input — do not fall back to editing the file by hand because a tool said no. A refusal is the system working.
- Read tools report the **registry's health**. If they say it is damaged, stop and run `project_validate` rather than working around it. `project_register` refuses outright in that state, on purpose: rewriting a damaged registry would make the unreadable rows permanently lost. The project-local writes (dashboard, slash commands) aren't blocked, but they still resolve their target through the registry — so a project whose row is unreadable can't be addressed either way. "No projects found" from a damaged registry does **not** mean the user has no projects; never respond to it by re-registering everything.

**There is no tool for configuration.** `.scarf/manifest.json` and `.scarf/config.json` are still authored as files; see Config Schema Design below.

### When the tools are absent

`scarf-projects` is registered for a **local** Hermes only. On a remote/SSH host you will not see these tools — and only then do you fall back to writing Scarf's files directly, using the file-format reference sections in this skill. The fallback is a last resort, not a shortcut: a hand-written registry row with a malformed field is how projects disappear from Scarf's sidebar. Check whether the tools exist before you decide.

## When to invoke this skill

Activate when the user says things like:

- *"Create a new Scarf project that watches / tracks / reports on …"*
- *"Scaffold a dashboard for …"*
- *"Set up a project that runs a daily check on …"*
- *"Help me author a Scarf template."*
- *"Build me a Scarf project to monitor …"*
- *"Upgrade this project to use Scarf's full feature set."* (the **upgrade/enrichment** path — see below)

Do **not** activate for pure reference questions like *"what widget types does Scarf support?"* or *"how does Scarf handle secrets?"* — answer those inline from the reference sections below.

Also do not activate for a one-off "tweak this one widget" edit — that's a plain file edit, not a scaffold.

## Upgrading / enriching an EXISTING project

Scarf hands off here right after a one-click **"Upgrade Project"** runs its deterministic structure pass on an existing project. By the time you're invoked, Scarf has already ensured: the stable id (`.scarf/project.json`), the AGENTS.md managed block, a Kanban tenant (if the host has Kanban), and a **placeholder** `.scarf/dashboard.json`. Your job is to **enrich it in place** — do NOT re-scaffold and do NOT clobber the user's files:

1. **Read what's already there first** — README, the project's source, existing `.scarf/` files, the placeholder dashboard — so the enrichment fits THIS project.
2. **Replace the placeholder dashboard** (the single "Configure this project" text widget) with a real one tailored to the project, using the widget catalog below. Read the existing `.scarf/dashboard.json` first, then send the complete new document with `project_update_dashboard` — it replaces the file. If the dashboard already has real widgets, read-merge — never delete the user's widgets.
3. Add **slash commands** with `project_add_slash_command` and, where a recurring job fits, **cron jobs** (`hermes cron create`, created paused) — see the Cron section.
4. **Build a starter mini-app or two** — invoke the **`scarf-miniapp-author`** skill for the bridge contract + `.scarf/miniapps/<id>/` format. A task board, an approval queue, or a status panel makes the upgrade tangible. Prefer non-sensitive bridge permissions so it runs immediately.
5. **BOUNDED:** the structure pass already wrote the safe scaffolding (managed AGENTS.md block, identity, tenant). Only ADD or REPLACE-THE-PLACEHOLDER; never write outside managed markers or overwrite user content.

Everything below (widget catalog, config schema, cron, file-writing rules) applies to both new scaffolds and upgrades.

## How a Scarf project is shaped on disk

A Scarf project is a directory that Scarf knows about: it carries a canonical record at `<project>/.scarf/project.json` and a row in the registry at `~/.hermes/scarf/projects.json`. `project_register` writes both halves in one call, with a stable id — that is why you never write either file yourself when the tools are there. For Scarf to render a useful dashboard and for the project to be exportable as a `.scarftemplate`, it needs these files at minimum:

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

Explain the widget catalog (see Widget Catalog sections below) in plain English, then ask which ones feel right. Offer concrete suggestions based on the purpose:

- Counting things (open PRs, failing tests, up/down sites) → `stat` widgets. Add `sparkline: [Number]` (v2.7+) if you have a recent trend handy.
- A list of items with status → `list` with `text` + `status` per item (≤8 items). 12+ items → use `status_grid` (v2.7+) for a denser layout.
- Time-series data → `chart` with `line` or `bar` type.
- Rows × columns of heterogeneous data → `table`.
- A live URL (useful for monitoring a site) → `webview`. **Including a webview widget exposes a Site tab** next to the Dashboard tab — worth noting to the user.
- A static image / generated chart → `image` (v2.7+; local file or remote URL).
- A progress bar for something with a clear 0-to-N scale → `progress`.
- Static help / markdown → `text` with `format: "markdown"`.
- A longer markdown report the cron job writes → `markdown_file` (v2.7+; reads from a file under the project, refreshes when the cron job rewrites it).
- The last N lines of a log/output file → `log_tail` (v2.7+).
- The state of one Hermes cron job (last run / next run / output) → `cron_status` (v2.7+).

**v2.7 file-reading widgets** (`markdown_file`, `log_tail`, `image`-with-`path`) read files relative to the project root. **By convention, write the underlying files inside `<project>/.scarf/`** (e.g. `.scarf/reports/weekly.md`, `.scarf/reports/run.log`) so the project-wide directory watch picks up changes and the widgets refresh automatically. Files outside `.scarf/` work too but only refresh when `dashboard.json` itself changes, so cron jobs writing outside `.scarf/` should `touch dashboard.json` after each run.

### 4. Configuration needs

- *"Does this project need anything configurable by the user — URLs to watch, API tokens, thresholds, a list of accounts?"*

If yes → design a config schema. Fields map to seven types (see Config Schema Design below). Remember: **secret fields never have defaults**; that's a hard validator rule.

If no → skip `.scarf/manifest.json`; the project works but won't have a Configuration form.

### 5. Target agents

- *"Which agents will operate this project? Just Claude Code? Also Cursor / Codex / Aider / other?"*

For v1 just write `AGENTS.md` — every modern agent reads it, and if you need a specific shim (CLAUDE.md, GEMINI.md, .cursorrules), add it as a symlink to AGENTS.md so content stays in sync.

## Widget Catalog (JSON shapes)

All widgets require `type` and `title`. Type-specific fields below.

`project_update_dashboard` validates every widget against this exact catalog before it writes anything, so a type or a missing required field that isn't in here comes back as a refusal rather than a broken dashboard. The accepted types are: `stat`, `progress`, `text`, `table`, `chart`, `list`, `webview`, `markdown_file`, `log_tail`, `cron_status`, `image`, `status_grid`, `kanban_summary`.

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
Every row should have the same length as `columns`. Nothing validates this — the tool won't refuse a ragged table and the renderer won't complain, it will just draw a table that looks wrong. Check it yourself.

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
`chartType` is `"line"`, `"bar"` or `"pie"`. Any other value — including `"area"`, which the schema still advertises — renders as a **line** chart. Don't promise the user an area chart.

### `list` — items with optional status badge
```json
{ "type": "list", "title": "Watched Sites",
  "items": [
    { "text": "https://example.com", "status": "success" },
    { "text": "https://example.org", "status": "danger" }
  ]
}
```
**Status values (typed in v2.7+):** prefer the canonical set — `"success"`, `"warning"`, `"danger"`, `"info"`, `"pending"`, `"done"`, `"neutral"`. Common synonyms also work and map to the canonical case (`"ok"`, `"up"`, `"passing"` → success; `"down"`, `"error"`, `"failed"` → danger; `"active"` → info; `"complete"`, `"finished"` → done; `"warn"`, `"degraded"` → warning). Unknown strings render as plain text rather than crashing — old dashboards using ad-hoc statuses keep working unchanged. **For new templates, prefer the canonical names** so the colors stay predictable across Scarf releases.

### `webview` — embedded live URL
```json
{ "type": "webview", "title": "First Watched Site",
  "url": "https://awizemann.github.io/scarf/", "height": 420 }
```
**Important:** including any `webview` widget in a dashboard exposes a **Site** tab next to the Dashboard tab in the project view. Useful for templates that watch something renderable. The agent can update `url` on cron runs to keep the Site tab in sync with config (e.g., set it to `values.sites[0]`).

---

## Widget Catalog (v2.7+ — file-reading and richer widgets)

Five new widget types landed in v2.7. They all read from disk relative to the project root, and refresh automatically when any file under `<project>/.scarf/` changes — so a cron job that writes `<project>/.scarf/reports/uptime.md` will trigger the corresponding widget to re-render. **Convention: place the underlying files inside `.scarf/` (or a subdir of it) so the directory watch picks them up.** Files outside `.scarf/` work too but only refresh when `dashboard.json` itself changes.

### `markdown_file` — renders a markdown file from disk
```json
{ "type": "markdown_file", "title": "This Week", "path": ".scarf/reports/weekly.md" }
```
`path` is relative to the project root. Refuses absolute paths and `..` escape. Use this when the cron job writes a longer-form report; use `text` when the content is short and authored inline.

### `log_tail` — last N lines of a file, monospaced
```json
{ "type": "log_tail", "title": "Last cron run", "path": ".scarf/reports/run.log", "lines": 30 }
```
Default `lines` is 20, capped at 200. ANSI color codes are stripped automatically. Pair with cron jobs that write atomic log snapshots (write-temp + rename) — in-place appends won't refresh until `dashboard.json` is touched.

### `cron_status` — last/next run + state for one Hermes cron job
```json
{ "type": "cron_status", "title": "Uptime sweep", "jobId": "uptime-sweep", "lines": 5 }
```
`jobId` matches a `HermesCronJob.id` (visible in the Cron tab). Read-only — Run/Pause/Resume actions stay on the Cron tab; this widget only reports state. Great for dashboards that drive a single scheduled task.

### `image` — local file or remote URL
```json
{ "type": "image", "title": "Latency p95", "path": ".scarf/reports/latency.png", "height": 200 }
{ "type": "image", "title": "Build status", "url": "https://example.com/badge.svg" }
```
Either `path` (local, relative to project root) OR `url` (remote). `path` wins when both are set. Useful for chart PNGs the cron job generates with matplotlib / Plotly.

### `status_grid` — compact NxM grid of colored cells
```json
{ "type": "status_grid", "title": "Fleet", "gridColumns": 6, "cells": [
  { "label": "us-east-1",     "status": "success", "tooltip": "200ms p50" },
  { "label": "us-west-2",     "status": "warning", "tooltip": "elevated latency" },
  { "label": "eu-central-1",  "status": "danger",  "tooltip": "down" }
]}
```
Reuses the typed status enum from `list`. Auto-fits columns when `gridColumns` is omitted. Denser than a `list` when monitoring 12+ services at a glance.

### `kanban_summary` — top open tasks from this project's Kanban board
```json
{ "type": "kanban_summary", "title": "Board", "value": 5 }
```
Needs nothing but `title`. Pulls the project's own Kanban tenant (the `kanbanTenant` in `manifest.json`) and renders the top in-progress / blocked / todo tasks plus a glance line like "12 todo · 3 running · 5 blocked". Optional `value` sets how many rows to show (default 3). Only useful on a host that has Kanban.

### `stat` — sparkline (v2.7+ additive field)
```json
{ "type": "stat", "title": "Releases this month", "value": 4,
  "color": "blue", "sparkline": [1, 2, 1, 3, 2, 4] }
```
Optional `sparkline: [Number]` renders a 1-line trend under the big number. Min 2 points, no max — tiny SVG path, cheap. Works on every existing `stat` widget without breaking older Scarf builds (they ignore the unknown field).

### Choosing a widget type — quick guide

- Counting things → `stat` (add `sparkline` if you have a recent trend).
- Progress toward a target → `progress`.
- Authored copy or short instructions → `text` (markdown).
- A report the cron job writes to disk → `markdown_file`.
- The most-recent run output of a cron job → `log_tail` or `cron_status`.
- A list of services / URLs / items with health → `list` (≤8 items) or `status_grid` (12+ items).
- Tabular data → `table` (or `chart` if it's numeric and you want trends).
- A live website or chart from a cron-generated PNG → `webview` (browsable) or `image` (static).

## Config Schema Design

If the project needs user-configurable values, design a schema. Put it in `<project>/.scarf/manifest.json` with this shape:

```json
{
  "schemaVersion": 2,
  "id": "author/project",
  "name": "My Project",
  "version": "1.0.0",
  "description": "Short one-liner.",
  "contents": { "dashboard": true, "agentsMd": true, "config": 2, "cron": 1 },
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

Note: `contents.config` is the **count of schema fields**, not a boolean. In the example above it's `2` because there are two fields. `contents.cron` is likewise a count — set it to the number of cron jobs the bundle ships (`1` above), or leave it out only when there are none.

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
- **`schemaVersion` is 1, 2 or 3** — pick the lowest that covers what the template ships. 1 = dashboard/AGENTS only; **2** = adds the `config` block; **3** = adds `contents.slashCommands`. A bundle that ships `slash-commands/` files MUST be schemaVersion 3 and MUST list every one of them in `contents.slashCommands`, or the validator rejects it both ways (claimed-but-missing, and present-but-unclaimed).
- **`contents.config`** must equal the actual count of schema fields — a claim mismatch is rejected.
- **`contents.cron`** must equal the number of cron jobs in the bundle. It defaults to 0, so a template that exports one cron job and forgets this line is rejected.

## Cron Job Design

If the project has a scheduled task, register a cron job via `hermes cron create`. That is the whole job for a live project.

### How cron jobs reach an exported template

**You do not hand-author `cron/jobs.json` into a live project.** Scarf's exporter *writes* that file into the staging directory from the real Hermes jobs the user picks in the Export sheet. A `cron/jobs.json` you drop into a project directory is read by nothing. So: register the job with `hermes cron create` and let Export carry it.

The staging/bundle layout the exporter produces is **flat**, and is not a copy of the project directory — there is no `.scarf/` inside a bundle, and the manifest is named `template.json`, not `manifest.json`:

```
staging/
├── template.json      # the manifest (`.scarf/manifest.json` becomes this)
├── dashboard.json     # from .scarf/dashboard.json
├── AGENTS.md
├── README.md
├── cron/
│   └── jobs.json      # WRITTEN BY THE EXPORTER from the user's real cron jobs
└── slash-commands/    # only when the template ships commands
```

Each entry the exporter writes into `cron/jobs.json` is shaped like this — useful to recognize, not to author by hand:

```json
[
  {
    "name": "Check site status",
    "schedule": "0 9 * * *",
    "prompt": "Read {{PROJECT_DIR}}/.scarf/config.json — get values.sites and values.timeout_seconds — then HTTP GET each URL with that timeout, write the results to {{PROJECT_DIR}}/status-log.md, and update {{PROJECT_DIR}}/.scarf/dashboard.json's stat widgets by title (Sites Up, Sites Down, Last Checked). Reply with a one-line summary."
  }
]
```

### Using secrets in cron prompts

`secret`-typed config fields land in the macOS Keychain at install time, with `keychain://` URIs in `<project>/.scarf/config.json` (never plaintext on disk). At install + on every config save, **Scarf mirrors the resolved SECRET values — and only those — into `~/.hermes/.env`**. Non-secret fields (URLs, thresholds, lists) are never mirrored: they stay in `.scarf/config.json`, and a prompt that wants one has the agent read that file. Writing `$SCARF_<SLUG>_<SOME_PLAIN_FIELD>` in a prompt gets you an empty string, because that variable was never set. under env var names like `SCARF_<UPPERCASE_SLUG>_<UPPERCASE_FIELDKEY>`. Hermes's cron scheduler reloads `~/.hermes/.env` fresh on every tick, so the values are reachable from any tool the agent invokes.

**The agent reads them via the terminal or code_exec tool — not from prompt-text substitution.** Hermes does not interpolate env vars into prompt bodies. Tool-invoked subprocesses (the only path through which env vars become visible) DO see them via shell-level expansion or `os.environ`. Cron prompts should reference secrets in tool invocations, not in inline text.

**Naming.** For a template with `slug = "site-status-checker"` and a secret field `api_token`, the env var is `SCARF_SITE_STATUS_CHECKER_API_TOKEN`. Both halves are upper-cased and any non-`[A-Z0-9_]` characters become `_`. Stable across releases — write your prompts using these names and they'll keep working when the user rotates the secret.

**Example cron prompt (with a secret):**

```json
{
  "name": "Daily news digest",
  "schedule": "0 9 * * *",
  "prompt": "Read {{PROJECT_DIR}}/.scarf/config.json and take values.rss_url from it — that field is not a secret and is NOT in the environment. Then use the terminal tool to fetch it: `curl -sS -H \"Authorization: Bearer $SCARF_LOCAL_NEWS_API_TOKEN\" \"<the rss_url you just read>\" -o {{PROJECT_DIR}}/.scarf/feed.xml`. Then summarise the top 5 items into {{PROJECT_DIR}}/.scarf/digest.md."
}
```

The agent runs `curl` via the terminal tool; the shell expands the env vars from the cron process's environment (which Hermes populated by loading `~/.hermes/.env`). For Python via the code_exec tool, use `os.environ['SCARF_LOCAL_NEWS_API_TOKEN']`.

**What NOT to do:**

- ❌ *"Read `keychain://...` from config.json and call the API with it."* Hermes treats the URI as opaque text — the API call sends `Authorization: Bearer keychain://...` and gets a 401.
- ❌ *"Use the API token from values.api_token in config.json."* Same issue — the value in config.json is the URI, not the secret.
- ❌ Inlining a secret into the prompt body and asking the agent to use it. Secrets shouldn't appear in prompts; that's why we route them through env vars.

**What about `~/.hermes/.env` rotation?** The user rotates a secret in Scarf's Configuration sheet → Scarf re-resolves from the Keychain → re-mirrors to `~/.hermes/.env` → next cron tick (Hermes reloads `.env` per tick) sees the new value. No cron-job edit needed.

### Gotchas

- **Hermes does not set a CWD when firing cron jobs.** Relative paths in the prompt resolve against wherever the Hermes process happens to be running, not the project. Always use `{{PROJECT_DIR}}` in the prompt — the installer substitutes the absolute path at install time. This is THE most common template-author mistake.
- **Cron jobs created by the installer start paused.** Their name is auto-prefixed with `[tmpl:<template-id>]`. The user enables them from Scarf's Cron sidebar when ready.
- **Registering a cron job for a user's local (non-exported) project:** run `hermes cron create --name "<descriptive name>" "<schedule>" "<prompt>"` directly, substituting the absolute `<project>` path for `{{PROJECT_DIR}}` yourself. Then `hermes cron pause <id>` so it doesn't run until the user opts in.
- **Hermes does not substitute env vars into prompt text.** `$VAR` references in the prompt body are passed through verbatim. Env vars only become visible when the agent invokes a tool (terminal, code_exec) that runs in a subprocess inheriting the cron process's environment — see the "Using secrets in cron prompts" section above.

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

### Step 3 — register the project with Scarf

```
project_register(name: "<project-name>", path: "<absolute-project-dir>")
```

This comes BEFORE the dashboard, because `project_update_dashboard` resolves its target through the registry. The tool writes `<project>/.scarf/project.json` with a stable id and adds the registry row in one call. The directory must already exist (Step 2 made it) — registering never creates it. It refuses a duplicate name, and refuses a path that is already registered; if you hit either, run `project_get` to see what is already there rather than picking a variant name.

Scarf watches the registry and picks the project up within a second — there is no manual UI step.

**Fallback, remote hosts only** (no `scarf-projects` tools): append a `{ "name": "<project-name>", "path": "<absolute-project-dir>" }` entry to the `projects` array in `~/.hermes/scarf/projects.json` — read it, parse it, append, write it back. Creating the file from scratch means `{ "projects": [ … ] }`. Add **no other fields**. In particular do not write a `uuid` — Scarf derives project identity itself, and a hand-invented value there is exactly the mistake that has taken projects out of the sidebar before. A row Scarf can read is a row it can repair; a row carrying a made-up ID is not.

### Step 4 — write the dashboard

```
project_update_dashboard(project: "<project-name>", dashboard: { … })
```

The document replaces `.scarf/dashboard.json` wholesale. Only when the tools are absent do you write that file yourself.

Use the Widget Catalog above. Always include:

- `version: 1`
- `title` (the project's display name)
- `description` (a one-liner shown under the title)
- `sections` (array; each has a non-empty `title`, optional `columns` (1–12, default 3), `widgets`)

Keep section titles short. Group related widgets. First section is usually "Current Status" or similar with the key stats.

If the tool refuses, it names the offending field by JSON path and nothing was written — fix that field and send the whole document again.

### Step 5 — write `manifest.json` (only if the project has a config schema)

Put the full manifest shape from Config Schema Design above. Use `schemaVersion: 2`, match `contents.config` to the actual field count, and ensure every secret field has no `default`.

If there's no config schema, skip this file — the project still works, it just won't have a Configuration button. You can add it later.

There is no tool for this file, on any host: write `<project>/.scarf/manifest.json` directly. Same for `.scarf/config.json` — and never put a secret value in either (see the secrets rules above).

### Step 6 — write `AGENTS.md`

Every scaffolded project needs an `AGENTS.md` that covers:

- **Purpose** — what the project does.
- **Layout** — which files exist and what they're for.
- **Configuration** — if there's a config schema, document every field: what it's for, what valid values look like, what happens when it's missing.
- **Dashboard** — list every widget the cron job (if any) updates, by title. If the cron updates a webview widget's URL, document that explicitly.
- **Cron behaviour** — what the cron job does, what it reads, what it writes, what its exit criteria are.
- **Chat prompts** — common user questions and how to answer them (e.g., *"What's the status of my sites?"* → "read the top section of `status-log.md` and summarise").
- **What NOT to do** — e.g., *don't modify `.scarf/config.json` yourself; tell the user to open the Configuration button.*

Use `{{PROJECT_DIR}}` placeholders in AGENTS.md only if the template will be installed through the installer (which substitutes the token). For a hand-scaffolded local-only project, substitute the absolute path yourself — `{{PROJECT_DIR}}` only resolves at install time.

### Step 7 — write `README.md`

User-facing. Keep it short:

- One-paragraph purpose.
- How to install / first run (for an unexported project: "the scaffolding agent registered the project with Scarf, so it appears in the Projects sidebar within a second — no manual UI step needed").
- How to trigger the cron job manually (Cron sidebar → Run Now).
- A pointer at `AGENTS.md` for agents.

### Step 8 — register the cron job (if any)

For a local non-exported project:

```bash
hermes cron create --name "<descriptive name>" "<schedule>" "<prompt with absolute project dir substituted>"
# Then pause it so it doesn't fire until the user's ready:
hermes cron pause <newly-created-job-id>
```

Read the id back by parsing the create output, or from `hermes cron list`.

For an exportable template (one you're staging in `templates/<author>/<name>/staging/`): just author `cron/jobs.json` — the installer registers + pauses at install time, and prefixes the name with `[tmpl:<id>]`.

### Step 9 — add slash commands (if any fit)

```
project_add_slash_command(project: "<project-name>", name: "<command>", description: "<one line>", body: "<prompt text>")
```

Command names are lowercase letters, digits and hyphens, must start with a letter, and are capped at 64 characters — pass the name without the leading slash. The body may use `{{argument}}` and `{{argument | default: "..."}}`. Adding a command that already exists is refused unless you pass `overwrite: true`; optional `argumentHint`, `model` and `tags` shape how it appears in the slash menu.

**Fallback, remote hosts only:** write `<project>/.scarf/slash-commands/<name>.md` — YAML frontmatter with `name` and `description`, optionally `argumentHint`, `model` and a `tags` list, then the prompt body below the closing `---`. The key is `argumentHint`; a `hint` key is ignored.

### Step 10 — check your work

```
project_validate(project: "<project-name>")
```

Runs Scarf's Project Doctor over what you just built and reports anything that disagrees — a missing record, a dashboard that doesn't parse, an orphan. Do this before you tell the user you're done. `repair: true` applies only the repairs Scarf considers safe, and never any while the registry is damaged.

### Step 11 (optional) — log to the Template Author project's list

If the user has the `awizemann/template-author` project installed (the one that shipped this skill), add an entry to its `Scaffolded Projects` list widget:

```json
{ "text": "<absolute-project-dir> — <one-line purpose>", "status": "success" }
```

Use `project_get` to find that project's dashboard path, read the file, add the item, and send the whole document back through `project_update_dashboard` — it replaces the file, so preserve every other field as-is. This gives the user a running audit trail of everything you've scaffolded for them.

## Testing your scaffold

### Minimum smoke test

1. Run `project_validate` on the project (Step 10) and confirm it reports nothing wrong, then tell the user the project will appear in Scarf's Projects sidebar within a second.
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

- [ ] **You used the `scarf-projects` tools** for registration, the dashboard and slash commands — and hand-edited Scarf's files only because the tools genuinely weren't there.
- [ ] **You never invented a registry field.** No `uuid` you made up, no extra keys. On the fallback path, a row is `{name, path}` and nothing else.
- [ ] `project_validate` reports the project healthy.
- [ ] Every cron prompt uses `{{PROJECT_DIR}}` (for exported) OR an absolute path (for local-only). Relative paths will fail.
- [ ] `contents.config` in the manifest equals the actual field count. Claim mismatch = rejected.
- [ ] No `default` on any `secret` field.
- [ ] Every enum field has non-empty `options`.
- [ ] Every list field has `itemType: "string"`.
- [ ] Every table widget has rows of length equal to `columns` — unenforced, so it's on you.
- [ ] Every webview widget has an https URL that renders something meaningful even pre-first-run (Scarf homepage is a decent placeholder).
- [ ] `dashboard.json` has `version: 1` at the top.
- [ ] `AGENTS.md` documents every config field, every updated widget, and the cron behaviour — the user relies on it as the source of truth when things drift.
- [ ] **No raw URLs in field descriptions.** Use `[link text](https://…)` markdown syntax instead — raw URLs read as long unbreakable tokens in the Configuration sheet. Same rule for long paths and other unbreakable strings; wrap in `` ` `` if they must appear verbatim.
- [ ] **Leave the `<!-- scarf-project:begin -->` / `<!-- scarf-project:end -->` region alone in the project's `AGENTS.md`.** As of Scarf v2.3, the app auto-injects a project-identity block at chat-start time (project name, directory, template id, configuration field names, cron jobs). Anything you write inside that region will be overwritten on the next chat start. Put template-specific agent instructions BELOW the block so they're preserved across refreshes.

## Reference — source of truth files

- **Dashboard widget schema** — `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift` in the Scarf repo. If you need exact field types or defaults, read it.
- **What `project_update_dashboard` will accept** — `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/DashboardWidgetCatalog.swift`: the exact per-type required fields the tool validates against before writing.
- **The `scarf-projects` tools themselves** — `scarf/Packages/ScarfCore/Sources/ScarfProjectsMCPKit/`. `ProjectMCPToolCatalog.swift` is the argument schema the agent sees; `ProjectMCPTools.swift` is what each tool actually does and every reason it refuses.
- **Config schema + validation** — `scarf/scarf/Core/Models/TemplateConfig.swift` and `scarf/scarf/Core/Services/ProjectConfigService.swift`.
- **Exporter behaviour** — `scarf/scarf/Core/Services/ProjectTemplateExporter.swift`. Verifies what files the exporter will pick up from a live project and what it'll carry into a bundle.
- **Installer contract** — `scarf/scarf/Core/Services/ProjectTemplateInstaller.swift`. Verifies what `{{PROJECT_DIR}}` substitution covers and where installed files land.
- **Catalog validator** — `tools/build-catalog.py` in the Scarf repo. Run with `./scripts/catalog.sh check` for the same rules CI uses.
- **Worked example** — `templates/awizemann/site-status-checker/staging/` in the Scarf repo. Complete end-to-end: dashboard with stats + list + webview, a config schema with a list + a number, a cron job, an AGENTS.md that documents every moving part. Read it first whenever you're unsure how a piece should look.
- **User-facing docs** — [Project Templates wiki page](https://github.com/awizemann/scarf/wiki/Project-Templates).
