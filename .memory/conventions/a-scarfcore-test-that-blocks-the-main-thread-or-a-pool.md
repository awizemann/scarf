---
title: A ScarfCore test that blocks the main thread or a pool thread fails unrelated suites in the full run
type: note
permalink: scarf/conventions/a-scarfcore-test-that-blocks-the-main-thread-or-a-pool
tags: [testing, flake, concurrency, main-actor, cooperative-pool, scarfcore]
source_paths: [scarf/Packages/ScarfCore/Tests/ScarfCoreTests/HermesP55Tests.swift, scarf/Packages/ScarfCore/Tests/ScarfCoreTests/M1ACPTests.swift]
source_paths_inferred: false
source_sha: 18806e7c4dbac0ffd6ff7e91c12d27440d0a8cc5
created: 2026-09-18
updated: 2026-09-21
reviewed: 2026-09-19
reviewed_by: audit:claude-code (background)
---

Found on feat/voice (t-f1593849). The full ScarfCore `swift test` failed about 2 of 3 runs, always M1ACPTests at its `waitFor`. Those tests passed under `--filter`, and main passed. The cause was in OTHER tests, which blocked the executors M1ACPTests hops through. `swift test` runs ~3,500 tests in one process. There is one main thread and one cooperative pool, and the pool is as wide as the core count (10 here).

## Observations
- [gotcha] A synchronous `@MainActor` test holds the MAIN THREAD for its whole body. `HermesP55GoalMirrorTests.mirrorStateIsGoneFromEveryTarget` (a repo-wide regex sweep) ran 26 s alone and 30-97 s in the full run. Any `@MainActor` test that was mid-`await` (M1ACPTests, M4ACPIOSTests, the WKWebView tests) could not get back onto the main actor and timed out. Running just `--filter 'M1ACPTests|HermesP55GoalMirrorTests'` reproduces it. Main passed only by ordering luck, because its M1ACP bodies queued behind the sweep. Rule: a test that needs no main-actor state is never `@MainActor`, and a sweep compiles ONE pattern, not one per symbol per file #testing #flake
- [gotcha] A sync test that waits on a child process parks a cooperative-pool thread for the child's whole life. The old `ShellTestRunner` did this with a `DispatchSemaphore`, and the Hermes ACP-import contract tests held 2 of 10 threads for 11 s+ under load. `ShellTestRunner.run` is `async` now: it resumes from `terminationHandler`, the timeout is a dispatch timer, and the parent's handles close right after spawn. `ShellTestRunnerPoolTests` is a rendezvous test (cores+4 children must all be alive at once) that fails against a blocking runner. A `.enabled` trait that shells out uses the async closure form #testing #c10
- [gotcha] Moving the victims OFF the main actor made it WORSE: M1ACPTests without `@MainActor` failed 5/5, even with every new suite skipped. The pool queue in the full run is the deeper wait. Fix the hog; don't relocate the victim #testing
- [decision] M1ACPTests/M4ACPIOSTests `waitFor` is a 30 s ceiling (was 2 s). It returns as soon as the predicate holds, so only a failing test pays it. It was raised only after the hogs were fixed, because trivial argv tests in the same loaded run still waited 10 s for a pool thread #testing
- [gotcha] A WebKit test's timing must use the PAGE's clock. `aDisconnectIsLostOnlyAfterTheGrace` slept in Swift around a 150 ms JS grace timer and failed whenever a round trip to the page took longer than the grace. Put both `setState` calls and the waits in one `callAsyncJavaScript`, where page timers fire in due order. Separately, the WKWebView lifecycle makes WebKit dlopen AVKit and build an `AVRoutePickerView` on the main thread (WebMediaSessionManager), which costs about a second under load #testing

## Relations
- relates_to [[Process.waitDraining lives in ScarfCore — the two halves of a piped spawn, and the poll-interval trap]]
- relates_to [[A @MainActor suite cannot test detached-read interleaving — such tests pass with the fix removed]]
- relates_to [[Fast test-iteration commands (swift test vs xcodebuild)]]


## Swift Testing macro gotcha (2026-09-21, t-f0a94093)

- [gotcha] `#require(…)` / `#expect(…)` cannot wrap a **mutating** call on a local `var` struct: the macro expands the expression into a closure (`Testing.__checkFunctionCall(state.self, calling: { $0.beginPoll() })`) and `$0` is a `let`, so it fails to compile with `cannot use mutating member on immutable value: '$0' is immutable` — a message that points at generated code and reads like a concurrency error. It also emits a bogus "no calls to throwing functions occur within 'try'" warning alongside. Call the mutating method on its own line into a local, then require/expect the local: `let claimed = state.beginPoll(); let issued = try #require(claimed)`. Hit while testing `KanbanChatBadgeState`'s id-tagged poll claim #testing #gotcha
