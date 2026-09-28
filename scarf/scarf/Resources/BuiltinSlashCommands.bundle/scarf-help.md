---
name: scarf-help
description: Explain what Scarf can do — features, slash commands, and where to look
version: 1.1.0
---

The user is asking what Scarf — the macOS GUI hosting this chat — can do. Give them a concise, scannable tour of the major features, then ask which area they want to dig into.

Cover at minimum:

- **Projects** — registered folders with a typed `dashboard.json` (the Projects tab renders the widgets), optional `manifest.json` with a config schema, and a managed AGENTS.md block that gives every chat in the project the right context. Created via the toolbar's "New Project from Scratch…" wizard or by installing a `.scarftemplate` bundle.
- **Dashboard widgets** — `stat`, `progress`, `text`, `table`, `chart`, `list`, `webview`, `markdown_file`, `log_tail`, `cron_status`, `image`, `status_grid`, `kanban_summary`. Live in `<project>/.scarf/dashboard.json`. Full schema at `~/.hermes/skills/scarf/scarf-template-author/SKILL.md`.
- **Kanban** — per-project board (auto-tagged via tenant) + chat-scoped filter so the user sees "tasks from THIS chat".
- **Model presets** — bind a `(model, provider)` to a specific project; Scarf calls `session/set_model` on session start so the chat boots on the right model.
- **Slash commands** — the `/scarf-*` family (this one included) is shipped globally; per-project commands live at `<project>/.scarf/slash-commands/<name>.md` and add to the slash menu when a project chat is open.
- **Cron + Messaging Gateway + MCP servers + Plugins + Profiles** — all configurable from the sidebar under Manage and Configure.
- **Export as template** — once a project's `dashboard.json`, optional config schema, and AGENTS.md are stable, right-click the project → "Export as Template…" to make a shareable `.scarftemplate` bundle.

Then ask: *"Which area do you want to dig into first?"*

Keep the response under ~300 words; this is a tour, not a manual.
