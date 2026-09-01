# Scarf v2.23.0

This is the Hermes v0.21.0 ("Pantheon") parity release. Hermes's biggest release of the year shipped Bot Mode, a 3× larger MCP catalog, cron incidents, and bot-to-bot messaging — and this Scarf release makes all of it work correctly from the Mac app, adds a new **Peers** section for messaging your other Hermes agents, and fixes a cluster of long-standing parsing bugs the source audit surfaced. Every new surface is capability-gated: connect to an older Hermes and Scarf behaves exactly as before. Compatibility now spans Hermes v0.6.0 through v0.21.0.

## Peers — message your other agents ⚙

Hermes v0.21 introduced `hermes peer`: agent-to-agent DMs and async runs between your Hermes installations. Scarf now has a **Peers** section (Manage sidebar, next to Gateway) on v0.21+ hosts: your registered peers listed from config, one-shot DMs, and asynchronous runs with live status, stop, and replay-aware deduplication. Scarf reads the peer registry directly and never touches peer API keys — registration stays a CLI act, and the empty state shows you the exact `hermes peer add` command. Errors surface Hermes's own words verbatim, including the "peer too old" remedy.

## Cron grew a health system ⚙

- **Incidents** — Hermes v0.20.6+ records durable failure incidents per job (deduplicated by error signature). Scarf shows an open-incident badge per job and an expandable incident list with one-click acknowledge — including the truthful "already closed" case when a scheduler tick beat you to it.
- **Doctor** — per-job configuration health (missing scripts, overdue schedules) renders as warning indicators on job rows, parsed robustly even when a job's last error is a multi-line traceback.
- **Resume & Run Now** — paused or completed jobs can be re-armed and fired immediately on hosts that support it; on older hosts Scarf defers to the CLI's own behavior instead of refusing locally.
- **Bot Chat delivery** — cron output can land in a bot's canonical Bot Chat (v0.20.6+), now offered as a delivery target — and Scarf no longer forwards that target to hosts that can't parse it.
- Scarf now reads every jobs.json shape Hermes tolerates (ID-keyed maps, bare `repeat` values), so a store written by a newer Hermes never fails to load.

## Session previews got honest

Since Hermes v0.19, in-place compaction can leave a machine-generated summary as a session's earliest message — and Scarf's session list happily showed that boilerplate as the preview. Previews now mirror Hermes's own carrier-aware logic (ported SQL, verified byte-identical to upstream): you see the first *authentic* message, with summary scaffolding stripped and rewound messages excluded. Renaming a session also now explains itself when Hermes refuses (canonical "Bot Chat" sessions are rename-protected server-side).

## The MCP catalog tripled ⚙

The optional-MCP catalog jumped from 20 to 65 entries (Algolia, CircleCI, Cloudflare, Grafana, GitLab, Neon, Postman, Railway, Semgrep, Strava, Wolfram, and 34 more) — and the Atlassian entry's URL is fixed (the old endpoint has 404'd since June). Catalog installs now honor each entry's recommended tool exclusions, mirroring Hermes's own install behavior.

## Parity fixes the audit forced

- **Web search/extract settings** track Hermes's backend changes: Tavily (removed upstream) is dropped from the pickers unless your config still uses it; the retired Web Extract auxiliary-model row hides on hosts that no longer read it and stays for older hosts that do.
- **Turn lease timeout** displays and accepts the new v0.21 default (5s) instead of silently snapping it to 60.
- **Health's update check** now recognizes all three of Hermes's "Update available" formats (including "1 commit behind" and the count-less form, previously invisible) and honestly reports "unknown" when an offline host prints nothing, instead of implying you're current.
- **Gateway status** stops matching phantom strings: the "Loaded" state is now derived from what `hermes gateway status` actually prints, and a stale PID file no longer shows a dead gateway as running.
- **Curator pin/unpin** surfaces Hermes's new diagnostics, including the "recorded but unmanaged — adopt it" nudge that used to be silently discarded.
- **Two new providers** — Tencent TokenPlan and Nebius Token Factory — appear in the model picker with all their aliases.
- **Dotted names no longer corrupt config**: a quick command named "v1.2 deploy" used to write nested garbage into config.yaml; Scarf now uses Hermes v0.21's escape syntax (and safely sanitizes on older hosts), and recovers previously mangled entries on read.
- The `hermes-agent` skill (essential and un-disableable since v0.20.6) can no longer show as "OFF" from a stale config entry.

## Under the hood

- New capability groups `isV0206OrLater` / `isV021OrLater` with per-flag floors verified against each intervening Hermes tag — several features the v0.21 release notes advertise actually shipped in v0.20.6, and Scarf gates them where they really landed.
- 104 new tests (ScarfCore now at 1474), including fixture-driven parsers for cron incidents/doctor and peer JSON, an end-to-end remote-backend preview test over real SQLite, and a byte-identity check against Hermes's preview SQL.
- The whole cycle ran as audited work packages with an independent fresh-eyes review; its findings (a doctor-parser edge case, two over-eager version gates, several parser hardenings) are fixed in this release.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight; this release requires no iOS-side update.
- Compatible with Hermes v0.6.0 through v0.21.0. Sections marked ⚙ appear only when the connected host supports them; older hosts render identically to v2.22.0.
