# Site Status Checker — Agent Instructions

This project maintains a daily uptime check for a short list of URLs. The same instructions apply whether you're Hermes, Claude Code, Cursor, Codex, Aider, or any other agent that reads `AGENTS.md`.

## Project layout

- `sites.txt` — one URL per line. Lines starting with `#` are comments. This is the source of truth for what to check. **Not shipped with the template** — created on first run (see below).
- `status-log.md` — append-only markdown log. Newest run at the top. Each run is a section with the ISO-8601 timestamp as the heading. Also created on first run.
- `.scarf/dashboard.json` — Scarf dashboard. **Only the `value` fields of the three stat widgets and the `items` array of the "Watched Sites" list widget should be updated.** The section titles, widget types, and structure must stay intact.

## First-run bootstrap

If `sites.txt` doesn't exist in the project root, create it with this starter content and tell the user you did:

```
# One URL per line. Lines starting with # are comments.
# Replace these placeholders with the sites you want to watch.
https://example.com
https://example.org
```

If `status-log.md` doesn't exist, create it with a one-line header:

```
# Site Status Log

Newest run at the top. Each section is a single check.
```

## What to do when the cron job fires

The cron job runs this project's "Check site status" prompt. When invoked:

1. Read `sites.txt` in the project root. Ignore empty lines and `#`-prefixed comments. Expect plain URLs; be tolerant of whitespace around them.
2. For each URL, make an HTTP GET request with a 10-second timeout. Follow up to 3 redirects. Treat any 2xx or 3xx response as **up**, anything else (including timeouts and DNS failures) as **down**.
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
- Don't truncate `status-log.md` — it's the historical record. If it grows past 1 MB, add a one-line note at the top of the file asking the user to archive it.
- Don't invent URLs. If `sites.txt` is empty or missing, leave the dashboard untouched and write a single `status-log.md` entry noting "no sites configured."
- Don't run browsers or headless Chrome. Plain HTTP GET is sufficient.

## When the user asks you things

- "What's the status of my sites?" — read the top section of `status-log.md` and summarize.
- "Add a site" — append the URL to `sites.txt` on its own line. Don't sort or reorder existing entries. Confirm back to the user which URL you added.
- "Remove a site" — delete the matching line from `sites.txt`. If multiple match, ask before choosing.
- "Run the check now" — do everything in the cron flow above, then summarize the results in chat.
- "Why is [site] down?" — read the last 3-5 entries for that URL in `status-log.md` and report any pattern you see (consistent timeouts, intermittent 5xx, DNS failures, etc.). Don't speculate beyond what the log shows.
