---
name: scarf-export
description: Prepare the active project for export as a .scarftemplate bundle
version: 1.0.1
---

The user wants to package the active Scarf project as a shareable `.scarftemplate` bundle. The active project's path is in the `<!-- scarf-project -->` AGENTS.md block; read it first.

A `.scarftemplate` bundle is a zip containing:

- `template.json` — the manifest (id, name, version, `contents` claim, optional `config.schema`)
- `README.md` — shown in the install preview sheet
- `AGENTS.md` — required; cross-agent project instructions (the agents.md standard). Leave the `<!-- scarf-project -->` marker region intact — Scarf rewrites it on each install.
- `dashboard.json` — copied to `<project>/.scarf/dashboard.json`
- `instructions/…` — optional per-agent shims (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.github/copilot-instructions.md`)
- `skills/<name>/…` — optional bundled skills
- `cron/jobs.json` — optional pre-registered jobs (`[tmpl:<id>] [proj:<project-id>]` name prefix is auto-added on install; they install paused)
- `memory/append.md` — optional MEMORY.md appendix; Scarf adds it as its own memory entry between `<!-- scarf-template:<key>:begin/end -->` markers (the key is a hash of the template id)

Do NOT bundle:
- `config.yaml`, `auth.json`, session files, credentials
- Resolved secret values from `<project>/.scarf/config.json` (only the schema)
- Anything under `.scarf/template.lock.json` (that's install-side, not author-side)

Workflow:

1. Read `<project>/.scarf/manifest.json` if it exists; note any `config.schema` to forward.
2. Make sure `AGENTS.md`, `dashboard.json`, and `README.md` are present and clean (no debug content, no machine-specific paths).
3. Tell the user about Scarf's built-in Export flow: right-click the project in Scarf's Projects sidebar → "Export as Template…". The export sheet generates `template.json` from the project's current state and produces a `.scarftemplate` zip.
4. If they want to inspect what'll be exported BEFORE running the GUI flow, walk them through what `ProjectTemplateExporter` would include based on the current project files.

The full author playbook is at `~/.hermes/skills/scarf/scarf-template-author/SKILL.md` — reference its widget-catalog + config-schema sections when validating field types.
