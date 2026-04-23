# Site Status Checker

A minimal uptime watchdog that pings a list of URLs once a day, records pass/fail results, and keeps a simple Scarf dashboard up to date.

**Requires Scarf 2.3+** — this template uses the configuration feature (a form during install, and a Configuration button on the dashboard for editing later).

## What you get

- **Configurable site list** — you tell Scarf which URLs to watch during install, via a form. No file editing required. Edit the list later via the **Configuration** button on the project dashboard (slider icon next to the folder).
- **Configurable timeout** — how long to wait per URL before giving up, also set via the form.
- **`.scarf/config.json`** — where your configured values land. The agent reads this at run time; you never need to open it by hand.
- **`status-log.md`** — the agent's append-only log of check results. New runs append a section at the top. Created automatically on first run.
- **`.scarf/dashboard.json`** — Scarf dashboard with live stat widgets (sites up, sites down, last checked), the full list of watched sites with their last-known status, and a usage guide.
- **Cron job `Check site status`** — registered (paused) by the installer; tag `[tmpl:awizemann/site-status-checker]`. Runs daily at 9:00 AM when enabled. Reads your configured sites + timeout, hits each URL, writes results to `status-log.md`, and updates the dashboard.

## First steps

1. During install, fill in the Configuration form: add the URLs you want to watch and (optionally) adjust the timeout. Hit Continue, then Install.
2. After install, open the **Cron** sidebar and enable the `[tmpl:awizemann/site-status-checker] Check site status` job. It's paused on install so nothing runs without your explicit say-so.
3. From the project's dashboard, ask your agent to run the job now: *"Run the site status check and update the dashboard."*
4. Future runs happen automatically at 9 AM daily.

## Changing sites or timeout later

Click the **Configuration** button (slider icon, dashboard toolbar) to re-open the form pre-filled with your current values. Add, remove, or edit URLs. Save. The next cron run picks up the changes.

## Customizing

- **Change the schedule.** Edit the cron job in the Cron sidebar — the schedule field accepts `30m`, `every 2h`, or standard cron expressions like `0 9 * * *`.
- **Change what "down" means.** By default the agent treats any non-2xx/3xx HTTP response as down. If you want to check for specific strings in the body (e.g. "Maintenance"), tell the agent in `AGENTS.md` and it will adapt.
- **Add alerting.** Set a `deliver` target on the cron job (Discord, Slack, Telegram) — the agent will post the run summary there instead of just writing to `status-log.md`.

## Recommended model

`claude-haiku-4` works well — this is a simple tool-use task (HTTP GETs + a short summary). Haiku keeps costs low when the cron runs daily. The recommendation appears in the Configuration form; Scarf doesn't auto-switch your active model, so adjust via Settings if you'd like.

## Uninstalling

Right-click the project in the sidebar → **Uninstall Template…** (or click the shippingbox icon on the dashboard header). Scarf walks you through exactly what's about to be removed: template-installed files in the project dir, the `[tmpl:…]` cron job, and the Configuration values you entered (`config.json` + Keychain items for any secrets — though this template has none). User-created files (like `status-log.md`) are preserved.
