# Scarf Template Author

A Hermes skill that teaches your agent how to scaffold a new Scarf project — and, because Scarf's `.scarftemplate` format is symmetric with a live project on disk, how to shape it so you can publish it to the catalog later if you want.

## What you get

Installing this template drops a skill at `~/.hermes/skills/templates/awizemann-template-author/scarf-template-author/SKILL.md` and a minimal "how to use" project in a folder of your choice. Every agent that reads the standard `~/.hermes/skills/` directory — Claude Code, Cursor, Codex, Aider, and the rest of the [agents.md](https://agents.md/) family — picks the skill up automatically.

## How to use it

After install, open your agent in any directory and say something like:

- *"Create a new Scarf project that watches the number of open PRs in my GitHub repo."*
- *"Scaffold a Scarf dashboard that tracks daily focus time from my Toggl logs."*
- *"Set up a project that runs a cron job to summarise my inbox each morning."*
- *"Help me author a Scarf template I can share."*

The agent will ask four or five questions (purpose, data source, cadence, what to display, any secrets) and then write:

- `<your-dir>/.scarf/dashboard.json`
- `<your-dir>/.scarf/manifest.json` — only if you're going to use a configuration form or want to export later
- `<your-dir>/AGENTS.md`
- `<your-dir>/README.md`
- Optionally a cron job registered via `hermes cron create` (always created paused — you enable it from Scarf's Cron sidebar when ready).

When it's done, click **+** in Scarf's Projects sidebar and pick the directory. Your dashboard appears. Iterate on it by asking your agent to tweak widgets or add fields.

## Turning a local project into a shareable template

Once you're happy with the result, Scarf → Projects → Templates → *Export "&lt;name&gt;" as Template…* produces a `.scarftemplate` anyone can install. The exporter carries the configuration *schema* but never your filled-in values — so your secrets and personal settings stay local.

## About this template's own dashboard

The installed project itself is tiny — a single Quick Start text widget and an empty list widget meant to serve as a scratchpad for tracking which scaffolded projects you've created. Its only purpose is to give you a place to land after install and a reminder of the trigger phrases above. The real value is the skill.

## Reference

- [Project Templates wiki page](https://github.com/awizemann/scarf/wiki/Project-Templates) — full spec + troubleshooting.
- [`awizemann/site-status-checker`](https://awizemann.github.io/scarf/templates/awizemann-site-status-checker/) — a complete, non-trivial example the skill studies and references.
- Dashboard / configuration schemas are Swift-authoritative at `scarf/scarf/Core/Models/ProjectDashboard.swift` and `scarf/scarf/Core/Models/TemplateConfig.swift` in the Scarf repo.

## What this template intentionally is not

- Not an archetype picker. v1 is blank-slate conversational; pre-baked starters (`monitor`, `dev-dashboard`, `personal-log`, etc.) may land in v1.1 once we see what shapes people ask for most often.
- Not a graphical wizard. The conversational agent path is strictly richer than a fixed form, and dogfoods Scarf's agent-first philosophy.
- Not a remote-scaffolding tool. It writes files into a directory on the machine where the agent runs; pair with Scarf's remote-server mode if you want to scaffold onto another box.
