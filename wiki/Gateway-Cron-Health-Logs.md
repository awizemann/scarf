---
title: Gateway-Cron-Health-Logs
type: note
permalink: scarf-wiki/gateway-cron-health-logs
created: 2026-05-29
updated: 2026-05-29
---

# Gateway / Cron / Health / Logs / Settings

The Manage section's operational tools, grouped because they're what you reach for when something needs attention.

## Gateway Control

Start, stop, and restart the messaging gateway. Live status:

- **PID, uptime, connected platforms.**
- Per-platform connection state mirrors the dot you see throughout the app.
- **Pairing management** — view approved users, approve new pairing requests, revoke existing approvals.

The gateway is what brings Hermes onto Telegram / Discord / Slack / etc. Stop it to take the agent offline without quitting Hermes itself.

## Cron Manager

View and edit Hermes scheduled jobs (`~/.hermes/cron/jobs.json`):

| Column | What it shows |
|---|---|
| Name | The job's display name. |
| Schedule | **Human-readable phrase** _(v2.5+)_ — "Every 6 hours", "Weekdays at 09:00", "@hourly", etc. — falling back to the raw cron expression for anything the formatter doesn't recognize. Backed by [`CronScheduleFormatter`](Core-Services); ScarfGo renders the same text. |
| State | `enabled` / `paused` / `failed` / `running` with an icon. |
| Last run / next run | Timestamps. |
| Delivery | Channel format like `discord:chat:thread`. |

**Operations** (new in 1.6 — full write support):

- Create a new job — prompt, optional skills, optional model override, schedule, delivery target.
- Edit any field on an existing job.
- Pause / resume.
- Run-now (one-shot trigger outside the schedule).
- Delete.
- Pre-run scripts, delivery-failure tracking, timeout type / seconds, `[SILENT]` indicator for jobs that suppress output.

Edits go through [`ServerContext.writeText`](Architecture-Overview) — atomic, transport-aware.

## Health

Component-level status and diagnostics. Mirrors `hermes status` and `hermes doctor`:

- API key validation per provider.
- Auth provider status.
- External tools availability (browser, terminal, voice).
- "Update available" indicator from [Sparkle](Updating).

**Two buttons:**

- **Run Dump** — captures `hermes dump` output inline.
- **Share Debug Report** — uploads a structured report to Nous support, with a confirmation dialog before sending.

### Supply-chain audit _(v2.10.0+, Hermes v0.15+)_

A **Run supply-chain audit** button runs `hermes audit` (which checks installed dependencies against the [OSV.dev](https://osv.dev) advisory database) and shows the result inline on the Health view. Gated on `HermesCapabilities.hasHermesAudit`.

### xAI retired-model warning _(v2.10.0+, Hermes v0.15+)_

When your configured model is one of the xAI Grok IDs retired on May 15 (`grok-4-0709`, `grok-4-fast-*`, `grok-4-1-fast-*`, `grok-code-fast-1`, `grok-3`, `grok-imagine-image-pro`), Health surfaces a warning with a one-click **`hermes migrate xai`** action to rewrite the stored model to its successor (`grok-4.3` / `grok-imagine-image-quality`). Stored retired IDs still resolve at runtime via Scarf's alias map, so this is a cleanup nudge, not a hard failure. Gated on `HermesCapabilities.hasXAIModelRetirement`.

### Web Dashboard launcher (local only)

Hermes ships a local web UI (`hermes dashboard`) on port 9119 for config / session management. The Health header shows its live state:

- **Launch Dashboard** spawns `hermes dashboard --no-open --port 9119` detached, waits for the port to bind (probing `/api/status` up to ~6s), then opens `http://127.0.0.1:9119` in the default browser.
- **Open in Browser** / **Stop** take over once the dashboard is running. Stop works whether Scarf launched it or you started it from a terminal — it falls back to `pkill -f "hermes dashboard"` in the external case.
- Liveness is polled every 3 seconds via a 500ms `GET /api/status` — that endpoint is whitelisted in Hermes's `_PUBLIC_API_PATHS` so no session token is needed for detection.

The row is hidden for remote servers — the dashboard binds 127.0.0.1 by default and SSH tunneling isn't wired up yet.

## Log Viewer

Real-time tail for the three main logs at `~/.hermes/logs/`:

- `agent.log` — the agent's loop.
- `errors.log` — errors only.
- `gateway.log` — messaging gateway.

**Filters:**

- **Level** — DEBUG / INFO / WARNING / ERROR / CRITICAL.
- **Component** — Gateway / Agent / Tools / CLI / Cron.
- **Session** — clickable session-ID pills filter the view to one session.
- **Text search.**

Local windows tail with `FileHandle`. Remote windows run `ssh host tail -F` with partial-line buffering so you don't see half-arrived JSON. See [`HermesLogService`](Core-Services).

## Settings

Restructured in 1.6 into a 10-tab layout exposing ~60 previously hidden config fields:

| Tab | What lives here |
|---|---|
| **General** | Updates (Sparkle toggle + manual check), basic preferences. |
| **Display** | Streaming, reasoning visibility, cost display, verbose mode. |
| **Agent** | Model picker (backed by models.dev catalog — 111 providers + 6 overlay-only providers from `HERMES_OVERLAYS`), max turns, approval mode, reasoning effort. |
| **Terminal** | Terminal backend, Docker / container settings, modal options. |
| **Browser** | Browser backend selection. |
| **Voice** | TTS / STT providers, PTT, silence threshold (default 200ms). |
| **Memory** | `memory_enabled`, `memory_char_limit`, `user_char_limit`, `memory_provider`. **Reset memory** _(v2.5+)_ — a toolbar button on Memory views (Mac + iOS) runs `hermes memory reset --yes` with a destructive-confirmation dialog. |
| **Aux Models** | All 8 auxiliary model tasks (vision, web extract, compression, delegation, etc.). |
| **Security** | Tirith sandbox, command allowlist, website blocklist, redaction. |
| **Secrets** _(v2.10.0+, Hermes v0.15+)_ | **Bitwarden Secrets Manager** (`secrets.bitwarden.*`) — enable, `access_token_env` (default `BWS_ACCESS_TOKEN`), project_id, override_existing, server_url (US / EU / self-hosted), cache_ttl_seconds, auto_install. The bootstrap token itself lives in `~/.hermes/.env`, not in this form. Gated on `HermesCapabilities.hasBitwarden`. |
| **Advanced** | Logging level / rotation, checkpoints, human-delay simulation, compression thresholds. |

**Backup & Restore** lives at the bottom — wraps `hermes backup` (zips the current profile) and `hermes import` (unzips into the active profile). One-click via `context.runHermes`.

ScarfGo's Settings tab is **read view + Quick Edits** — see [ScarfGo](ScarfGo) and [Platform Differences](Platform-Differences). The 7 quick-edit keys (`model.default` / `provider`, `agent.approval_mode` / `max_turns`, `display.streaming` / `show_cost` / `show_reasoning`) shell out to `hermes config set`. Other keys remain read-only on iOS.

## Related pages

- [Core Services](Core-Services) — the services backing each of these views.
- [Hermes Paths](Hermes-Paths) — where each operational file lives.
- [Updating](Updating) — Sparkle, the appcast, and how the auto-update flow works.

---
_Last updated: 2026-05-28 — Scarf v2.10.0 (Health supply-chain audit button + xAI retired-model migrate action, Settings → Secrets / Bitwarden Secrets Manager tab)_