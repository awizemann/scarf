---
title: A source-scan test must be calibrated against the target's default actor isolation
type: note
permalink: scarf/conventions/a-source-scan-test-must-be-calibrated-against-the-target-s
tags: [testing, concurrency, c10, verification]
source_paths: [scarf/scarfTests/MainActorSpawnDisciplineP22Tests.swift, scarf/scarf.xcodeproj/project.pbxproj, scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift]
source_paths_inferred: false
source_sha: b114f72fcfbabf7abe398123c841957874af59eb
created: 2026-09-10
updated: 2026-09-13
reviewed: 2026-09-14
reviewed_by: audit:claude-code (background)
---

Written in P37 of the round-3 whole-surface audit, after the first draft of `MainActorSpawnDisciplineP22Tests.noNewSynchronousWaitRunsOnTheMainActor` passed while `HealthViewModel.dashboardListenerPID` sat right there doing an `lsof` wait on the main actor. The failure was not in the rule being checked but in the test's model of the language, and the same four mistakes are available to any future scan test.

## Observations
- [gotcha] Scarf's app targets build with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`scarf.xcodeproj/project.pbxproj:606,649,910,947`), so in `scarf/scarf` and `Scarf iOS` EVERY declaration is main-actor-isolated unless it says `nonisolated` - and almost nothing says `@MainActor` anywhere. A C10 scan that looks FOR an `@MainActor` line therefore finds nothing and passes while real violations sit in plain sight. The gate is per-root: default-isolated target means a hit unless the declaration chain opts out; ScarfCore (no default isolation) means a hit only when the type carries `@MainActor` #concurrency #testing
- [convention] A scan test must assert the HIT COUNT equals the allowlist size, not only that the offender list is empty. `#expect(offenders.isEmpty)` passes identically when the scan is correct and when its matcher has quietly stopped matching; `#expect(hits == allowed.count)` fails loudly in the second case and is the only thing that proves the test is still a test #testing #verification
- [convention] Walk OUT to enclosing declarations by INDENT, never by nearest-func-above or any-line-above. Nearest-func lands on a nested local helper (`func closePipes` inside a `nonisolated func unzip`) and reports three already-correct sites; scanning every line above finds an unrelated `nonisolated` hundreds of lines away and excuses a real one. Only a line indented strictly less than everything seen so far encloses the site #testing
- [convention] Every allowlist entry in a scan test carries a task id AND an assertion that the debt still exists, so a fixed-or-renamed site cannot leave a stale entry silently hiding the next violation. P37 shipped two: `AppRelauncher.relaunch()` (t-b15ba4c3) and `HealthViewModel.dashboardListenerPID` (t-cd9fd829). **Both are now CLOSED** — P38 gave `dashboardListenerPID` the bounded primitive and round-4 P43 took `relaunch()` — so `allowed` is EMPTY and the `isolatedScanned == allowed.count` floor is `0 == 0`, which proves nothing on its own. That is exactly why `MainActorSpawnDisciplineP22Tests.theSweepMatcherStillRecognisesEveryShape` plants each shape and each near-miss against the named matcher, and why P43b added a `filesScanned` premise floor: an emptied allowlist has to be replaced by a calibration test or the sweep silently stops being a test #testing #conventions
- [gotcha] Prove a scan test bites by PLANTING a violation, in both directions: a file with no `@MainActor` line at all (caught only once the default-isolation gate was right) and a `nonisolated` function with a nested helper (must be excused). A scan test that has never been shown to fail is a checkbox #testing

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Unguarded-write seam: the primitive is named, and a scan test keeps it honest]]


## Round-5 P48 — what the scan tests look like now

- [invariant] **`HermesP38SourceSweepTests` is REPO-WIDE and has no scope predicate.** The
  `isInSweepScope` / `isPhaseSuite` / `branchTouchedTestFiles` / `legacySuiteFiles` machinery and
  the `theBranchScopeIsFullyScanned` deletion floor are all deleted (round-5 decision 7). All
  three rules — no subscript after a count `#expect`, no `try? #require`, no fixed sleep ≥ 500 ms
  without a written reason — run over every `.swift` file under `scarf/scarfTests`,
  `scarf/Scarf iOSTests` and `scarf/Packages/ScarfCore/Tests`. **Future phases append nothing**,
  which is what the scoping cost in maintenance every round. The premise floor is a plain file
  count (484 real, floor 300) #testing
- [fact] The scoping was a sequence of honest compromises, not a mistake: P38 hand-listed 17 phase
  suites, P45 replaced the list with a phase-NAME pattern (finds new phase suites by construction,
  reads nothing a phase writes in an ordinarily-named file), P46 added the branch's touched files
  by PATH (which closed that and found seven more). Every step was bounded by "a repo-wide run
  reports ~90 pre-existing sites, and a sweep that fails on day one is a sweep somebody disables".
  P48 is the day those 89 were fixed — each by turning the count `#expect` into `try #require`,
  which stops the TEST rather than the host
- [convention] **A known false positive is TIGHTENED, never exempted by file.** P46's note listed
  `#expect(map["k"] != nil)` reading as a subscript on an unrelated `.count` receiver; P48 added
  the general rule behind it — an optional-chained subscript (`map[1]?.first`) is a `Dictionary`
  read and cannot trap, and the `?` right after the closing bracket is the proof, since an `Array`
  subscript is non-optional and cannot be chained that way #testing
- [convention] **A scan test's opt-out list is a claim about the language, and asymmetries must be
  pinned.** `MainActorSpawnDisciplineP22Tests` learned `Thread.detachNewThread` as an opt-out in
  P48 — a thread has no actor, so a wait inside one is off the main actor whatever the enclosing
  declaration says. `Task.detached` is emphatically NOT an opt-out (it is the same cooperative
  pool), and a test in `HermesP48Tests` asserts the sweep's source carries the first and not the
  second, because the two spellings look alike and mean opposite things #testing
- [invariant] **`ProcessAsyncWaitP43cTests` matches three shapes over two roots.** A blocking
  spelling directly in an `async` body; one inside a `Task { … }` / `Task.detached { … }` closure
  (the shape that hid all five `t-12d04477` app-target sites, each in a closure inside an ordinary
  `func`); and one reached through a SYNCHRONOUS helper declared in the same file that an `async`
  function there calls (the shape that hid `LocalTransport.runProcess` and
  `SSHTransport.runLocal`). Roots: `Sources/ScarfCore` and `scarf/scarf`. It does not follow a call
  across files, and the doc says so. Its allowlist is EMPTY and states why rather than carrying a
  comfortable entry: `HermesFileService.runShellProbe` is deliberately synchronous but no rule here
  matches it, because the sweep reads `func` declarations and not property initializers #testing
- [gotcha] **Widening a sweep is how you find out what the phase just wrote.** P48's widening
  immediately reported eleven live sites, most of them created by P48's own earlier commits in the
  same session. A sweep that only ever runs green on the diff that introduced it has not been
  tested against anything #verification


## Round-6 P58 — a sweep's NEEDLES are a claim about scope too, and a walker must not read prose

- [gotcha] **A sweep calibrated on the sites one phase fixed only ever finds those sites.**
  `OffPoolDisciplineP52Tests` knew exactly the two calls P51 got wrong (`enrichedEnvironment()`,
  `loadState()`), so a tree full of `Task.detached { fileService.runHermesCLI(…) }` reported TWO
  hits and passed — and P54 added six more while it was green. Widened to seven needles
  (`availableData`, `readDataToEndOfFile`, `waitUntilExit(`, `runHermesCLI(`, `runProcess(`), the
  same tree has 42. P53's lesson was about the MATCHER; this is the same lesson about the WORD LIST
  #testing #c10
- [convention] **Needle matching is identifier-bounded on the left, or the sweep reports the cure.**
  A plain `contains` makes `asyncRunProcess(` — the async seam round-6 decision 11 added — a
  `runProcess(` hit. The paren does the same job on the right: `waitUntilExit(` excludes
  `waitUntilExitAsync(`. A calibration test plants each cure as a near-miss
- [gotcha] **A brace-matching walker that does not strip comments reads PROSE as code.**
  `PipeReader.swift`'s doc comment spells the defect it replaced — `Task.detached { while true {
  handle.availableData } }` — and the walker matched from inside the sentence, then reported the
  needle. The per-line comment filter could not save it: the matched body starts MID-LINE, so it
  carries no `///`. Comments are blanked in place first, line count preserved. **A sweep whose first
  report is the documentation of the fix is a sweep the next phase stops reading** #testing
- [convention] **When a widened sweep finds more than a phase can fix, the remainder is a COUNTED
  baseline, never an exemption.** `pendingOffPoolSites` keys `basename:needle` to the number of hits
  and names `t-406d56d6`. An extra hit in a listed file is still a failure, and fixing one without
  taking it off the list is ALSO a failure — otherwise the baseline rots into a licence. A bare
  allowlist would have hidden both directions #testing
- [decision] **Two sweeps asking different questions need different opt-outs, so they are different
  tests.** `Task.detached` is deliberately NOT an opt-out for the P52 pool sweep and plainly IS one
  for the P22 "is this on the main actor" sweep. P58's `enrichedEnvironment()` check is therefore a
  separate test in the P22 suite rather than another needle in `isSynchronousWait` — folding it in
  would have had to weaken one of the two #c10 #testing
