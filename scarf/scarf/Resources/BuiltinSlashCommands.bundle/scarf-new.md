---
name: scarf-new
description: Create a brand-new Scarf project — invokes the scarf-template-author skill interview
argumentHint: <optional one-line description>
version: 1.0.1
---

SKILL: scarf-template-author

The user wants to create a new Scarf project. Run the `scarf-template-author` skill interview now.

If the user gave an argument with this command, treat it as their answer to the skill's first question ("In one sentence — what does this project do?") and skip ahead to question 2.

User's optional one-liner: {{argument | default: "(none — start at question 1)"}}

The skill lives at `~/.hermes/skills/scarf/scarf-template-author/SKILL.md` and documents the full interview flow, the widget catalog, the config-schema field types, and the export-to-template contract. Follow it.

Once you've gathered enough to scaffold:

1. Create the project directory (the user will tell you where, or default to `~/Projects/<slug>`).
2. Write `<project>/.scarf/dashboard.json` with the widgets you agreed on.
3. Write `AGENTS.md` with project-specific instructions BELOW the `<!-- scarf-project -->` marker region (never edit inside the markers — Scarf rewrites that on every project-scoped chat start).
4. If the project takes user-supplied inputs (URLs, API tokens, etc.), also write `<project>/.scarf/manifest.json` with a `config.schema`.
5. If the project needs scheduled refresh, run `hermes cron create --workdir <project.path> …` to register a job.
6. Register the project: if the `scarf-projects` MCP tools are available, prefer `project_register` (`name`, `path`) — it's the same code Scarf's UI runs and refuses malformed input instead of corrupting the registry. Only if those tools are NOT available, fall back to editing `~/.hermes/scarf/projects.json` by hand: append a `{ "name": "<project-name>", "path": "<absolute-project-dir>" }` entry to the `projects` array (create the file with `{ "projects": [...] }` if missing). Scarf picks up the change on next sidebar refresh, then tell the user where the project landed.

Confirm the project is ready, then suggest they open a chat scoped to it for further work.
