---
id: t-a9ef75f0
title: Activity section shows an error banner in the UI sweep, failing testEverySectionRenders
status: done
added: 2026-09-10
---

## Description

`scarfUITests/SectionSweepUITests.testEverySectionRenders` fails on the Activity section:

    scarf/scarfUITests/SectionSweepUITests.swift:188: error:
    Activity rendered with an error.banner on screen: Warning

PRE-EXISTING, proven: reproduced identically on a detached worktree at `99412912` (the commit before P35) with a scratch `-derivedDataPath`, so it is not caused by the round-3 remediation branch. It also fails in isolation, not only under the full serial run, so it is not a load flake.

The banner is `ActivityView.swift:97` (`.accessibilityIdentifier("error.banner")`), the orange read-warning bar whose Retry calls `ActivityViewModel.load()`. The sweep launches with an isolated `SCARF_HERMES_HOME`, which has no `state.db`, so the likely cause is that Activity reports a missing/unreadable state.db as a WARNING banner where the other sections render an empty state — i.e. the sweep's "rendered but broken" contract and Activity's empty-vs-unreadable discriminator disagree.

Decide which is right and fix that side: either Activity should treat "no state.db yet" as an empty state rather than a warning (the `absent vs unreadable is the discriminator` rule in `.memory/decisions/`), or the sweep should seed a state.db for the Activity section. Do not weaken the sweep's banner assertion — a rendered-but-broken section is exactly what it exists to catch.

Also worth checking in the same pass: `ConfigJourneyUITests.testModelPresetCreateAndDeleteWritesPresetStore` appeared in the same full-run failure list but PASSES in isolation, so it looks load-sensitive; confirm and add it to the known load-sensitive list (t-f3820038) or fix the wait.

## Plan



## Artifacts

Fixed in `e8887a66` on main (2026-09-14): `ActivityViewModel.loadImpl` mirrors `DashboardViewModel`'s rule — a LOCAL context whose state.db does not exist renders the empty feed; a local database that exists but cannot be read warns without naming SSH; remote failures keep the SSH copy. Tests: `ScarfCoreTests/ActivityAbsentStateDBTests` (2). Smoke plan green afterwards: all 28 sections render, 127 s. The `ConfigJourneyUITests.testModelPresetCreateAndDeleteWritesPresetStore` load-sensitivity note stays open on the Full-plan run.

