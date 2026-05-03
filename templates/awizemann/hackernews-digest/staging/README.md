# HackerNews Daily Digest

A minimal news-aggregation project that fetches HackerNews top stories once a day, filters them by score and (optional) topic keywords, and keeps a rolling markdown log + a live Scarf dashboard.

**Requires Scarf 2.3+** — uses the Configuration form during install and on-demand re-edit.

## What you get

- **Configurable score threshold** — only stories at or above this score show up. HN front page averages ~150; lower it to widen the net, raise it to focus on the truly viral.
- **Configurable item cap** — keeps each digest from sprawling. Default 15.
- **Optional topic keywords** — a list of keywords (case-insensitive substring match against titles). Items that match a keyword get a `[topic]` tag in the digest and `"ok"` status in the dashboard list. Empty list = include every story above threshold, no highlighting.
- **No API keys** — HackerNews' Firebase API is fully public. Nothing in this project's `.scarf/config.json` is secret; no Keychain entries are created.
- **`digest.md`** — agent's append-only log. New runs prepend at the top. Created automatically on first run.
- **`.scarf/dashboard.json`** — live dashboard with stat widgets (top score, items tracked, last run) and a Top Stories list.
- **Cron job `Daily HN digest`** — registered (paused) by the installer; tag `[tmpl:awizemann/hackernews-digest]`. Runs daily at 8:00 AM when enabled.

## First steps

1. During install, fill in the Configuration form — set `min_score`, `max_items`, and any topic keywords you care about. (All have sensible defaults if you just want to skip it.) Hit Continue, then Install.
2. After install, open the **Cron** sidebar and enable the `[tmpl:awizemann/hackernews-digest] Daily HN digest` job. It's paused on install so nothing runs without your explicit say-so.
3. From the project's dashboard, ask your agent to run the job now: *"Run the HN digest and update the dashboard."*
4. Future runs happen automatically at 8 AM daily.

## Changing filters later

Click the **Configuration** button (slider icon, dashboard toolbar) to re-open the form pre-filled with your current values. Adjust score, max items, or topics. Save. The next cron run picks up the changes.

## Customizing

- **Change the schedule.** Edit the cron job in the Cron sidebar — accepts `30m`, `every 2h`, or standard cron expressions like `0 8 * * *`.
- **Switch sources.** This template is HN-only by design. To pull from Lobsters, Reddit, or RSS, fork it (export from a Scarf project, edit `cron/jobs.json`'s prompt, re-import) — most of the agent contract is generic.
- **Add alerting.** Set a `deliver` target on the cron job (Discord, Slack, Telegram) — the agent will post the run summary there instead of just writing to `digest.md`.

## Recommended model

`claude-haiku-4` works well — this is a simple HTTP-fetch + filter + markdown task. Haiku keeps costs low when the cron runs daily. The recommendation appears in the Configuration form; Scarf doesn't auto-switch your active model, so adjust via Settings if you'd like.

## Uninstalling

Right-click the project in the sidebar → **Uninstall Template…** (or click the shippingbox icon on the dashboard header). Scarf walks you through exactly what's about to be removed: template-installed files in the project dir, the `[tmpl:…]` cron job, and the configuration values you entered (`config.json`; this template stores no secrets so there's nothing in Keychain to clean up). User-created files (like `digest.md`) are preserved.
