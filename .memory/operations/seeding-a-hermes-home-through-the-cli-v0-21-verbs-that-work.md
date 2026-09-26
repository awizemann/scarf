---
title: Seeding a Hermes home through the CLI (v0.21) — verbs that work and traps
type: note
permalink: scarf/operations/seeding-a-hermes-home-through-the-cli-v0-21-verbs-that-work
tags: [hermes, cli, testing, fixture, hermes-v0-21]
source_paths: [scripts/ui-fixture/make-ui-fixture.sh, scripts/ui-fixture/VERBS.md]
source_paths_inferred: true
source_sha: 6ec7e92a3340153ed472a7bdf07d61e0f77bab42
created: 2026-09-08
updated: 2026-09-08
---

## Observations

- [fact] **Expanded seed set** (verified through 2026-09-21): One-shot prompt via `hermes -z "<prompt>"` for sessions; `cron create <schedule> [prompt] --name --deliver local` then `cron pause <job_id>` for paused jobs; `kanban init` / `kanban create <title> --body` / `kanban block <id>` for simple cards; `kanban claim <id>` to transition a card to running (not `--initial-status running`, which is silently ignored); `kanban request-review <id> --summary --force` to transition to review; `project create <name> --description`; `skills repair-official <name> --restore --yes` for offline skill install. Full seeding runs in 25–75s, spending real tokens on the three sessions.

- [gotcha] `kanban create --initial-status blocked` and `--initial-status running` are **silently ignored** — the creation banner prints the requested status while the row lands in `ready`. Real transitions require follow-up calls: `kanban block <id>` for blocked, `kanban claim <id>` for running (CLAIM is the ready→running transition), `kanban request-review <id>` for review. Root cause: the --initial-status flag exists in argparse but is not wired to the create path. #hermes-v0-21

- [gotcha] `hermes skills install <identifier> --yes` resolves identifiers fuzzily and exits 0 when it finds no exact match ("No exact match for 'X'. Did you mean…"), installing nothing — indistinguishable from success by exit code. Judge by reading back `skills list`, or avoid it entirely: `skills repair-official <name> --restore --yes` installs from the local offline tree ($HERMES_INSTALL/optional-skills/) deterministically #hermes-v0-21

- [gotcha] `cron create` has no `--paused`/`--disabled` flag — a paused job must be created then `cron pause`d — and paused jobs are invisible to plain `cron list`, so any read-back must pass `--all` #cron

- [fact] `hermes memory` exposes only `setup/status/off/reset` (external provider plugins). There is NO CLI verb that creates a memory; built-in memory is `$HERMES_HOME/memories/MEMORY.md` + `USER.md`, which Scarf's own MemoryView reads and writes as plain files, so a fixture seeds them the same way #memory

- [gotcha] Not a Hermes bug but it bites every script that shells it: under `set -o pipefail`, `hermes … | grep -q needle` returns 141 because grep exits on first match and hermes takes SIGPIPE — a PASSING assertion fails, intermittently depending on output size. Capture the output into a variable and match that instead #shell

- [fact] **Cost-state seeding** (added 2026-09-21): No hermes verb sets session cost columns (`cost_status`, `estimated_cost_usd`) — they are written only by the agent's usage-accounting path (`hermes_state_usage.py:275`), unreachable from `hermes sessions` (list/export/rename/delete/import only). Fixtures must write those rows directly into the fixture's own state.db using sqlite3, using PRAGMA probes to find which columns exist (charter C4). The fixture builder stays read-only on the real home (safety checks at script start), so this write is always on the throwaway database. #cost

- [fact] **Chat-scoped kanban seeding** (added 2026-09-21): No hermes verb accepts a `--session` flag on `kanban create` (only `list` reads `--session`); `tasks.session_id` is documented as "NULL from CLI/dashboard" (kanban_db.py:730). Task statuses come from the CLI (create + claim + request-review); only the session_id stamp is a direct UPDATE on the fixture's own kanban.db. Both direct-write patterns respect charter C3 — Scarf stays read-only, and the builder writes only the throwaway home it just created, which the script's own safety checks prove is not the real home. #kanban-session

- [gotcha] `sqlite3 -readonly` **fails** on both fixture databases in WAL mode: a read-only open must create the `-shm` shared-memory file, so `sqlite3 -readonly kanban.db` exits with "unable to open database file (14)". Always pass `-readonly` only on a COPY of the database, or checkpoint it first. The fixture script deliberately opens read-write (only against the throwaway home) and uses PRAGMA probes rather than trying to inspect read-only. #sqlite-wal

## Relations
- documented_in [[scarf-wiki/UI-Test Fixture]]
- relates_to [[Hermes v0.21 Compatibility Decisions]]
