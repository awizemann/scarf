---
title: Roadmap
type: note
permalink: scarf-wiki/roadmap
created: 2026-05-29
updated: 2026-08-13
---

# Roadmap

What's next for Scarf. Public, opinionated, subject to change.

> This page was frozen at "Now (2.5)" for a long stretch while Scarf shipped fourteen releases (v2.5 → v2.19). The roadmap is being re-planned rather than reconstructed after the fact — the "Now / Near-term" section below is deliberately thin, grounded only in the open task board (`TASKS.md`) and recent release notes, not backfilled speculation. Check the [Release Notes Index](Release-Notes-Index) for everything that's already shipped.

## Shipped since this page was last current

One line each, oldest to newest — see the [Release Notes Index](Release-Notes-Index) for full detail:

- **2.6** — Hermes v0.12 catch-up: autonomous Curator, multimodal ACP images, 5 new providers, Teams + Yuanbao gateways, read-only Kanban.
- **2.7 / 2.7.1 / 2.7.5** — Perf overhaul (skeleton-then-hydrate chat, SSH cancellation), then Kanban grew into a full drag-and-drop board.
- **2.8** — Hermes v0.13: Persistent Goals, ACP `/queue`, Kanban diagnostics + recovery UX, Curator archive/prune.
- **2.9.x** — Hermes v0.14: `/subgoal`/`/yolo`/`/sessions`/`/codex-runtime`, xAI Grok OAuth + NovitaAI providers, Hermes Proxy.
- **2.10.x** — Hermes v0.15 ("The Velocity Release"): OpenAI first-class provider, Kanban v0.15 maturation wave, Bitwarden Secrets, MCP mTLS.
- **2.11** — Hermes v0.16: first `state.db` schema change since v0.11 (`messages.active` soft-delete), live session titles.
- **2.12** — Hermes v0.17: zero mandatory compat changes; WhatsApp Business Cloud API + SimpleX gateways.
- **2.13** — ScarfGo gains Hermes profile switching; iOS remote-connection pooling reliability fix.
- **2.15** — Projects grow up: per-project cockpit, Mini-apps, Fleet & Portfolio, one-click Upgrade Project.
- **2.16.x** — Hermes v0.18 catch-up: in-place session compaction search, Web Tools tab fixed, lossless cron round-trip, SSH ControlMaster self-healing.
- **2.17.x** — Local model support + session-layer work (see Release Notes Index for detail).
- **2.18** — Hermes v0.19 "Quicksilver" + v0.20 "Herald" parity: pinned sessions, per-model costs, richer session export, approval suggestions, cron run history.
- **2.19** — Hermes v0.20 settings backlog closed (profile routing, title generation, reasoning effort, secrets sources, voice tuning, telemetry); browser provider picker bug fixed; cached version detection.

Also shipped along the way: [ScarfGo](ScarfGo) public TestFlight (iOS companion), full i18n for 7 languages, [Project Templates](Project-Templates), and the multi-server / remote-SSH architecture.

## Now / Near-term

Grounded in the open items on the task board (`TASKS.md`) as of 2026-08-13:

- **v2.19.1 patch pass** — in progress: UI-test isolation fix (tests were writing to a real `~/.hermes/projects.json`), a MiniAppBridge `onEvent` unhandled-rejection fix, `DASHBOARD_SCHEMA.md` updated for 5 missing widget types, and this wiki freshness pass.
- **Hermes v0.20 deferred settings backlog** (`t-1cc0a505`) — import-agent, sync, and other parked Phase 3 settings surfaces from the v0.20 audit.
- **Audit follow-ups** — a sweep of pickers with present-but-empty `""` rows that incorrectly claim to unset a value (`t-9634ae74`), and profile_routes edge cases + Bitwarden default drift from the 2026-08-12 fresh-eyes audit (`t-6a6d692c`).
- **Marketing site + README FAQ refresh** for the v2.15 Projects model (`t-83c4c692`), superseding an older open PR.
- A long tail of smaller verification/fix items tagged `[todo/*]` and `[followup/*]` in `TASKS.md` — mostly CLI-wire-shape verifications against live Hermes hosts and targeted bug fixes (image-attachment routing diagnosis, remote server connection editing, large-`state.db` performance).

No larger initiative has been scoped and committed yet beyond this list — check back once the next planning pass lands, or watch [TASKS.md](https://github.com/awizemann/scarf/blob/main/TASKS.md) directly for the live board.

## What we're NOT doing

- **A web version of Scarf.** The whole point is being native — macOS app on the desktop, iPhone app on mobile, both close to the metal.
- **Background sync.** Scarf is a viewer; Hermes runs the agent. Pull happens when you open a tab, not in the background. (Push notifications, when Hermes ships a sender, are an *event* surface — they alert; they don't sync.)
- **Bundled Hermes installer.** Hermes installation belongs in Hermes-land.
- **Closed-source / paid tier.** MIT-licensed, free, will stay that way.
- **Local Hermes runtime on iOS.** Hermes is Python; iOS doesn't sandbox Python runtimes practically. ScarfGo will always be a thin client over SSH.

## Suggesting features

Open an issue at <https://github.com/awizemann/scarf/issues> with what you want and why. Star the repo if you'd use it (signal helps prioritization).

---
_Last updated: 2026-08-13 — Scarf v2.19.0. Rewritten after a long freeze (previously stuck at "Now (2.5)" since 2026-04-25): added a shipped-since compressed history and narrowed Now/Near-term to what's actually grounded in the open task board — the roadmap is being re-planned, not reconstructed._
