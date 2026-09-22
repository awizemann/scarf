---
title: XCUITest runner gotchas: env vars need TEST_RUNNER_, identifiers propagate, ⌘1 keystrokes get dropped
type: note
permalink: scarf/conventions/xcuitest-runner-gotchas-env-vars-need-test-runner
tags: [testing, xcuitest, swiftui, a11y, gotcha]
source_paths: [scarf/scarfUITests/UITestIsolation.swift, scarf/scarf/ContentView.swift]
source_paths_inferred: false
source_sha: 09bc6bed5dd25c3aa33c4d09c861cd37c8bc0383
created: 2026-09-08
updated: 2026-09-21
reviewed: 2026-09-08
reviewed_by: claude-fable-5-1
---

Learned while building the section sweep (t-e732e091, 2026-09-08). All four verified on this Mac, not inferred.

## Observations
- [gotcha] xcodebuild does NOT forward its own environment to the XCUITest RUNNER process: `FOO=bar xcodebuild test` is silently ignored inside the test. Prefix it — `TEST_RUNNER_FOO=bar` arrives as `FOO`. Verified both ways with SCARF_UITEST_FIXTURE #testing #gotcha
- [gotcha] CORRECTED 2026-09-08 (t-cd7d1c11): `.accessibilityIdentifier` on a container does NOT leave inner identifiers alone — it REWRITES every descendant's, so ContentView's `<section>.root` erased `cron.newJob` (seen as `[Cron.root] New cron job`) and every other in-section id. `.accessibilityElement(children: .contain)` restores them but then synthesized clicks stop activating controls inside; the shipped answer is a 1×1 `Color.clear` MARKER overlay carrying the id #swiftui #a11y
- [gotcha] The ⌘1 window-surface nudge is lossy: a keystroke landing between "process is .runningForeground" and "menu bar installed" is dropped with no error. `launchAndSurface` re-sends it up to 3 times (harmless — ⌘1 with a window open just focuses it); this was the target's most likely flake #testing
- [convention] Wait for `XCUIApplication.state` with `XCTNSPredicateExpectation`, which POLLS (~1 Hz) rather than relying on KVO — `state` posts no change notifications, and this is what replaced every `Thread.sleep` in scarfUITests. Disappearance needs a predicate expectation too; `waitForExistence` only waits for appearance #testing
- [gotcha] A UI-test fixture home is only honored when it carries the `.scarf-test-home-marker` sentinel, so ScarfUITestCase REFUSES to copy an unmarked SCARF_UITEST_FIXTURE — without that check a mistyped path (or a well-meant `~/.hermes`) would silently drop the run onto the developer's real Hermes home #testing #isolation

- [gotcha] `typeText`/`click` can raise "Failed to synthesize event: Timed out while synthesizing event", which XCTest records as a test FAILURE the instant it happens — a plain retry loop never reaches attempt 2, it just reports attempt 1. Non-strict `XCTExpectFailure` around every attempt BUT THE LAST is what makes a retry real (`ScarfUITestCase.setText`) #testing #gotcha
- [gotcha] Typed text also drops characters silently — observed "UI Gate Journey" landing as "UI Gate Journ" and as "UI Gate Journeys". Never assume a `typeText` landed: read the element's `value` back and compare. This is load-bearing for any field PRE-FILLED with a real user path (NewProjectSheet's parent dir defaults to `~/Projects` and satisfies `canCommit`), where a lost keystroke scaffolds into the developer's own directory — a path `SCARF_HERMES_HOME` does not isolate #testing #isolation
- [constraint] Two XCUITest runs on one Mac (two agents, two DerivedData) make every journey flaky: the apps ping-pong for the frontmost slot, steps slow 2-3x, and failures move around ("Failed to activate application (current state: Running Background)", a different sweep section failing each run). Calling `app.activate()` unconditionally makes it WORSE. `build-detached.sh` quitting every running copy also kills another agent's app under test ("Application com.scarf.app is not running") — UI-test runs must be serialized across agents #testing #gotcha


## Relations
- relates_to [[UI gate: section root identifiers and the Smoke/Full/Live test plans]]
- relates_to [[UI release gate: XCUITest is the gate, Harness is exploratory, fixture home built by the hermes CLI]]


## A gate FAIL that ran zero tests (t-6fec1932, 2026-09-21)

- [gotcha] The runner can die before any test runs: `The test runner failed to initialize for UI testing. (Underlying Error: Timed out while enabling automation mode.)`, recorded in the result bundle as a `System Failures` suite with no test nodes at all. Observed on the FIRST `ui-gate.sh --smoke-only` against cold DerivedData, with the console session unlocked and on-console and no second run on the Mac — a plain re-run with the same `--derived-data` passed. It is a testmanagerd/automation-mode init timeout, not a product failure #testing #gotcha
- [gotcha] ui-gate.sh renders that case as `FAIL` with `UI: ? executed / ? failed` in the summary table, which reads exactly like a real test failure. The `?` is the tell: the script parses its total from the last `Executed N tests…` line, and a runner that never initialized emits none. ALWAYS check for an `Executed` line before hunting an app bug — `xcrun xcresulttool get test-results tests --path <bundle>` names the real cause in one call #testing #gotcha
- [convention] A UI test that asserts HERMES CLI behaviour (not Scarf behaviour) rots when the agent is upgraded, and presents as a gate failure on a correct host. Two hit at once on 2026-09-21: `cron list` began including paused jobs (upstream `3f399c0bd4`), and the fixture's own growth broke a hard-coded card count. Assert such facts against the installed CLI's source per C5, name the row/job you mean rather than a total, and scope a listing read to the matching LINE — the fixture seeds paused cron jobs and kanban cards of its own, so an unscoped `contains` passes on a neighbour #testing #hermes
