# HackerNews Daily Digest — Agent Instructions

This project keeps a daily digest of HackerNews top stories filtered to the score threshold and (optional) topic keywords the user configured. The same instructions apply whether you're Hermes, Claude Code, Cursor, Codex, Aider, or any other agent that reads `AGENTS.md`.

## Project layout

- `.scarf/config.json` — **the source of truth for filter settings.** Written by Scarf's install/configure UI. Holds:
  - `values.min_score` (number, default 100) — minimum HN score to include.
  - `values.max_items` (number, default 15) — cap on items per digest run.
  - `values.topics` (array of strings, default `[]`) — keywords to mark in the digest. Empty array means "no topic highlighting; include every story above the score threshold."
- `.scarf/manifest.json` — cached copy of `template.json`. Don't modify.
- `digest.md` — append-only markdown log. Newest run at the top. Each run is a section with the ISO-8601 timestamp as the heading. Created on the first run if it doesn't exist.
- `.scarf/dashboard.json` — Scarf dashboard. **Only the `value` fields of the three stat widgets and the `items` array of the "Top Stories" list widget should be updated.** The section titles, widget types, and structure must stay intact.

## How configuration works

The user configures this project through Scarf's UI — not by editing files directly. On install, a form asked them for the score threshold, item cap, and any topic keywords; those values landed in `.scarf/config.json`. They can edit those values any time via the **Configuration** button on the project dashboard header.

Read configuration like this (JSON, via whatever file-read tool you have):

```
cat .scarf/config.json
# → { "values": { "min_score": 100, "max_items": 15, "topics": ["rust", "ai"] }, ... }
```

**Never** edit `.scarf/config.json` yourself. If the user asks "raise the score threshold" or "add a topic" in chat, tell them to open the Configuration button on the dashboard.

## First-run bootstrap

If `digest.md` doesn't exist, create it with a one-line header:

```
# HackerNews Daily Digest

Newest run at the top. Each section is a single digest.
```

## What to do when the cron job fires

The cron prompt Scarf registers for this project carries **absolute paths** (the installer substitutes `{{PROJECT_DIR}}` at install time) — you don't need to figure out the project's location yourself. Use whatever absolute paths appear in the prompt you received; if you're working in the project's interactive chat instead, the paths below are relative to the project root.

1. Read `.scarf/config.json`. Extract `values.min_score` (number), `values.max_items` (number), and `values.topics` (array). Apply defaults (100 / 15 / `[]`) for any missing field.
2. Fetch `https://hacker-news.firebaseio.com/v0/topstories.json`. Take the first `max_items * 3` IDs — that gives headroom for the score filter to drop low-scorers without re-fetching.
3. For each ID, fetch `https://hacker-news.firebaseio.com/v0/item/<id>.json`. Keep only items where:
   - `type == "story"`,
   - `score >= min_score`,
   - either `url` or `text` is non-null.
4. Truncate the surviving list to `max_items`.
5. If `topics` is non-empty, walk each surviving item and find the first keyword whose lowercase form is a substring of the lowercase title. Tag the item with that keyword in `[brackets]`. If no keyword matches, leave the item un-tagged.
6. Build a digest section:
   ```
   ## <ISO-8601 timestamp>

   - [<score>] <title> [<topic>]? — <url or https://news.ycombinator.com/item?id=<id>>
   - …
   ```
   Use the HN comments URL when the item has no external `url`.
7. Prepend the section to `digest.md` (newest at top).
8. Update `.scarf/dashboard.json`:
   - `Top Story Score` stat widget: `value` = the highest score in your filtered list (or `0` if the list is empty).
   - `Items Tracked` stat widget: `value` = number of items in the filtered list.
   - `Last Run` stat widget: `value` = the ISO-8601 timestamp.
   - `Top Stories` list widget `items`: one entry per filtered story:
     - `text`: `"[<score>] <title>"`
     - `status`: `"ok"` if the story matched a topic, otherwise `"pending"`.
9. If the cron job has a `deliver` target set, emit a one-line summary (`12 items, top score 487 — "<title>"`) as the agent's final response so the delivery mechanism picks it up.

## What not to do

- Don't modify the structure of `dashboard.json` (section titles, widget types, widget titles, `columns`). Only the values listed above are writable.
- Don't edit `.scarf/config.json` — that's the user's responsibility via the Configuration UI.
- Don't truncate `digest.md` — it's the historical record. If it grows past 1 MB, add a one-line note at the top of the file asking the user to archive it.
- Don't fetch any URL other than `hacker-news.firebaseio.com` (the digest source) or the items the user explicitly asks about. No scraping, no other news sources.
- Don't paginate past the first `max_items * 3` IDs. If the score filter eats all of them, write an empty digest section noting "no stories above threshold today" and update widgets to zero.

## When the user asks you things

- "What's in today's digest?" — read the top section of `digest.md` and summarize.
- "Run the digest now" — do everything in the cron flow above, then summarize the results in chat.
- "Why is [story] not in the digest?" — read the last 3–5 sections of `digest.md` and check whether the story appeared. If not, suggest the most likely cause (score below threshold, item type wasn't `story`, item appeared after the most recent run).
- "Change the threshold" / "add a topic" — tell them: *"Click the Configuration button on the dashboard header (the slider icon, next to the folder). Adjust the values there and save. The next cron run will pick it up."* Don't try to edit config.json yourself.
