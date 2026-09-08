---
id: t-ec6d2e6d
title: Fix Skills → Uninstall: wrong identifier, and exit 0 on failure
status: done
added: 2026-09-08
priority: high
---

## Description

Found while building the UI-gate P2c config journeys (t-877c6e6f). Scarf's Skills → detail pane → **Uninstall does nothing and reports success**, for every skill. Two independent defects, both charter C5:

**1. Wrong identifier.** `SkillsView.skillDetail` calls `viewModel.uninstallHubSkill(skill.id)`, and `SkillsScanner.swift:71` builds that id as `categoryName + "/" + skillName`. So Scarf runs `hermes skills uninstall <category>/<name>`. Verified against the installed CLI (v0.21.0) with `HERMES_HOME` pointed at a throwaway copy of the UI fixture home:

    $ hermes skills uninstall smart-home/openhue      # exit 0
    Uninstall 'smart-home/openhue'?
    Confirm [y/N]: Error: 'smart-home/openhue' is not a hub-installed skill (may be a builtin)
    # openhue still on disk

    $ hermes skills uninstall openhue                 # exit 0
    Uninstall 'openhue'?
    Confirm [y/N]: Uninstalled 'openhue' from smart-home/openhue
    # gone

The CLI wants the BARE skill name. Fix: pass `skill.name` (`SkillsViewModel.uninstallArgs` is already name-shaped — only the call site is wrong).

**2. Exit 0 is not success.** Note that BOTH invocations above exit 0 — the failure path exits zero too. `SkillsViewModel.uninstallHubSkill` → `finishUninstall(exitCode:)` judges the outcome purely by exit code, so even after fixing (1) any future failure will surface to the user as "uninstalled". Judge it by reading back the skill list / the output, the way the v0.21 seeding note says to judge `skills install` (which has the same fuzzy-miss-exits-0 trap).

**Blast radius:** every Uninstall click in the Skills section since the feature shipped. Users see a success banner and the skill stays installed.

**Regression test already exists:** `scarf/scarfUITests/ConfigJourneyUITests.swift` → `testFixtureSkillIsListedAndUninstalls` asserts the skill leaves `<home>/skills/<category>/<name>`. It is currently wrapped in `XCTExpectedFailure("t-2f9ab0c4: …")`, so it keeps the gate green while this is open and FAILS as soon as the bug is fixed — remove the wrapper as part of the fix, don't just delete the test.

## Plan



## Artifacts

Fixed on ui-gate: SkillsView passes skill.name; SkillsViewModel.uninstallSucceeded(exitCode:output:) treats an `Error:` line as failure regardless of exit 0 and the banner shows the CLI's reason; --yes deliberately not added (absent on v0.20 hosts, stdin "y\n" works on both). Unit test in HermesV020ParityWaveB4Tests; the Config journey's XCTExpectFailure wrapper is removed so the uninstall assertions run for real.

