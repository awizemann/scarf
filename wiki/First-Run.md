---
title: First-Run
type: note
permalink: scarf-wiki/first-run
created: 2026-05-29
updated: 2026-05-29
---

# First Run

> **Looking for ScarfGo's first run?** The iOS app has a multi-step onboarding flow (host details → SSH key generation → paste public key → connection test). See [ScarfGo Onboarding](ScarfGo-Onboarding) for the walkthrough. This page covers the macOS app.

The first time you launch Scarf, it opens a single window bound to your local Hermes install at `~/.hermes/`. That window is automatic — there is no setup screen.

## What Scarf expects

For the local server window to work, Hermes must be installed at `~/.hermes/` with at least:

- `~/.hermes/state.db` — SQLite database (created automatically by Hermes on first run).
- `~/.hermes/config.yaml` — runtime config.
- The `hermes` CLI on your `$PATH` (Scarf checks `~/.local/bin/hermes`, `/opt/homebrew/bin/hermes`, `/usr/local/bin/hermes`, and `~/.hermes/bin/hermes` as fallbacks).

If `~/.hermes/` is missing or empty, the Dashboard will tell you so. Install Hermes first per the [Hermes README](https://github.com/hermes-ai/hermes-agent), then relaunch Scarf.

## What you'll see

The window opens to the **Dashboard** — system health, token usage, recent sessions. The sidebar on the left has four groups:

- **Monitor** — Dashboard, Insights, Sessions, Activity
- **Interact** — Chat, Memory, Skills
- **Configure** — Platforms, Personalities, Quick Commands, Credential Pools, Plugins, Webhooks, Profiles, Servers
- **Manage** — Tools, MCP Servers, Gateway, Cron, Health, Logs, Settings

Click any item to open it. Selection lives in `AppCoordinator` — see [Sidebar & Navigation](Sidebar-and-Navigation) for the full list with icons.

## Adding a remote server

To open a window against a remote Hermes install, use **File → Open Server… → Add Server**. You'll need:

- Hostname or alias (resolved via your `~/.ssh/config`)
- Optional user, port, identity file, remote home, and Hermes binary hint

See [Servers & Remote](Servers-and-Remote) for prerequisites on the remote host (`sqlite3`, `pgrep`, SSH key auth, readable `~/.hermes/`).

## Multiple windows

Each Scarf window is bound to exactly one server. Open as many windows as you want — they run with independent state and can be tiled side-by-side.

ScarfGo on iOS uses a single-window 5-tab layout instead — see [Sidebar & Navigation](Sidebar-and-Navigation) for the cross-platform navigation comparison.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (cross-linked ScarfGo onboarding + iOS nav)_