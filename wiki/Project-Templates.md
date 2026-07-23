---
title: Project-Templates
type: note
permalink: scarf-wiki/project-templates
created: 2026-05-29
updated: 2026-05-29
---

# Project Templates

`.scarftemplate` bundles — shareable projects for Scarf and any agent that reads the [agents.md](https://agents.md/) standard. Introduced in v2.2.0.

A template packages everything needed to reproduce a project on another machine: the dashboard, the agent instructions, any skills, any scheduled cron jobs, an optional memory appendix, and — as of v2.2 — a typed configuration schema that drives a form during install. Templates are agent-portable out of the box: the same bundle works identically for users running Claude Code, Cursor, Codex, Aider, and the 20+ other agents that read `AGENTS.md`.

## Quick jump

- [Installing a template](#installing-a-template)
- [Configuring a template](#configuring-a-template)
- [The Site tab](#the-site-tab)
- [Uninstalling](#uninstalling)
- [Exporting a project as a template](#exporting-a-project-as-a-template)
- [Authoring a template](#authoring-a-template) — manifest, schema, AGENTS.md contract
- [The public catalog](#the-public-catalog)
- [Safe-by-design invariants](#safe-by-design-invariants)
- [Troubleshooting](#troubleshooting)

## Installing a template

Three entry points, all under **Projects → Templates** in the project sidebar's toolbar menu:

1. **Install from File…** — pick a `.scarftemplate` from disk.
2. **Install from URL…** — paste an `https://` URL pointing at a `.scarftemplate`.
3. **`scarf://install?url=…`** — click a deep link in a browser. macOS hands it to Scarf via the registered URL scheme. Only `https://` targets are accepted; `http://`, `file://`, and `javascript:` are refused. The install sheet always opens for user confirmation — a deep link never installs silently.

Every install goes through a preview sheet that lists:

- The exact project directory to be created (you pick the parent folder). _v2.5.2+:_ on remote server contexts the parent-directory step uses a path-input + Verify sheet (mirroring the Add Project pattern from #54) — the installer writes the project files to the remote host via SFTP rather than to the Mac filesystem.
- Every file inside the project.
- Every skill to be namespaced under `~/.hermes/skills/templates/<slug>/`.
- Every cron job to be registered, always paused on install — you enable each one manually from the Cron sidebar when ready.
- Every Keychain secret the Configure step will write.
- A live diff of any memory appendix against your existing `MEMORY.md`.

Nothing writes until you click **Install**.

## Configuring a template

Templates can declare a typed configuration schema. When present, Scarf inserts a **Configure** step between the parent-directory pick and the preview sheet.

Seven field types are supported today:

| Type | JSON key | Rendered as | Constraints |
|---|---|---|---|
| Single-line string | `"type": "string"` | Text field | `minLength`, `maxLength`, `pattern` (regex) |
| Multi-line string | `"type": "text"` | Text editor | `minLength`, `maxLength` |
| Number | `"type": "number"` | Number field | `min`, `max` |
| Boolean | `"type": "bool"` | Toggle | — |
| Enum | `"type": "enum"` | Segmented picker (≤4) / Dropdown (>4) | `options: [{value, label}]` |
| List of strings | `"type": "list"` + `"itemType": "string"` | Repeatable rows with add/remove | `minItems`, `maxItems` |
| Secret | `"type": "secret"` | Password field with show/hide | Stored in macOS Keychain |

Non-secret values are written to `<project>/.scarf/config.json` as plain JSON. Secrets are stored in the login Keychain under service name `com.scarf.template.<slug>` with an account keyed to a hash of the project directory path — two installs of the same template in different directories don't collide.

After install, the **slider icon** in the dashboard header re-opens the same form pre-filled with current values. Change a site, rotate a token, toggle a feature; the next cron run picks up the new values automatically. Secrets are never echoed back — the form shows "Saved in Keychain — leave empty to keep the stored value" if the Keychain entry already exists.

### Model recommendations

A template can suggest a preferred model plus alternatives:

```json
"modelRecommendation": {
  "preferred": "claude-sonnet-4.5",
  "rationale": "Tool-heavy workload — reasoning helps.",
  "alternatives": ["claude-opus-4.1", "gpt-4.1"]
}
```

Scarf displays this in the Configure sheet without auto-switching your active model — always your call. Change it in Settings if you agree.

## The Site tab

A dashboard that includes at least one `webview` widget automatically gets a **Site** tab next to **Dashboard** in the project view. Useful for templates that watch something renderable — a site, a Grafana panel, a preview endpoint.

The example `awizemann/site-status-checker` template uses this: on every cron run, the agent rewrites the webview's `url` field to the first configured site, so the Site tab stays in sync with whatever you configured.

## Uninstalling

Right-click any template-installed project in the sidebar → **Uninstall Template (remove installed files)…**, or click the uninstall icon in the dashboard header.

Uninstall is driven by `<project>/.scarf/template.lock.json`, which records everything the installer wrote. The preview sheet lists what will be removed and what will be preserved:

- **Removed:** every file listed in the lock, the skills namespace directory (wholesale — it's isolated), every Keychain ref, every tagged cron job via `hermes cron remove`, the memory block between its `<!-- scarf-template:<id>:begin/end -->` markers, and the projects-registry entry.
- **Preserved:** every file in the project directory that *wasn't* installed by the template. If the cron job wrote a `status-log.md` or you dropped a personal file into the project folder, it stays. The directory itself is removed only if nothing user-owned is left inside; otherwise the directory is kept with just your files. A banner on the uninstall success screen explicitly lists preserved paths so you know what's left behind.

There's no undo — reinstalling means re-running the install flow.

### Remove from List vs. Uninstall Template

Two distinct actions in the project sidebar's right-click menu:

- **Remove from List (keep files)…** — *registry only*. Scarf forgets the project; nothing on disk is touched, cron jobs stay, Keychain secrets stay, skills stay. A confirmation dialog spells this out. Useful for hand-installed projects (not template-installed) or if you want to hide a project from the sidebar without destroying it.
- **Uninstall Template (remove installed files)…** — *full cleanup*, driven by the lock file as above. Only shown for projects that were installed from a `.scarftemplate`.

## Exporting a project as a template

Select any project → **Projects → Templates → Export "&lt;name&gt;" as Template…**. The form asks for:

- Id (author/name, e.g. `awizemann/focus-dashboard`).
- Display name, version, description.
- Optional author block (name, url), category, tags.
- Optional icon + screenshots.
- Which skills from `~/.hermes/skills/` to include.
- Which cron jobs from `~/.hermes/cron/jobs.json` to include.
- Optional memory snippet to ship.

The exporter carries the configuration *schema* from `<project>/.scarf/manifest.json` into the bundle but **never** the user's values from `<project>/.scarf/config.json`. Exporting is safe on projects with live config — your secrets and personal settings stay local.

The output is a single `.scarftemplate` file you can hand to anyone, upload to a share, or submit to the public catalog.

## Authoring a template

The bundle is a zip with at minimum:

```
<name>.scarftemplate
├── template.json           # manifest (see below)
├── README.md               # shown in the install preview
├── AGENTS.md               # REQUIRED — cross-agent instructions
└── dashboard.json          # copied to <project>/.scarf/dashboard.json
```

And optionally:

```
├── instructions/
│   ├── CLAUDE.md           # Claude Code shim
│   ├── GEMINI.md
│   ├── .cursorrules
│   └── .github/copilot-instructions.md
├── skills/
│   └── <skill-name>/
│       └── SKILL.md
├── slash-commands/         # NEW in schemaVersion 3 (v2.5)
│   └── <name>.md           # one Markdown file per project-scoped slash command
├── cron/
│   └── jobs.json           # array of cron job definitions
└── memory/
    └── append.md           # appended to ~/.hermes/memories/MEMORY.md
```

### Manifest (`template.json`)

```json
{
  "schemaVersion": 3,
  "id": "yourname/your-template",
  "name": "Your Template",
  "version": "1.0.0",
  "description": "One-line description shown in catalog + install sheet.",
  "author": { "name": "Your Name", "url": "https://github.com/yourname" },
  "category": "productivity",
  "tags": ["example", "monitoring"],
  "contents": {
    "dashboard": true,
    "agentsMd": true,
    "instructions": ["CLAUDE.md"],
    "skills": ["example-skill"],
    "slashCommands": ["audit-prs", "summarize-week"],
    "cron": 1,
    "memory": true,
    "config": 2
  },
  "config": {
    "schema": [
      { "key": "site_url", "type": "string", "label": "Site URL", "required": true,
        "pattern": "^https://" },
      { "key": "api_token", "type": "secret", "label": "API Token", "required": true }
    ],
    "modelRecommendation": {
      "preferred": "claude-haiku-4",
      "rationale": "Lightweight workload — haiku is plenty."
    }
  }
}
```

The `contents` block is a *claim* — the installer verifies every claim against the actual zip entries before anything touches disk. A bundle that ships 2 cron jobs while claiming `"cron": 1` is refused at load time. Same applies to `slashCommands` — every name must have a matching `slash-commands/<name>.md` file at the bundle root.

### `slashCommands` (v2.5+, schemaVersion 3)

Templates can ship project-scoped slash commands by listing each name in `contents.slashCommands` and including a matching `slash-commands/<name>.md` file at the bundle root. The installer copies them to `<project>/.scarf/slash-commands/` and tracks them in the lock file. **User-authored slash commands in the same directory survive uninstall** — only the template-shipped ones are removed.

`schemaVersion` bumps to **3** only when a bundle ships slash commands. v1 and v2 bundles continue to install identically (the installer accepts schemaVersion 1, 2, and 3). See [Slash Commands](Slash-Commands) for the file format and substitution rules.

### v2.7 widget vocabulary expansion (no schema bump)

Scarf v2.7 added five new widget types — `markdown_file`, `log_tail`, `cron_status`, `image`, `status_grid` — plus a `sparkline` field on `stat` and a typed status enum on `list` items. **None of these require a `schemaVersion` bump.** They're additive within `dashboard.json` itself, so:

- v1, v2, v3 bundles that use only the original 7 widget types keep working byte-identically on v2.7+.
- Bundles that adopt new widget types still validate against the existing manifest schema — only the catalog validator's vocabulary list ([`tools/widget-schema.json`](https://github.com/awizemann/scarf/blob/main/tools/widget-schema.json)) was extended.
- A v2.7-authored dashboard installed into a pre-v2.7 Scarf renders unknown widgets as a clearly-labeled error card (not a crash), so forward-incompatibility degrades gracefully.

### v2.7.5 — `kanban_summary` widget + new `kanbanTenant` manifest field

v2.7.5 adds a sixth additive widget kind — **`kanban_summary`** — and a new optional `kanbanTenant` field on the manifest. Same forward-compatibility rules apply:

- **`kanban_summary`** renders the top three `running` / `blocked` / `todo` tasks for the current project's tenant by priority, plus a glance footer (`"12 todo · 3 running · 5 blocked"`) sourced from `hermes kanban stats`. Polls every 10s while the dashboard is foregrounded. Drop `{ kind: kanban_summary, max_rows: 3 }` into a dashboard.json section to include it. Catalog validator ([`tools/build-catalog.py`](https://github.com/awizemann/scarf/blob/main/tools/build-catalog.py)) and site renderer ([`site/widgets.js`](https://github.com/awizemann/scarf/blob/main/site/widgets.js)) recognize it; bundles using it keep validating against the existing schema.
- **`kanbanTenant`** is a Scarf-minted `scarf:<slug>` string written to `<project>/.scarf/manifest.json` on first kanban interaction inside a project, so per-project boards filter by it automatically. **Templates do not ship `kanbanTenant`** — it's user-machine-scoped state. The exporter strips it out of bundles so two installs of the same template don't collide on tenants. Catalog validator skips the field entirely.
- The widget is **only useful when Hermes ≥ v0.12** (the `kanban` CLI surface). On a pre-v0.12 host, `KanbanSummaryWidgetView` renders its empty/error state and the rest of the dashboard keeps working.

See [Projects](Projects-and-Profiles) for the full widget catalog, the per-project Kanban board surface, and the typed status badge synonyms.

### `AGENTS.md` contract

`AGENTS.md` is the single source of truth for what the project does and how to operate it. It must:

- Describe the project's purpose and layout.
- Document every `~/.scarf/config.json` field the cron job reads.
- Document every file in the project the cron job writes.
- Document every widget in `dashboard.json` the cron job updates (by title + key).
- Use `{{PROJECT_DIR}}` in any path references — the installer substitutes absolute paths at install time.

The cron job's `prompt` field in `cron/jobs.json` is the operational instruction; `AGENTS.md` is the reference spec. Both should agree; if they drift, catalog CI doesn't catch it, so template authors own the consistency.

### Install-time token substitution

In cron-job prompts and in `dashboard.json` strings, the installer substitutes:

- `{{PROJECT_DIR}}` — absolute path of the newly-created project directory.
- `{{TEMPLATE_ID}}` — the `owner/name` id from the manifest.
- `{{TEMPLATE_SLUG}}` — the sanitised slug used for the skills namespace + project dir.

Cron jobs need `{{PROJECT_DIR}}` because Hermes doesn't set a CWD when firing cron — relative paths would resolve against wherever Hermes happens to be.

## The public catalog

Published templates live at [awizemann.github.io/scarf/templates/](https://awizemann.github.io/scarf/templates/), generated from `templates/<author>/<name>/` in the [Scarf repo](https://github.com/awizemann/scarf/tree/main/templates).

Each template gets a detail page with:

- The README rendered as markdown.
- A live preview of the post-install dashboard (`site/widgets.js` renders the same widget vocabulary the app uses).
- The configuration schema rendered with constraint summaries ("1–25 items", "≥ 1", "Pattern: `^https://`").
- A one-click install button that opens `scarf://install?url=…` in the user's browser.

Submissions go through [`templates/CONTRIBUTING.md`](https://github.com/awizemann/scarf/blob/main/templates/CONTRIBUTING.md). A CI-enforced Python validator ([`tools/build-catalog.py`](https://github.com/awizemann/scarf/blob/main/tools/build-catalog.py)) mirrors the Swift-side invariants (supported field types, widget types, contents-claim verification, secret-with-default rejection, 5 MB bundle-size cap, high-confidence secret patterns). Bundles are raw-served from `main` at `https://raw.githubusercontent.com/awizemann/scarf/main/templates/<author>/<name>/<name>.scarftemplate` — no per-template GitHub Releases ceremony.

## Safe-by-design invariants

The installer enforces these rules — a bundle that violates any of them is refused at load time:

- **Never writes to global configuration:** `~/.hermes/config.yaml`, `auth.json`, sessions, or any credential path is off-limits.
- **Skills are namespaced:** `~/.hermes/skills/templates/<slug>/<skill-name>/` — never loose in the top-level skills dir, so uninstall is `rm -rf` on one folder.
- **Cron jobs are tagged and paused:** `[tmpl:<id>] <name>` with `paused: true` on create. You enable each one manually from the Cron sidebar.
- **Secrets never land in `config.json`:** `secret`-type field values route through `SecItemAdd` and the config file stores `keychain://service/account` URIs.
- **Bundle size capped:** 50 MB at the install layer, 5 MB at the catalog-submission layer.
- **Install preview is load-bearing:** every file the installer will write appears in the sheet. There's no silent write path.

## How the agent sees the project (v2.3+)

When you click **New Chat** on a project's Sessions tab, Scarf does two things:

1. Starts `hermes acp` with the project directory as the session's working directory.
2. Writes a Scarf-managed block into `<project>/AGENTS.md` between `<!-- scarf-project:begin -->` and `<!-- scarf-project:end -->` markers, so Hermes's automatic context-file load picks up the project's identity.

Hermes reads a context file from the session's cwd at startup, picking the first match in this priority order: `.hermes.md` → `HERMES.md` → `AGENTS.md` → `CLAUDE.md` → `.cursorrules`. Each is capped at 20 KB. Scarf's managed block contains:

- Project name + directory
- Dashboard and manifest paths
- Template id + version (for template-installed projects)
- Configuration field *names* (with type hints — `secret` fields marked as such, but **values never appear**)
- Cron jobs attributed to the project via the `[tmpl:<id>] …` prefix
- A reminder to preserve template-author content below the block

**Safe around hand-edits.** Everything outside the markers is left byte-identical on every refresh. Template-author AGENTS.md content lives safely below the block.

**Secret-safe.** Config values stored in the Keychain never appear — only field names. The block is safe to drop into any agent's context.

**Bare projects.** If you add a plain directory to Scarf (via the `+` button) and start a chat in it, Scarf creates a minimal `AGENTS.md` containing only the managed block. The agent still has identity-level project awareness even without a template.

**Known caveat.** If any parent directory of your project contains a `.hermes.md` or `HERMES.md` file, Hermes's priority order picks *those* up first and the project's AGENTS.md is shadowed. No fix in v2.3 — planned for v2.4 pending input on how to handle authored `.hermes.md` files.

The service backing all of this is `ProjectAgentContextService` in the main Scarf repo. Template authors: leave the `<!-- scarf-project -->` region alone in your bundled `AGENTS.md`, put template-specific instructions below it.

## Troubleshooting

**"The install sheet closes as soon as I click Continue on the Configure step."**
Fixed in v2.2.0. If you're seeing this, you're on an older dev build — update via Sparkle.

**"Run Now on a cron job shows Run failed but the dashboard updates a minute later anyway."**
Fixed in v2.2.0. The cron tick timeout was too short; Run Now now shows "Agent started — dashboard will update when it finishes" without blocking.

**"The Site tab shows a GitHub 404 instead of my configured site."**
Was a bug in the `awizemann/site-status-checker` template's pre-first-run placeholder URL. Fixed in v1.1.0 of that template. After install, the first cron run rewrites the URL to your first configured site.

**"I uninstalled the project but the folder is still on disk."**
Intentional. The uninstaller preserves files that weren't installed by the template — typically a `status-log.md` written by a cron job. The uninstall success screen lists the preserved paths. Delete the folder from Finder if you don't need the extra files.

**"I installed the same template twice and got an error."**
Expected — the installer refuses a re-install of the same template id into the same location to avoid double-appending to `MEMORY.md`. Uninstall the existing install first, or pick a different parent directory.

**"My template's cron job runs but uses relative paths that don't resolve."**
Use `{{PROJECT_DIR}}` in the cron prompt. Hermes doesn't set a CWD for cron runs, so relative paths resolve against the agent's own dir. The installer substitutes `{{PROJECT_DIR}}` with the absolute project path at install time.

## See also

- [Installation](Installation) — getting Scarf set up in the first place.
- [Projects & Profiles](Projects-and-Profiles) — the broader Projects feature that templates build on.
- [Memory & Skills](Memory-and-Skills) — what the "memory appendix" and "skills" sections of a template reference.
- [Gateway / Cron / Health / Logs](Gateway-Cron-Health-Logs) — cron lifecycle beyond just templates.
- [Release Notes Index](Release-Notes-Index) — v2.2.0 for the full launch notes.

---
_Last updated: 2026-05-08 — Scarf v2.7.5 (`kanban_summary` widget + per-project `kanbanTenant` manifest field; templates never ship the tenant — exporter strips it)_