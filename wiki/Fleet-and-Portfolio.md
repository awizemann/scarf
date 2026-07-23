---
title: Fleet-and-Portfolio
type: note
permalink: scarf-wiki/fleet-and-portfolio
created: 2026-06-28
updated: 2026-06-28
---

# Fleet & Portfolio

_The same project, understood across every machine you run it on._ (Scarf v2.15+, Mac)

If you run the same repo on more than one host — a laptop and a server, say — Scarf now treats those copies as **one logical project**, not two unrelated folders. The **Fleet** panel in a project's [cockpit](Projects-&-Profiles) shows each host's copy side by side, flags where their configuration has **drifted** apart, and lets you push one host's config out to the others.

## How Scarf knows it's the same project

Every project carries a **stable id**, minted once when the project is first scaffolded and stored in its repo-resident `project.json`. Because the id travels with the repo, registering a clone on a second machine surfaces it grouped with the original — Scarf matches by id, not by path or name. A project that lives on only one host simply shows no Fleet panel (there's nothing to compare).

> **To build a fleet:** scaffold or upgrade a project on host A, push/clone the repo to host B, then add that path as a project in the Scarf window connected to host B. The shared `project.json` id links them.

## Drift — where copies disagree

**Drift** is configuration that holds different values across a project's host materializations. The Fleet panel compares, per host:

- **Name** — a rename applied on one host only
- **Model preset** — the bound LLM preset (including bound-vs-default)
- **Board** — the Kanban board/tenant slug
- **Cron** — the *count* of project-attributed cron jobs (compared by count, since host-local job IDs differ per host)
- **Memory namespace** — the `MEMORY.md` block namespace
- **Mini-apps** — the set of registered [mini-app](Mini-Apps) ids

When everything agrees, the panel shows a green **In sync**. When it doesn't, a yellow callout names the drifted fields and the per-host cards highlight the disagreeing values.

## Apply to Fleet

When one host is configured the way you want, **Apply to Fleet…** pushes that host's config out to the others. You pick the source (this host), check which target hosts receive it, preview what will change per host, and confirm. Scarf then writes, per selected field:

- **Model preset** — rebinds the target's preset (idempotent, keyed by the preset's id, reversible).
- **Board** — sets the target's Kanban tenant where it doesn't already have one (additive — it never reassigns existing tasks).
- **Cron** — recreates the source's project cron jobs on the target via `hermes cron create`, rewriting prompt paths from the source root to the target root so relative paths still work. Jobs are created **paused** (mirroring the template installer), and jobs whose name already exists are skipped.

### It's deliberately conservative

- **Per-host, non-fatal isolation.** Each target is handled independently. One unreachable host, or one field that fails, never aborts the rest — you get a per-host, per-field report of what was **applied**, **skipped**, or **failed**.
- **Target-version-gated cron.** Copying cron probes the **target** host's `hermes --version` first and drops flags an older Hermes wouldn't understand — `--deliver all` on pre-0.14, `--workdir` on pre-0.12 — so the job is created with sane defaults instead of failing. An unreadable version probe falls back to the conservative (flags-dropped) path, and the result message tells you (e.g. "2 created without deliver=all — host < v0.14"). The same version-gating now protects cron jobs created during **template install**.
- **Live refresh.** After writing a target's fields, Scarf re-derives and saves that host's `project.json` so the Fleet panel reflects the new config immediately.

## Using it — at a glance

1. Open a project's cockpit and select the **Fleet** panel (it appears only for projects materialized on more than one host).
2. Read the summary: *Materialized on N hosts* + **In sync** or *X fields drifted*.
3. Scan the per-host cards (model, board, cron count, mini-apps, memory namespace). Drifted fields are highlighted.
4. If this host has config worth pushing, click **Apply to Fleet…**, choose targets, review the per-host preview, and confirm.
5. Read the results summary to see exactly what each target received.

## Related

- [Projects & Profiles](Projects-&-Profiles) — the first-class project object, cockpit, and Upgrade Project
- [Mini-Apps](Mini-Apps) — registered mini-apps are one of the fields drift tracks
- [Gateway / Cron / Health / Logs](Gateway-/-Cron-/-Health-/-Logs) — how Scarf surfaces cron jobs
- [Project Templates](Project-Templates) — template-install cron uses the same version-gating
