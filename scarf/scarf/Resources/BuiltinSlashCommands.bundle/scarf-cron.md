---
name: scarf-cron
description: Schedule a recurring Hermes cron job for the active project
argumentHint: <what the job should do, e.g. "fetch latest hn comments daily">
version: 1.1.0
---

The user wants to register a scheduled (cron) job for the active Scarf project. The active project's path and its cron naming rule are in the Scarf-managed `<!-- scarf-project:begin -->` block of AGENTS.md; read it first. If no project is active, ask which project the job belongs to (or whether they want a global job).

User's request: {{argument | default: "(no specifics yet — ask the user what the job should do and how often)"}}

What you need from the user:

1. **What the job does** — the prompt the agent will receive on each run. Make it self-contained: the job runs with no memory of this chat.
2. **Schedule** — Hermes accepts a cron expression (`"0 9 * * 1-5"`), an interval (`"30m"`, `"every 2h"`), or a one-shot timestamp. If the user speaks in plain words ("every weekday at 9am"), turn that into a cron expression yourself and confirm it with them. Cron times are in the Hermes host's timezone (`HERMES_TIMEZONE` or config `timezone`, else the server's local time).
3. **Delivery** — where results land: `local` (keep the output on the host only), a platform such as `telegram`, `discord` or `signal`, or `platform:chat_id` for a specific chat. Leave it out to use Hermes's default.
4. **(Optional) Model** — the global default is used otherwise.

Then run (the schedule and the prompt are positional, in that order, after the options):

```bash
hermes cron create \
  --name "[proj:<project id>] <short descriptive name>" \
  --workdir "<project.path>" \
  --deliver "<delivery>" \
  "<schedule>" \
  "<the prompt>"
```

Start the name with the project's `[proj:<id>]` prefix exactly as the AGENTS.md block gives it. Scarf attributes cron jobs to a project only by that prefix, so without it the job never shows up in the project's cron panel and isn't paused when the project is archived.

Always pass `--workdir <project.path>` for a project-scoped job. It makes the spawned agent inherit AGENTS.md and the dashboard, and resolve relative paths against the project's files. Without it the job runs against `$HOME` and the project context is lost.

Omit `--deliver` rather than guessing a target. Options vary by Hermes version, so if a flag is rejected run `hermes cron create --help` and adjust.

Confirm the job landed by running `hermes cron list` and reporting the new entry to the user. Mention they can see and manage it in Scarf's Cron sidebar.
