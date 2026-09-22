---
title: UI-test fixture home builder (make-ui-fixture.sh) contract
type: note
permalink: scarf/operations/ui-test-fixture-home-builder-make-ui-fixture-sh-contract
tags: [testing, ui-tests, fixture, release-gate, hermes]
source_paths: [scripts/ui-fixture/make-ui-fixture.sh, scarf/scarfUITests/UITestIsolation.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesProfileResolver.swift]
source_paths_inferred: false
source_sha: 09bc6bed5dd25c3aa33c4d09c861cd37c8bc0383
created: 2026-09-08
updated: 2026-09-08
reviewed: 2026-09-08
reviewed_by: claude-fable-5-1
---

`scripts/ui-fixture/make-ui-fixture.sh <dest-dir>` builds the seeded throwaway Hermes home the XCUITest release gate runs against (phase 1 of the UI release gate plan, 2026-09-08). `ScarfUITestCase.makeIsolatedHermesHome()` mints the same SHAPE but empty, so a section sweep against it only proves empty states render; this script adds real data by driving the installed `hermes` CLI with `HERMES_HOME` pointed at the fixture.

Consume it as `FIXTURE="$(scripts/ui-fixture/make-ui-fixture.sh "$(mktemp -d)/fixture-home)")" — the path is the only thing on stdout, progress goes to stderr — then launch with BOTH `SCARF_HERMES_HOME` (Scarf's own file I/O) and `HERMES_HOME` (the CLI `LocalTransport` spawns) set to it.

## Observations
- [convention] The fixture mirrors `ScarfUITestCase` exactly: subdirs `scarf/ cron/ sessions/ logs/`, the `.scarf-test-home-marker` sentinel (without it `HermesProfileResolver` ignores `SCARF_HERMES_HOME` and silently falls back to the REAL `~/.hermes`), and COPIES — never symlinks — of `config.yaml`, `auth.json`, `.env` #testing
- [fact] Seeds 3 real one-shot sessions, 3 cost-state sessions (direct state.db writes for testing cost presentations), 3 ACP badge chats with chat-scoped kanban tasks, 2 paused cron jobs, 3 kanban cards (one blocked), 1 project, 1 official skill (`openhue`, offline), and `memories/MEMORY.md` + `USER.md` #testing
- [constraint] `--dry-run` verifies every verb/flag against the installed argparse and seeds nothing; `--self-check` digests five paths under the real `~/.hermes` (scarf/projects.json, cron/jobs.json, state.db, kanban.db, config.yaml) before and after and fails on any change. There is deliberately NO `--keep-going` — a failed verb aborts non-zero naming the verb #testing
- [constraint] Refuses a dest that is or is inside the real `~/.hermes` (symlinks resolved via the deepest existing ancestor), `$HOME`, or `/`; a rerun clears an existing dir ONLY when it is empty or carries the sentinel, never an arbitrary non-empty directory #safety
- [decision] Never check a `state.db` into the repo — generating through the CLI (and direct writes to the fixture's own throwaway copy only) keeps the schema matched to the Hermes the app actually faces and keeps charter C3 intact (Scarf never writes state.db; the fixture script does, through hermes or directly to the throwaway home) #decision

## Relations
- relates_to [[Seeding a Hermes home through the CLI (v0.21) — verbs that work and traps]]
- relates_to [[UI release gate: XCUITest is the gate, Harness is exploratory, fixture home built by the hermes CLI]]
