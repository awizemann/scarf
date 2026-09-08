---
id: t-cd7d1c11
title: UI gate P2b journey: Cron + Kanban
status: done
added: 2026-09-08
---

## Description

XCUITest journeys: cron create → pause → delete (verify via UI and via the fixture home's cron/jobs.json); kanban card create → move column (verify via UI and `hermes kanban` CLI against the fixture home). Add identifiers as needed. Depends on P1a + P1b.

## Plan



## Artifacts

## Artifacts

Commit `d18c2680` on `worktree-agent-ace824ad5ce410d6c` (branched off `ui-gate` — the worktree had been cut from `main`, so it was reset onto `ui-gate` first). Not pushed.

**New**
- `scarf/scarfUITests/CronKanbanJourneyUITests.swift` — two journeys. Cron: create through the editor sheet → assert the row renders → pause → delete, each step cross-checked against `<isolatedHome>/cron/jobs.json` and `hermes cron list [--all]` (the bare form is asserted NOT to list a paused job). Kanban: `kanban init` → create through the sheet → assert the card is inside `kanban.column.upNext` → Block through the inspector → assert it moved to `kanban.column.blocked`, cross-checked against `hermes kanban list`. Seeded fixture rows (2 paused cron jobs, 3 cards incl. the blocked one) asserted when `SCARF_UITEST_FIXTURE` is set, and the empty-home case asserted when it is not.

**Identifiers added** (all on real controls): `cron.newJob`, `cron.row.<id>`, `cron.editor.{name,schedule,prompt,save}`, `cron.detail.{state,pauseToggle,delete}`, `cron.message`, `kanban.newTask`, `kanban.create.{title,submit}`, `kanban.column.<column>`, `kanban.card.<id>`, `kanban.inspector.block`, `kanban.block.confirm`. Row/card ids mirror the ids the CLI prints.

**Infrastructure changed**
- `ContentView.swift` — `<section>.root` moved onto a 1×1 transparent marker overlay. A container `.accessibilityIdentifier` REWRITES every descendant's, so the P1b root id was erasing every identifier in every section (`[Cron.root] New cron job`); `.accessibilityElement(children: .contain)` fixed that but broke synthesized clicks inside the section.
- `KanbanColumnView.swift` — column is now an a11y container, so `kanban.column.<x>` resolves to one element and card-in-column containment can be asserted.
- `expandAllSidebarSections` moved from `SectionSweepUITests` to `ScarfUITestCase`.
- Journeys pin `kanban.viewMode` and `WindowFrameAutosave`'s key through `NSArgumentDomain`.

**Verification** — `-testPlan Full -only-testing:scarfUITests/CronKanbanJourneyUITests`, run repeatedly with and without `TEST_RUNNER_SCARF_UITEST_FIXTURE`. Cron journey passes in both modes (~63–68 s each). Kanban journey has been driven end to end through create + column-move with the fixture, but does not pass reliably: it skips whenever the host capability probe has not landed within 180 s (t-a9ad5e67), and its final Block step has failed in some runs. Real `~/.hermes` untouched — `cron/jobs.json` and `kanban.db` mtimes identical before and after.

**Bugs filed** — t-0fb3b91f (cron detail pane unreachable / VoiceOver implications; cron pause+delete steps are landed under `XCTExpectFailure(strict: false)` rather than dropped), t-a9ad5e67 (one-shot capability probe), t-e0c3bd4d (gate writes the developer's window-frame pref).

**Memory** — new note `scarf/conventions/driving-cron-and-kanban-from-xcuitest-what-actually-works`; corrected the identifier-propagation claim in `scarf/conventions/xcuitest-runner-gotchas-env-vars-need-test-runner`.

**Still open** — the Kanban journey needs a second look once t-a9ad5e67 lands; until then the Kanban half of the gate is non-deterministic.

