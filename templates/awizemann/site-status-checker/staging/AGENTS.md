# Site Status Checker — Agent Instructions

This project maintains a daily uptime check for a list of URLs the user configured during install. The same instructions apply whether you're Hermes, Claude Code, Cursor, Codex, Aider, or any other agent that reads `AGENTS.md`.

## Project layout

- `.scarf/config.json` — **the source of truth for what to check.** Written by Scarf's install/configure UI; holds a `values.sites` field (a JSON array of URL strings) and a `values.timeout_seconds` field (a number, default 10).
- `.scarf/manifest.json` — cached copy of `template.json`, used by Scarf's Configuration editor to re-render the form. Don't modify.
- `status-log.md` — append-only markdown log. Newest run at the top. Each run is a section with the ISO-8601 timestamp as the heading. Created on the first run if it doesn't exist.
- `.scarf/dashboard.json` — Scarf dashboard. **Only the `value` fields of the three stat widgets and the `items` array of the "Watched Sites" list widget should be updated.** The section titles, widget types, and structure must stay intact.

## How configuration works

The user configures this project through Scarf's UI — not by editing files directly. On install, a form asked them for the list of sites and a request timeout; those values landed in `.scarf/config.json`. They can edit those values any time via the **Configuration** button on the project dashboard header.

Read configuration like this (JSON, via whatever file-read tool you have):

```
cat .scarf/config.json
# → { "values": { "sites": ["https://foo.com", "https://bar.com"],
#                 "timeout_seconds": 10 }, ... }
```

**Never** edit `.scarf/config.json` yourself. If the user asks "add a site" in chat, tell them to open the Configuration button on the dashboard. (A future Scarf release may expose a tool for agents to write config programmatically; until then, configuration is a user action.)

## First-run bootstrap

If `status-log.md` doesn't exist, create it with a one-line header:

```
# Site Status Log

Newest run at the top. Each section is a single check.
```

No `sites.txt` anymore — sites come from `.scarf/config.json`.

## What to do when the cron job fires

The cron job runs this project's "Check site status" prompt. When invoked:

1. Read `.scarf/config.json`. Extract `values.sites` (array of URLs) and `values.timeout_seconds` (number). If `sites` is empty or missing, write a `status-log.md` entry noting "no sites configured — open Configuration to add some" and leave the dashboard untouched.
2. For each URL in `sites`, make an HTTP GET request with the configured timeout. Follow up to 3 redirects. Treat any 2xx or 3xx response as **up**, anything else (including timeouts and DNS failures) as **down**.
3. Build a results table: URL, status (up/down), HTTP code (or error reason), response time in milliseconds.
4. Prepend a new section to `status-log.md`:
   ```
   ## <ISO-8601 timestamp>

   | URL | Status | Code | Latency |
   |-----|--------|------|---------|
   | … | up | 200 | 142 ms |
   | … | down | timeout | — |
   ```
5. Update `.scarf/dashboard.json`:
   - `Sites Up` stat widget: `value` = count of up results.
   - `Sites Down` stat widget: `value` = count of down results.
   - `Last Checked` stat widget: `value` = the ISO-8601 timestamp you just wrote.
   - `Watched Sites` list widget `items`: one entry per URL with `text` = URL and `status` = `"up"` or `"down"` (lowercase).
6. If the cron job has a `deliver` target set, emit a one-line summary (`3 up, 1 down — example.com timed out`) as the agent's final response so the delivery mechanism picks it up.

## What not to do

- Don't modify the structure of `dashboard.json` (section titles, widget types, widget titles, `columns`). Only the values listed above are writable.
- Don't edit `.scarf/config.json` — that's the user's responsibility via the Configuration UI.
- Don't truncate `status-log.md` — it's the historical record. If it grows past 1 MB, add a one-line note at the top of the file asking the user to archive it.
- Don't invent URLs or pull them from anywhere other than `values.sites`.
- Don't run browsers or headless Chrome. Plain HTTP GET is sufficient.

## When the user asks you things

- "What's the status of my sites?" — read the top section of `status-log.md` and summarize.
- "Add a site" / "Remove a site" — tell them: *"Click the Configuration button on the dashboard header (the slider icon, next to the folder). Add or remove the URL there and save. The next cron run will pick it up."* Don't try to edit config.json yourself.
- "Run the check now" — do everything in the cron flow above, then summarize the results in chat.
- "Why is [site] down?" — read the last 3–5 entries for that URL in `status-log.md` and report any pattern you see (consistent timeouts, intermittent 5xx, DNS failures, etc.). Don't speculate beyond what the log shows.
