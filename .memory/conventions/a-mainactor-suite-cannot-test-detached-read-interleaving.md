---
title: A @MainActor suite cannot test detached-read interleaving — such tests pass with the fix removed
type: note
permalink: scarf/conventions/a-mainactor-suite-cannot-test-detached-read-interleaving
tags: [testing, concurrency, swift-testing]
source_paths: [scarf/Packages/ScarfCore/Tests/ScarfCoreTests/ProjectsViewModelErrorSurfacingTests.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/ProjectsViewModel.swift]
source_paths_inferred: false
source_sha: 04223db9206630eb927ee0feef42c5525f10b025
created: 2026-09-03
updated: 2026-09-03
---

Found while adding a regression test for the `reloadGeneration` stale-clobber guard in `ProjectsViewModel` (Phase 2 of projects-first-class, commit 30be59d). The test looked correct, passed, and proved nothing.

## Observations
- [gotcha] In a `@MainActor` `@Suite`, `async let inFlight = vm.reload()` followed by a SYNCHRONOUS mutation does NOT interleave: the child task cannot run until the test suspends, so the 'stale detached read lands after the mutation' race never occurs and the test passes with the guard REMOVED. #testing #concurrency
- [convention] Before trusting any concurrency-ordering test, delete the fix and re-run it. If it still passes it is measuring nothing — delete the test rather than ship a green check, and leave a comment saying why the guard stands on reasoning instead. Same discipline as the fixture-honesty `#expect(throws:)` checks in ProjectRegistryResilienceTests. #testing
- [fact] Ordering guarantees that need a read seam to test honestly are a legitimate deferral; an injectable registry-read seam on ProjectDashboardService is what would make them testable. #todo

## Relations
- relates_to [[Project mutations report failure; registry damage banner is signature-dismissed]]
- relates_to [[Task.detached capture lists must be explicit]]
