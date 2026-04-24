# Template Author — Agent Instructions

This project is a help surface for the `scarf-template-author` Hermes skill. The same instructions apply whether you're Claude Code, Cursor, Codex, Aider, or any other agent that reads `AGENTS.md`.

## What this project is

Two things:

1. A minimal dashboard (`.scarf/dashboard.json`) the user lands on after install. It's a Quick Start text widget + an empty list widget. The list is an optional scratchpad where you can log projects you've scaffolded for the user, giving them a running audit trail. That's nice-to-have, not mandatory.
2. A skill at `~/.hermes/skills/templates/awizemann-template-author/scarf-template-author/SKILL.md`. The skill is the real value — it teaches you how to interview the user and scaffold a new Scarf-compatible project.

## What this project is NOT

- Not a running service. No cron jobs, no background tasks, no secrets.
- Not a dashboard you need to keep updated. The dashboard is documentation; the only mutation worth doing is appending to the Scaffolded Projects list after you scaffold something.

## When the user asks to create a Scarf project

The primary trigger. Phrases that should activate the full scaffolding flow:

- "Create a new Scarf project that …"
- "Scaffold a dashboard for …"
- "Set up a project to watch / track / report on …"
- "Help me author a Scarf template."
- "Build me a project that runs daily and …"

When you hear those:

1. Load the skill at `~/.hermes/skills/templates/awizemann-template-author/scarf-template-author/SKILL.md` and follow its interview flow. Do not improvise — the skill encodes the specific invariants Scarf enforces (widget types, field-type constraints, the `{{PROJECT_DIR}}` token, the paused-on-install cron rule, the secret-fields-have-no-defaults rule).
2. Scaffold into a directory the user picks. Use absolute paths.
3. After writing files, tell the user to register the project: click **+** in Scarf's Projects sidebar and pick the directory. Do not try to edit `~/.hermes/scarf/projects.json` yourself — Scarf reloads the registry on its own and the UI path is safer.
4. Optionally append to the Scaffolded Projects list in this project's `dashboard.json` so the user has a local record of what you've built for them. Preserve every other field in the dashboard as-is.

## When the user asks reference questions

If the user asks something like "what widget types does Scarf support?" or "how do I add a secret field?", you don't need to scaffold anything — answer inline. The skill's reference sections cover:

- The seven widget types (`stat`, `progress`, `text`, `table`, `chart`, `list`, `webview`) and their required fields.
- The seven config field types (`string`, `text`, `number`, `bool`, `enum`, `list`, `secret`) and their constraint keys.
- The `AGENTS.md` contract that every scaffolded project should honour.

Point them at the skill file if they want to read it directly. It's ~400 lines of structured markdown.

## What not to do

- Don't scaffold without asking the user where the project should live. The interview always asks for a parent directory.
- Don't register secrets in `<project>/.scarf/config.json`. Secret field values go through the macOS Keychain at install time; `config.json` stores `keychain://…` URIs, never plaintext. A scaffolded project that hasn't been installed yet has no secrets on disk at all.
- Don't claim dashboard widget titles the cron job doesn't actually update. The scaffolded `AGENTS.md` is a contract — if it says "the cron updates Sites Up / Sites Down", the cron prompt must match.
- Don't skip `{{PROJECT_DIR}}` token substitution in cron prompts. Hermes doesn't set a CWD for cron runs, so relative paths resolve against the agent's own dir — the installer swaps `{{PROJECT_DIR}}` for the absolute project path at install time.

## Reference

- `SKILL.md` at `~/.hermes/skills/templates/awizemann-template-author/scarf-template-author/SKILL.md` — the full scaffolding playbook.
- [Project Templates wiki page](https://github.com/awizemann/scarf/wiki/Project-Templates) — user-facing docs.
- [`awizemann/site-status-checker`](https://awizemann.github.io/scarf/templates/awizemann-site-status-checker/) — a complete working example covering dashboard stats, a configurable list, a cron job, a Site-tab webview, and a full AGENTS.md contract. Read it when you're unsure how a piece should look.
