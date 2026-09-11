# Round-4 remediation — addendum to the shared phase brief

Read `documents/hermes-v0.21.1-parity-agent-brief.md` first; this addendum overrides it where they differ.

## Overrides

- **Branch:** `fix/whole-surface-audit-r4` (already checked out). Commit there only. Never push. Never `git add` a managed tier (`.memory/`, `wiki/`, `design/`, `documents/`, `TASKS.md`, `tasks/`); leave them dirty. Stage only the files you changed, by path — never `git add -A` / `git add .`.
- **Findings source:** `documents/hermes-v0.21.1-whole-surface-audit-round4.md` (not the v0.21.1 audit report). Your task (`get_task <id>`) lists your items with file:line; open the round-4 report for the full reviewer text of each.
- **Product decisions:** the "Round-4 product decisions (Alan, 2026-09-11)" section at the end of `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md` is binding. Read it with `sed -n '/Round-4 product decisions/,$p' .memory/decisions/hermes-v0-21-1-compatibility-decisions.md`.
- **Hermes checkout for tag walks:** `~/.hermes/hermes-agent` (`git -C ~/.hermes/hermes-agent show v2026.9.7:<path>`). Target tag `v2026.9.7` (= Hermes v0.21.1). Never touch its working tree.
- **Commit prefix:** `fix(p39):` … `fix(p44):` per your phase. One commit per logical unit.

## Lessons from P30–P38 that bind this round (from the "Round 4" section of the decisions note)

1. **The exit-0 refusal is a family.** Do not judge one `-> None` handler; when your phase touches a CLI verdict, enumerate every handler on that verb's path from the tagged source and judge them all.
2. **Grep both targets.** When a fix names a primitive (a helper, an emitter, a decoder), grep the app target (`scarf/scarf/`) AND `scarf/Packages/ScarfCore/` (and `scarf/ScarfGo/` where iOS has a twin) for the same shape before calling it done.
3. **A hint that names a remedy is walked like a button.** Any copy that tells the user to do X must cite the Hermes source that shows X is accepted on that record.
4. **A doc comment asserting the sibling is safe needs its own citation.** Do not write "every X refusal exits 1" unless you opened every arm.
5. **Open the tagged blob for every line number you touch.** A sweep that adds a path prefix is not a walk.
6. **Test-host stability is enforced by the P38 source sweep** (`scarf/scarfTests/…P38…` stability tests): no array subscript after a count `#expect` (use `try #require(x.first)` or a `guard`), no `try!`, no force-unwrap in Swift Testing tests. Your new test files must pass that sweep; run it.
7. **"Pre-existing" needs proof:** a failing test is pre-existing only when it reproduces on a `main` worktree.
8. **A `-only-testing` filter that matches nothing still prints TEST SUCCEEDED.** Confirm a non-zero test count.

## Tests

- **NEVER run the UI tests (`scarfUITests`, `xcodebuild test` without `-only-testing:scarfTests`, or `./scripts/build-detached.sh`) — they take over Alan's Mac and he needs it today.** Unit tests only: `-only-testing:scarfTests` on the Mac target and `swift test` for ScarfCore. Do not launch the app.

- Every fix ships with a test that fails without the fix. Name the file after the phase (`…P39Tests.swift`) in the suite where the surrounding code's tests live (ScarfCore package tests for ScarfCore code; `scarf/scarfTests` for the app target).
- ScarfCore: `cd scarf/Packages/ScarfCore && swift test` (rerun a flaky suite with `--filter`).
- Mac app tests: `xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf -destination 'platform=macOS' -parallel-testing-enabled NO -skipPackagePluginValidation -derivedDataPath /private/tmp/claude-501/-Users-awizemann-Developer-Scarf/703860bb-c079-48ac-8974-0cd4b36c5d95/scratchpad/dd-<phase> -only-testing:scarfTests` — serial is the usable signal. At minimum run your own new suite(s) plus the suites of the files you touched; the orchestrator runs the full serial pass after P44.
- Scripts: `python3 -m unittest discover -s scripts/tests` when you touch `scripts/`.

## Report back (in addition to the brief's list)

For each finding in your task: fixed (commit), deliberately not fixed (why, and the task you filed), or already fixed by an earlier phase (cite the commit). Name every Hermes citation you re-opened.
