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

Verified against the installed CLI at v0.21.0 (2026.8.31) on 2026-09-08 while building `scripts/ui-fixture/make-ui-fixture.sh`. Every claim below is an observed run with `HERMES_HOME` pointed at a throwaway home, not a reading of release notes (charter C2/C5). Full `--help` excerpts live in `scripts/ui-fixture/VERBS.md`.

Working seed set: `hermes -z "<prompt>"` (root-parser option, not a verb) for sessions; `cron create <schedule> [prompt] --name --deliver local` then `cron pause <job_id>`; `kanban init` / `kanban create <title> --body` / `kanban block <id>`; `project create <name> --description`; `skills repair-official <name> --restore --yes`. A full seed of 3 sessions + 2 cron + 3 cards + project + skill runs in 25-75s.

## Observations
- [gotcha] `kanban create --initial-status blocked` is STILL silently ignored at v0.21.0 (unchanged from v0.20) AND the creation banner lies — it prints `Created t_xxx  (blocked, assignee=-)` while `kanban list` shows the row in `ready`. The only real path is a second `hermes kanban block <id>`; never trust the create output for status #hermes-v0-21
- [gotcha] `hermes skills install <identifier> --yes` resolves identifiers FUZZILY and EXITS 0 when nothing matches exactly ("No exact match for 'hello-test'. Did you mean…"), installing nothing — a textbook C5 trap. Judge it by reading back `skills list`, or avoid it: `skills repair-official <name> --restore --yes` installs from the LOCAL `<install-dir>/optional-skills/` tree, offline and deterministic #hermes-v0-21
- [gotcha] `cron create` has no `--paused`/`--disabled` flag — a paused job must be created then `cron pause`d — and paused jobs are invisible to plain `cron list`, so any read-back must pass `--all` #cron
- [fact] `hermes memory` exposes only `setup/status/off/reset` (external provider plugins). There is NO CLI verb that creates a memory; built-in memory is `$HERMES_HOME/memories/MEMORY.md` + `USER.md`, which Scarf's own MemoryView reads and writes as plain files, so a fixture seeds them the same way #memory
- [gotcha] Not a Hermes bug but it bites every script that shells it: under `set -o pipefail`, `hermes … | grep -q needle` returns 141 because grep exits on first match and hermes takes SIGPIPE — a PASSING assertion fails, intermittently, depending on output size. Capture the output into a variable and match that #shell

## Relations
- relates_to [[Hermes v0.21 Compatibility Decisions]]
- relates_to [[Harness demo project surface for marketing screenshots]]
