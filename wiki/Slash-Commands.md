---
title: Slash-Commands
type: note
permalink: scarf-wiki/slash-commands
created: 2026-05-29
updated: 2026-06-02
---

# Slash Commands (project-scoped + global)

Scarf surfaces three layers of slash commands in the chat menu:

1. **ACP-advertised** — whatever Hermes pushes via `available_commands_update` after `session/new` (`/clear`, `/compact`, `/cost`, `/model`, `/tools`, `/reload-skills`, `/help`, `/exit`, plus capability-gated `/goal`, `/queue`, `/subgoal`, `/yolo`, `/sessions`, `/codex-runtime`).
2. **Project-scoped** — `.md` files you author at `<project>/.scarf/slash-commands/`. Available only in chats scoped to that project. Win over global commands of the same name.
3. **Global `/scarf-*` commands** (v2.10.1+) — bundled Scarf-specific commands installed to `~/.hermes/scarf/slash-commands/` on launch. Available in **every** chat (pre-session, global, project-scoped). Documented below under "Bundled global commands".

All three are Scarf primitives expanded client-side and forwarded as a plain `session/prompt`; the agent only sees the rendered body with a `<!-- scarf-slash:<name> -->` marker. Hermes has no project-scoped slash-command concept of its own. Works uniformly on Mac + iOS, local + remote SSH, against any Hermes version.

## Bundled global commands (v2.10.1+)

Scarf ships six `/scarf-*` commands inside the app bundle. On every launch, `SlashCommandBootstrapService` copies them into `~/.hermes/scarf/slash-commands/` if missing OR if the bundled version is newer than the installed one. Hand-edits to a newer version number (e.g. you bump your local copy to `1.5.0`) are preserved.

| Command | What it does |
|---|---|
| `/scarf-new <one-liner>` | Kicks off the `scarf-template-author` skill interview to scaffold a new Scarf project from scratch. The one-liner (optional) is threaded as the answer to interview question 1. |
| `/scarf-help` | Concise tour of Scarf's feature surface (dashboard widgets, Kanban, model presets, slash commands, cron, etc.) and where to dig in next. |
| `/scarf-dashboard <change>` | Design or edit the active project's `dashboard.json`. Reads the active project from the chat's `<!-- scarf-project -->` AGENTS.md block; asks the user if no project is active. |
| `/scarf-widget <kind>` | Add a single widget to the active dashboard. Narrower scope than `/scarf-dashboard` — surgical add, doesn't redesign the file. |
| `/scarf-cron <description>` | Schedule a recurring `hermes cron` job for the active project. Walks the user through prompt, schedule, delivery channel, and registers the job with `--workdir <project.path>` so the spawned agent inherits AGENTS.md. |
| `/scarf-export` | Prepare + run the `.scarftemplate` export of the active project. Lists what the export will include (and exclude — secrets, session files, machine-specific paths) before pointing the user at Scarf's right-click → "Export as Template…" flow. |

Per-project commands of the same name win — author a `<project>/.scarf/slash-commands/scarf-help.md` and it overrides the bundled one for that project's chats. Use this when a project needs a domain-specific `/scarf-help` (e.g. for a template that has its own Getting Started pattern).

The bundled commands carry a `version: x.y.z` frontmatter field that drives the bootstrap upgrade decision — see the [Updating](Updating) page for how the version-gated overwrite works in practice. The same pattern applies to bundled skills (Scarf's `SkillBootstrapService` installs `scarf-template-author` into `~/.hermes/skills/scarf/` with the same semantics).

## Project-scoped commands

A project can ship its own slash commands — reusable prompt templates as Markdown files at `<project>/.scarf/slash-commands/<name>.md` with YAML frontmatter. Invoke as `/<name> [args]` from chat; Scarf substitutes `{{argument}}` placeholders in the body and sends the expanded prompt to Hermes.

## File format

```markdown
---
name: audit-prs
description: Summarize open pull requests on the active branch
argumentHint: "<repo or 'current'>"
model: claude-sonnet-4.5
tags: [git, summary]
---

You are auditing open pull requests for **{{argument | default: "the current repo"}}**.

For each PR:
1. Title + author + age
2. One-line summary of the diff
3. Status (mergeable, conflicts, draft, blocked on review)

Output as a Markdown table sorted by age (oldest first).
```

Front matter fields:

| Key | Required | Type | Purpose |
|---|---|---|---|
| `name` | yes | string | The slash. Lowercase, dashes-allowed, no spaces. Must match the filename minus `.md`. |
| `description` | yes | string | Single-line summary for the slash menu. |
| `argumentHint` | no | string | Display hint shown in the slash menu after the name (e.g. `<topic>`). |
| `model` | no | string | Override the active model just for this command's expansion. Use the same provider/model identifier the model picker uses. |
| `tags` | no | string[] | Free-form tags for grouping in the slash menu. |

Body is plain Markdown. Two substitution patterns:

- `{{argument}}` — replaced with whatever the user typed after `/<name>`. If they typed nothing, the placeholder stays literal.
- `{{argument | default: "fallback"}}` — replaced with the user's input, OR the fallback when input is empty.

Multi-argument support is **not** in v2.5 — `argument` is a single string. Future-versioned slash commands may add `{{arg1}}` / `{{arg2}}`; current bundles ignore unknown placeholders.

## Authoring (Mac)

Mac per-project view gains a **Slash Commands** tab alongside Dashboard / Site / Sessions. List, add, edit, duplicate, delete commands. The editor includes a live preview pane that shows the expanded prompt with a sample-argument field so authors see exactly what Hermes will receive.

Workflow:

1. **Projects sidebar → pick a project → Slash Commands tab.**
2. **+ New** → fill in name, description, optional argumentHint and model, then write the body.
3. **Sample argument** field — type a value to preview the expansion.
4. **Save** writes the file to `<project>/.scarf/slash-commands/<name>.md`.

Files are plain Markdown, so you can also author them outside Scarf — any editor works. Scarf watches the directory and refreshes the menu live.

## Invoking (Mac + iOS)

In any chat scoped to that project, type `/`. The slash menu shows:

- **Hermes-advertised commands** (`/compress`, `/clear`, etc.) at the top.
- **User `quick_commands:` from `~/.hermes/config.yaml`** in the middle.
- **Project-scoped slash commands** at the bottom under a "**Project commands**" subheading.

Pick one with ↑/↓ + Enter or Tab. Commands with `argumentHint` insert a trailing space so you can start typing the argument immediately. Hit Enter again to send. Scarf expands the body, prepends the `<!-- scarf-slash:<name> -->` marker, and sends the result to Hermes.

iOS shows the same menu but as a sheet that slides up from the composer (touch targets too small for a popover). Same picking model: tap a row, fill in the argument field at the bottom, send.

## ScarfGo (iOS) — read-only browser

iOS ships in v2.5 as **read-only**. The chat-context bar grows a `<N> slash` chip when the project has slash commands; tap to browse them in a sheet. Multi-line markdown editing is a phone keyboard's nightmare, so v2.5 keeps Mac as the canonical editor; iOS catches up in v2.6+.

## AGENTS.md block extension

The Scarf-managed project context block written to `<project>/AGENTS.md` (between `<!-- scarf-project:begin -->` and `:end -->`) lists every available slash command so the agent can answer *"what slash commands does this project have?"* and recognise the `<!-- scarf-slash:<name> -->` marker prepended to expanded prompts.

The block is regenerated before each project-scoped session start, so adding a new command is reflected on the next chat without a separate refresh step.

## Packaging via `.scarftemplate` (schemaVersion 3)

Templates ship slash commands by:

1. Including `slash-commands/<name>.md` files at the bundle root.
2. Listing each name in `manifest.contents.slashCommands`.
3. Bumping `schemaVersion` to 3.

Example manifest:

```json
{
  "schemaVersion": 3,
  "id": "yourname/your-template",
  "name": "Your Template",
  "version": "1.2.0",
  "contents": {
    "dashboard": true,
    "agentsMd": true,
    "slashCommands": ["audit-prs", "summarize-week"]
  }
}
```

The installer copies the files to the project's `.scarf/slash-commands/` directory and tracks them in the lock file. **User-authored slash commands in the same directory survive uninstall** — only the template-shipped ones are removed.

The catalog validator (`tools/build-catalog.py`) enforces the same schema as the Swift verifier — invalid bundles fail PR CI before they hit the catalog. v1 and v2 templates remain byte-compatible; only bundles that ship slash commands need to bump to schemaVersion 3.

See [Project Templates](Project-Templates) for the full bundle format.

## Why a Scarf primitive (not a Hermes one)

Hermes already has a slash-command surface — `quick_commands:` in `~/.hermes/config.yaml`, plus whatever slashes the agent advertises via ACP's `available_commands_update`. Both are global to the host. Project-scoped commands need to live with the project, travel with it via templates, and not pollute the global namespace when many projects share a host.

Implementing them at the client makes the slash a pure UI concern: Hermes never knows the slash existed, just receives a normal prompt with a marker comment. The marker survives transcript export, AGENTS.md introspection, and resume — so the agent has audit context for what the user invoked even though the dispatch is client-side.

## Related pages

- [Project Templates](Project-Templates) — schemaVersion 3 packaging details.
- [Chat](Chat) — slash menu UX in context.
- [ScarfGo](ScarfGo) — iOS read-only browser.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (initial publication)_