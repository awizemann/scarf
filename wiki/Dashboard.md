---
title: Dashboard
type: note
permalink: scarf-wiki/dashboard
created: 2026-05-29
updated: 2026-05-29
---

# Dashboard

The Dashboard is the default landing view of every window. It answers four questions at a glance: **Is Hermes running?** **What's it cost me?** **What did it just do?** **Is anything broken?**

## Layout

A scrolling stack of cards, refreshed automatically when `~/.hermes/state.db`, `config.yaml`, or the logs change ([HermesFileWatcher](Core-Services) handles the reload).

| Card | Source | What it shows |
|---|---|---|
| **Hermes Process** | `pgrep` (local) or `ssh host pgrep` (remote) | Running / stopped, PID, uptime. Start/stop/restart buttons. |
| **Token Usage** | `state.db` aggregations across all sessions | Input + output + cache + reasoning tokens; period selector (7/30/90 days / all). |
| **Cost Tracking** | Per-session `actual_cost_usd` (v0.7+) or `estimated_cost_usd` | Total spend in the period, broken down by model when available. |
| **Recent Sessions** | `sessions` table, ordered by `started_at DESC` | Last N sessions with title, source platform, message count, duration. Click to drill into [Sessions](Insights-and-Activity). |
| **Active Platforms** | Parsed from `config.yaml` | Which messaging platforms are configured and their connection status. |
| **Status** | `lastOpenError` from `HermesDataService` | Surfaced when the database can't be read (missing `sqlite3` on remote, permission denied, etc.). Links to [Health](Gateway-Cron-Health-Logs) for diagnostics. |

## Live refresh

Local windows watch `~/.hermes/` with FSEvents (`DispatchSourceFileSystemObject`). Remote windows poll mtimes every 3 seconds over the SSH ControlMaster. Either way, the Dashboard updates without needing a manual refresh — open it on a second monitor and watch sessions tick by as Hermes works.

### Project dashboards (v2.7+)

Per-project dashboards (the **Projects** sidebar item, separate from this system Dashboard) refresh on a project-wide watch: any change anywhere under `<project>/.scarf/` triggers a reload, not just `dashboard.json` itself. So a `markdown_file` widget pointing at `reports/weekly.md` (placed under `.scarf/reports/`) refreshes automatically when the cron job rewrites it. The same coverage applies on remote SSH-attached projects via 3-second mtime polling on each project's `.scarf/` directory. _Limitation:_ in-place appends to an existing file (`>> file.log`) don't tick the watcher — write atomically (write-temp + rename) or `touch dashboard.json` after each cron run.

## Status pill in the toolbar

Every Scarf window has a connection pill in the toolbar showing the bound server and its state:

- **Local** — green dot, "Local" label.
- **Remote (healthy)** — green dot, server name.
- **Remote (degraded)** — yellow dot, "Can't read Hermes state" — opens a diagnostics sheet that runs 14 checks in one SSH session (connectivity, `sqlite3` presence, read access on `config.yaml`/`state.db`, effective non-login `$PATH`).
- **Remote (failed)** — red dot, error message.

## When something looks wrong

- **"Hermes not running"** — start Hermes from a terminal, or click the Start button.
- **Empty cards** — `~/.hermes/state.db` is missing or unreadable. See [First Run](First-Run).
- **Token/cost are zero but you've used Hermes** — the schema may predate v0.7. Update Hermes; Scarf detects the new columns automatically.
- **Yellow "Can't read Hermes state" pill on remote** — open Manage Servers → Run Diagnostics. Each failed check explains why and how to fix.

## ScarfGo Dashboard (iOS, v2.5+)

ScarfGo's Dashboard is a slimmer take: a stats grid (Sessions / Messages / Tool Calls / Tokens) over a recent-sessions card, plus a Sessions sub-tab with a project filter Menu. Swipe the row to resume a session. The Hermes Process / Gateway / Active Platforms cards are Mac-only — they read state Hermes doesn't yet expose remotely in a phone-friendly way. See [Platform Differences](Platform-Differences) for the full Mac vs iOS feature matrix.

A **Switch server** button in the iOS Dashboard's top-right corner (added v2.5) returns you to the Servers list without first navigating to the System tab — handy when you have multiple Hermes hosts configured.

## Related pages

- [Insights & Activity](Insights-and-Activity) for deeper analytics.
- [Chat](Chat) for talking to the running Hermes.
- [Servers & Remote](Servers-and-Remote) for adding remote hosts and the diagnostics flow.
- [ScarfGo](ScarfGo) for the iOS Dashboard tour.

---
_Last updated: 2026-05-04 — Scarf v2.7 (project-wide auto-refresh on `.scarf/` directory)_