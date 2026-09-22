---
title: UI release gate: XCUITest is the gate, Harness is exploratory, fixture home built by the hermes CLI
type: note
permalink: scarf/decisions/ui-release-gate-xcuitest-is-the-gate-harness-is-exploratory
tags: [testing, release, harness, xcuitest]
source_paths: [scarf/scarfUITests/UITestIsolation.swift, scarf/scarfUITests/TemplateInstallUITests.swift, scarf/scarf/Navigation/AppCoordinator.swift, scripts/release.sh]
source_paths_inferred: false
source_sha: 96089feb0abaf78cf728e1ead67c4aa47f21cd11
created: 2026-09-08
updated: 2026-09-21
reviewed: 2026-09-12
reviewed_by: audit:claude-code (background)
---

Decided 2026-09-08 with Alan. Full plan: documents/testing/ui-release-gate-plan-2026-09-08.md. Harness "replay" is a viewer of a finished run's events.jsonl, not a re-executor, and its autonomous runs are LLM-driven and non-deterministic, so it cannot be a pass/fail gate.

## Observations
- [decision] The pre-release UI gate is XCUITest (scarfUITests on ScarfUITestCase isolation): a per-section sweep plus journeys, three test plans Smoke / Full / Live, run from release.sh with a loud --skip-ui-tests escape hatch; 10-15+ minutes is acceptable #testing #release
- [decision] Harness is OUT of the release-test story (Alan, 2026-09-08: drop it if it adds complexity, and it does — a second framework, LLM cost, weaker AX-label selectors); its replay is a viewer, not a re-executor, so it could never be a gate anyway #testing #harness
- [decision] Every UI test runs against a fresh throwaway Hermes home seeded by the installed hermes CLI (sessions, memories, paused cron, kanban, a skill, a project) so the state.db schema matches the real Hermes and Scarf itself never writes state.db (C3); no state.db is ever checked in #testing #fixture
- [decision] Credentials for the fixture home come from the developer's own real ~/.hermes (config.yaml / auth.json / .env copied by ScarfUITestCase); other contributors need their own Hermes install and keys, and the Live plan skips cleanly when hermes or credentials are absent #testing #secrets
- [convention] Every AppSection root view carries a <section>.root accessibility identifier and a scan test enforces it, so new sections cannot ship without being sweepable #testing #a11y

## Relations
- relates_to [[Fast test-iteration commands (swift test vs xcodebuild)]]
- relates_to [[ScarfCore tests inject a temp Hermes home via ServerContext.local(home:)]]
- relates_to [[Harness demo project surface for marketing screenshots]]


## The two fixture rows the hermes CLI cannot make (t-9c4d7c60, 2026-09-21)

The "seeded by the installed hermes CLI" rule above now has two documented
exceptions, both written by `make-ui-fixture.sh` into the THROWAWAY home it
just built (never the real one, which the script's existing safety checks
prove). Charter C3 binds Scarf, which stays read-only on every host.

- [constraint] A session's cost columns have NO CLI verb: `estimated_cost_usd` / `cost_status` are written only by the agent's own usage accounting (`hermes_state_usage.py:275`), and `hermes sessions` exposes list/export/rename/delete/import only. Driving real turns would randomise the exact dimension under test — which of the four statuses Hermes lands on depends on whether the configured model has a pricing entry — so the three cost-state rows (`uicost-unknown-0001` / `uicost-nullstatus-0002` / `uicost-amount-0003`) are a direct INSERT naming only columns a `PRAGMA table_info` probe found (C4) #testing #fixture
- [constraint] `tasks.session_id` is documented in Hermes's own source as "originating HERMES_SESSION_ID; NULL from CLI/dashboard" (`hermes_cli/kanban_db.py:730`): `kanban create` has no `--session` flag (only `list` does) and `HERMES_SESSION_ID` is read by the in-agent tool path, not the CLI. So the badge fixture's STATUSES come from the CLI and only the session stamp is a direct UPDATE on the fixture kanban.db #testing #kanban
- [convention] Both sets use FIXED ids so a test can address one row exactly (`sessions.row.<id>`, `chat.session.<id>`) instead of substring-matching a composed label the accessibility layer may truncate. The literals are duplicated in the script, `CostRenderingUITests.swift` and `ChatJourneyUITests.swift` — the UI-test bundle links neither the script nor ScarfCore — and the script's header block says to change all three together #testing
- [gotcha] `kanban create --initial-status running` PRINTS "(running, …)" and the row lands in `ready`, exactly as `--initial-status blocked` already did (re-verified on 0.21.4). `kanban claim` is the only transition that actually reaches `running`. The first verification pass grepped `kanban list`'s text for "running", and the seeded titles contain that word — so it passed on a board of two `ready` rows that the badge would have rendered as 1. Count the STATUS COLUMN, never the listing text #testing #gotcha
- [gotcha] `sqlite3 -readonly` FAILS on both fixture databases with "unable to open database file (14)": Hermes leaves them in WAL mode and a read-only open must create the `-shm` file. A PRAGMA probe written that way returns empty and is indistinguishable from "the column is missing" — it aborted the builder on its first run. Inspect a COPY with `?immutable=1`, or checkpoint first #testing #gotcha
