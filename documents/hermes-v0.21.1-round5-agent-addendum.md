# Round-5 remediation — addendum to the shared phase brief

Read `documents/hermes-v0.21.1-parity-agent-brief.md` first; this addendum overrides it where they differ.

## Overrides

- **Branch:** `fix/whole-surface-audit-r5` (already checked out, from `main` at `59fffa19`). Commit there only. Never push. Never `git add` a managed tier (`.memory/`, `wiki/`, `design/`, `documents/`, `TASKS.md`, `tasks/`); leave them dirty. **Commit with `git commit -- <paths>` naming only the files you changed** — never `git add -A` / `git add .`, and never a bare `git commit` after staging: another agent may share the tree.
- **Findings source:** `documents/hermes-v0.21.1-whole-surface-audit-round5.md`. Your task (`get_task <id>`) lists your items with file:line; the round-5 report carries the reviewer text.
- **Product decisions:** the "Round-5 product decisions (Alan, 2026-09-12)" section at the end of `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md` is binding. Read it with `sed -n '/Round-5 product decisions/,$p' .memory/decisions/hermes-v0-21-1-compatibility-decisions.md`. Also read the "Round 5 — merge of P39–P46" and "P46b" sections just above it (`sed -n '/^## Round 5 — merge/,/^## Round-5 product/p'`), which carry this round's lessons.
- **Hermes checkout for tag walks:** `~/.hermes/hermes-agent` (`git -C ~/.hermes/hermes-agent show v2026.9.7:<path>`). Target tag `v2026.9.7` (= Hermes v0.21.1). Never touch its working tree. A tag walk means OPENING the file at each tag you cite, not grepping.
- **Commit prefix:** `fix(p47):` … `fix(p51):` per your phase. One commit per logical unit.

## Lessons from P39–P46b that bind this round

1. **Ask which axis the consumer keys on.** Before scoping a fix (by platform, by file name, by membership), find the reader and confirm what it resolves by; three round-4 fixes were correct for the case in hand and wrong one axis over.
2. **The exit-0 family is enumerated by grepping `runHermesCLI(` callers**, not by verb. When your phase touches a CLI verdict, list every caller on that path and judge each on its output; a site that re-judges by exit code one layer above a correct verdict is a bug.
3. **The optimistic mirror has an idle twin.** When a fix lands on one member of a `case`/arm family, walk the siblings before committing.
4. **A hint that names a remedy is walked like a button** — cite the Hermes source showing the gesture is accepted on that record, on EVERY arm the copy renders for.
5. **Grep both targets** (`scarf/scarf/`, `scarf/Packages/ScarfCore/`, and `scarf/Scarf iOS/` for iOS twins) for the same shape before calling a primitive fix done.
6. **A doc comment asserting the sibling is safe needs its own citation.**
7. **Test-host stability sweep** (`scarf/scarfTests/HermesP38SourceSweepTests.swift`): no array subscript after a count `#expect` (use `try #require`), no `try!`/`try?` on `#require`, no force-unwrap, no fixed sleep ≥ 500 ms without a written reason. **Its scope is the whole test tree** since P48 landed decision 7: `isInSweepScope`, `branchTouchedTestFiles`, `isPhaseSuite` and `legacySuiteFiles` are deleted, the 89 pre-existing subscript sites are fixed, and **phases after P48 append nothing** — just keep your own test files clean. A fixed sleep ≥ 500 ms needs an entry in `allowedFixedSleeps` with a written reason.
8. **"Pre-existing" needs proof:** a failing test is pre-existing only when it reproduces on a `main` worktree.
9. **`-only-testing` needs the suite name and nested suites need the parent path** (`-only-testing:scarfTests/Outer/Inner`); a filter that matches nothing still prints TEST SUCCEEDED — confirm a non-zero test count.
10. **A parameter that IS the fix gets no default.**

## Tests

- **NEVER run the UI tests (`scarfUITests`, `xcodebuild test` without `-only-testing:scarfTests`, or `./scripts/build-detached.sh`).** Unit tests only. Do not launch the app.
- Every fix ships with a test that fails without the fix. Name the file after the phase (`…P47Tests.swift`) in the suite where the surrounding code's tests live (ScarfCore package tests for ScarfCore code; `scarf/scarfTests` for the app target).
- ScarfCore: `cd scarf/Packages/ScarfCore && swift test` (rerun a flaky suite with `--filter`; `ACPClientStartIdempotenceTests` is a known parallel-load flake, t-f3820038).
- Mac app tests: `xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf -destination 'platform=macOS' -parallel-testing-enabled NO -skipPackagePluginValidation -derivedDataPath /private/tmp/claude-501/-Users-awizemann-Developer-Scarf/ad9f520b-5145-47e3-8819-c29e79d1292b/scratchpad/dd-<phase> -only-testing:scarfTests` — serial is the usable signal. At minimum run your own new suite(s) plus the suites of the files you touched; the orchestrator runs the full serial pass after P51.
- iOS: build `xcodebuild -project scarf/scarf.xcodeproj -scheme "scarf mobile" -destination 'generic/platform=iOS Simulator' build` when you touch `scarf/Scarf iOS/`.
- Scripts: `python3 -m unittest discover -s scripts/tests` when you touch `scripts/`.

## Report back (in addition to the brief's list)

For each finding in your task: fixed (commit), deliberately not fixed (why, and the task you filed), or already fixed by an earlier phase (cite the commit). Name every Hermes citation you re-opened. List the test files you appended to the sweep's scope list.
