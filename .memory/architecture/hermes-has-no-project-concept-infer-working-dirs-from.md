---
title: Hermes has no project concept — infer working dirs from checkpoints, sessions.cwd, cron, kanban
type: note
permalink: scarf/architecture/hermes-has-no-project-concept-infer-working-dirs-from
tags: [hermes, projects, storage, integration, import, enumeration, reference]
created: 2026-06-20
updated: 2026-09-11
---

Researched (2026-06) from the then-vendored Hermes source at `~/Developer/ScarfBox/Vendor/hermes-agent` — **that path is retired; the Hermes checkout for tag walks is now `~/.hermes/hermes-agent`** (`git -C ~/.hermes/hermes-agent show <tag>:<path>`, never touch its working tree) — plus the live `~/.hermes` (2026-06, Hermes v2.10/state.db schema_v14). The substrate for a future "import Hermes-only projects into Scarf" feature (Phase-1 "projects amazing" part 2).

## Observations

- [no-project-entity] Hermes has **no first-class "project."** It models *sessions, cron jobs, kanban tasks, checkpoints, profiles* — each independently + optionally references a **directory** (cwd / workdir / workspace_path) or a **namespace** (kanban `tenant`). Nothing unifies them. "Project" is a Scarf invention (registry `~/.hermes/scarf/projects.json` + canonical `<root>/.scarf/project.json`). So importing requires INFERRING projects from directory signals. #hermes

- [profiles-are-not-projects] `~/.hermes/profiles/<name>/` is a **complete separate `HERMES_HOME`** (own state.db, sessions/, config.yaml, .env, auth.json, cron/, skills/) — a config+credential namespace, NOT a working directory. Resolution: if `HERMES_HOME`'s parent dir is named `profiles`, root = grandparent (`hermes_constants.py`). ScarfBox makes one profile per sandbox (`scarfbox-*`). **Do NOT enumerate profiles as projects.** #gotcha

- [enumeration-sources] Directories Hermes has worked in, ranked by reliability:
  1. **Checkpoint workdir registry** — `~/.hermes/checkpoints/store/projects/<sha256(abspath)[:16]>.json` → `{workdir, created_at, last_touch}`. Purpose-built ledger; survives session deletion. Often EMPTY in fresh homes (no checkpoints taken yet).
  2. **`sessions.cwd`** in `~/.hermes/state.db` (SQLite, `schema_version` 14): `SELECT DISTINCT cwd FROM sessions WHERE cwd IS NOT NULL AND source IN ('acp','cli')`. Reliably set for **acp** (the path Scarf/GUI clients use) + local-cli; **NULL** for cron/telegram/gateway + pre-column rows (no backfill). Also `model_config` JSON carries `.cwd` for acp.
  3. **Cron `workdir`** — `~/.hermes/cron/jobs.json` `jobs[].workdir` (absolute, validated-to-exist). When absent, the dir often only appears inside `jobs[].prompt`/`script` text (heuristic path-extraction, low confidence).
  4. **Kanban** — `~/.hermes/kanban.db` `tasks.workspace_path` (where `workspace_kind='dir'`) + `tasks.tenant` (Scarf mints `scarf:<slug>`; non-`scarf:` tenants = CLI-user projects worth surfacing). There IS a `project_id TEXT` column (`hermes_cli/kanban_db.py:866-869` @ v2026.9.7), but it references Hermes's own per-profile `projects.db` and a non-resolving id is silently dropped at create (`:1124-1127`) — so it is not a Scarf key and not a discovery source (corrected in P42).
  5. **On-disk `.scarf/` scan** — dirs containing `.scarf/project.json`|`manifest.json` not present in the registry (catches scaffolded/cloned projects dropped from `projects.json`).

- [algorithm] Union sources 1–5 → normalize (expand `~`, resolve symlinks, drop trailing `/`) → exclude `~/.hermes` itself + `~/.hermes/profiles/*` → set-subtract registry `path`s → rank survivors by recency (`last_touch` / `started_at` / `last_run_at`). #import

- [fresh-home-gotcha] In a fresh-ish home, checkpoints (#1) AND `sessions.cwd` (#2) can BOTH be empty/NULL even though the user clearly has projects — the signals that actually fired were **cron (#3) + kanban (#4)**. A robust "discover projects" feature must union ALL sources, never rely on `sessions.cwd` alone. #gotcha

- [agents-md-live] AGENTS.md / CLAUDE.md / .cursorrules are **read live from the cwd at run time** (injected into the system prompt when a workdir is established — cron via `workdir`, sessions via `TERMINAL_CWD`), never persisted to a DB. So "AGENTS.md ↔ project" binding = "whatever cwd was active." #hermes

## Relations
- relates_to [[Phase-1 Milestone 1: First-Class Project Object — implementation decisions]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
- relates_to [[Project-Scoped Chat and AGENTS.md Context]]
