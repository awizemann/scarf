---
title: A source-scan test must be calibrated against the target's default actor isolation
type: note
permalink: scarf/conventions/a-source-scan-test-must-be-calibrated-against-the-target-s
tags: [testing, concurrency, c10, verification]
source_paths: [scarf/scarfTests/MainActorSpawnDisciplineP22Tests.swift, scarf/scarf.xcodeproj/project.pbxproj, scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift]
source_paths_inferred: false
source_sha: 867f146260291ca96c6e07c4736d5910b16d5034
created: 2026-09-10
updated: 2026-09-10
---

Written in P37 of the round-3 whole-surface audit, after the first draft of `MainActorSpawnDisciplineP22Tests.noNewSynchronousWaitRunsOnTheMainActor` passed while `HealthViewModel.dashboardListenerPID` sat right there doing an `lsof` wait on the main actor. The failure was not in the rule being checked but in the test's model of the language, and the same four mistakes are available to any future scan test.

## Observations
- [gotcha] Scarf's app targets build with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`scarf.xcodeproj/project.pbxproj:606,649,910,947`), so in `scarf/scarf` and `Scarf iOS` EVERY declaration is main-actor-isolated unless it says `nonisolated` - and almost nothing says `@MainActor` anywhere. A C10 scan that looks FOR an `@MainActor` line therefore finds nothing and passes while real violations sit in plain sight. The gate is per-root: default-isolated target means a hit unless the declaration chain opts out; ScarfCore (no default isolation) means a hit only when the type carries `@MainActor` #concurrency #testing
- [convention] A scan test must assert the HIT COUNT equals the allowlist size, not only that the offender list is empty. `#expect(offenders.isEmpty)` passes identically when the scan is correct and when its matcher has quietly stopped matching; `#expect(hits == allowed.count)` fails loudly in the second case and is the only thing that proves the test is still a test #testing #verification
- [convention] Walk OUT to enclosing declarations by INDENT, never by nearest-func-above or any-line-above. Nearest-func lands on a nested local helper (`func closePipes` inside a `nonisolated func unzip`) and reports three already-correct sites; scanning every line above finds an unrelated `nonisolated` hundreds of lines away and excuses a real one. Only a line indented strictly less than everything seen so far encloses the site #testing
- [convention] Every allowlist entry in a scan test carries a task id AND an assertion that the debt still exists, so a fixed-or-renamed site cannot leave a stale entry silently hiding the next violation. P37 shipped two: `AppRelauncher.relaunch()` (t-b15ba4c3) and `HealthViewModel.dashboardListenerPID` (t-cd9fd829) #testing #conventions
- [gotcha] Prove a scan test bites by PLANTING a violation, in both directions: a file with no `@MainActor` line at all (caught only once the default-isolation gate was right) and a `nonisolated` function with a nested helper (must be excused). A scan test that has never been shown to fail is a checkbox #testing

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Unguarded-write seam: the primitive is named, and a scan test keeps it honest]]
