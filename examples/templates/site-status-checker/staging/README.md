# Site Status Checker

A minimal uptime watchdog that pings a list of URLs once a day, records pass/fail results, and keeps a simple Scarf dashboard up to date.

## What you get

- **`sites.txt`** — one URL per line. This is the source of truth for what the cron job checks. Edit it to add or remove sites.
- **`status-log.md`** — the agent's append-only log of check results. New runs append a section at the top.
- **`.scarf/dashboard.json`** — Scarf dashboard with live stat widgets (sites up, sites down, last checked), the full list of watched sites with their last-known status, and a usage guide.
- **Cron job `Check site status`** — registered (paused) by the installer; tag `[tmpl:awizemann/site-status-checker]`. Runs daily at 9:00 AM when enabled. The prompt tells the agent to read `sites.txt`, check each URL, write results to `status-log.md`, and update the stat widgets in `dashboard.json`.

## First steps

1. Open the **Cron** sidebar and enable the `[tmpl:awizemann/site-status-checker] Check site status` job. It's paused on install so nothing runs without your explicit say-so.
2. Edit `sites.txt` in your project root — replace the two placeholder URLs with the sites you actually want to watch.
3. From the project's dashboard, ask your agent to run the job now: "Run the site status check and update the dashboard."
4. Future runs happen automatically at 9 AM daily.

## Customizing

- **Change the schedule.** Edit the cron job in the Cron sidebar — the schedule field accepts `30m`, `every 2h`, or standard cron expressions like `0 9 * * *`.
- **Change what "down" means.** By default the agent treats any non-2xx HTTP response as down. If you want to check for specific strings in the body (e.g. "Maintenance"), tell the agent in `AGENTS.md` and it will adapt.
- **Add alerting.** Set a `deliver` target on the cron job (Discord, Slack, Telegram) — the agent will post the run summary there instead of just writing to `status-log.md`.

## Uninstalling

Templates don't auto-uninstall in Scarf 2.2. To remove this one by hand:

1. Delete this project directory (removes the dashboard, AGENTS.md, sites.txt, status-log.md).
2. Remove the project entry from the Scarf sidebar (click the `−` next to the project name).
3. Delete the `[tmpl:awizemann/site-status-checker] Check site status` cron job from the Cron sidebar.

No memory appendix or skills were installed, so nothing else needs cleanup.
