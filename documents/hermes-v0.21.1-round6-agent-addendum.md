# Round-6 remediation — addendum to the shared phase brief

Read `documents/hermes-v0.21.1-parity-agent-brief.md` first; this addendum overrides it where they differ.

## Overrides

- **Branch:** `fix/whole-surface-audit-r6` (already checked out, from `main` at `d53d3cbe`). Commit there only. Never push. Never `git add` a managed tier (`.memory/`, `wiki/`, `design/`, `documents/`, `TASKS.md`, `tasks/`); leave them dirty. **Commit with `git commit -- <paths>` naming only the files you changed** — never `git add -A` / `git add .`, and never a bare `git commit` after staging: another agent may share the tree.
- **Findings source:** `documents/hermes-v0.21.1-whole-surface-audit-round6.md`. Your task (`get_task <id>`) lists your items with file:line; the round-6 report carries the reviewer text.
- **Product decisions:** the "Round-6 product decisions (Alan, 2026-09-13)" section at the end of `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md` is binding. Read it with `sed -n '/Round-6 product decisions/,$p' .memory/decisions/hermes-v0-21-1-compatibility-decisions.md`. Also read the "Round 6 — merge of P47–P53" section just above it and the "P52 — cross-phase remediation" and "P53 — pre-merge remediation" sections (`sed -n '/^## P52 — cross-phase/,/^## Round-6 product/p'`), which carry this round's lessons.
- **Hermes checkout for tag walks:** `~/.hermes/hermes-agent` (`git -C ~/.hermes/hermes-agent show v2026.9.7:<path>`). Target tag `v2026.9.7` (= Hermes v0.21.1). Never touch its working tree. A tag walk means OPENING the file at each tag you cite, not grepping.
- **Commit prefix:** `fix(p54):` … `fix(p58):` per your phase. One commit per logical unit.

## Lessons from P39–P53b that bind this round

1. **Ask which axis the consumer keys on.** Before scoping a fix (by platform, by file name, by membership), find the reader and confirm what it resolves by.
2. **The exit-0 family is enumerated by grepping `runHermesCLI(` callers**, not by verb. When your phase touches a CLI verdict, list every caller on that path and judge each on its output; a site that re-judges by exit code one layer above a correct verdict is a bug.
3. **The optimistic mirror has an idle twin.** When a fix lands on one member of a `case`/arm family, walk the siblings before committing. **This includes the machinery a phase inherits** — the sweeps, their roots and their exemptions — not only the `case` arms and the files in your diff. P48 named `Task.detached` a false escape and its file-local sweep let P51 add three more; P53 widened sweep roots to ScarfIOS Sources and missed ScarfIOS Tests. When you learn a rule, find every sweep that should enforce it and confirm it does.
4. **A hint that names a remedy is walked like a button** — cite the Hermes source showing the gesture is accepted on that record, on EVERY arm the copy renders for.
5. **Grep both targets** (`scarf/scarf/`, `scarf/Packages/ScarfCore/`, `scarf/Packages/ScarfIOS/` and `scarf/Scarf iOS/` for iOS twins) for the same shape before calling a primitive fix done.
6. **A doc comment asserting the sibling is safe needs its own citation.** And **a number or citation in a comment is a claim nobody executes** — "484 test files" was 335, a `file:line` range was pasted to three sites and was wrong at all three. Pin a count or a line range with a test that re-measures it, or do not write the number.
7. **Test-host stability sweep** (`scarf/scarfTests/HermesP38SourceSweepTests.swift`): no array subscript after a count `#expect` (use `try #require`), no `try!`/`try?` on `#require`, no force-unwrap, no fixed sleep ≥ 500 ms without a written reason. Its scope is the whole test tree; phases append nothing — keep your own test files clean. A fixed sleep ≥ 500 ms needs an entry in `allowedFixedSleeps` with a written reason. **Every source-scan test you write is brace-matched when the thing it matches spans lines, counts URLs not basenames, has a per-root floor, and is calibrated with a planted needle.**
8. **"Pre-existing" needs proof:** a failing test is pre-existing only when it reproduces on a `main` worktree.
9. **`-only-testing` takes the SUITE name, which is NOT the file name.** For `-only-testing` the identifier is the suite's TYPE name (`struct HermesP38SourceSweepTests`), never the `@Suite("…")` display string and never the `.swift` file name — P56's reviewer proved the display string matches zero tests and still prints TEST SUCCEEDED. Nested suites need the parent path (`-only-testing:scarfTests/Outer/Inner`). A filter that matches nothing is silently dropped and the run still prints TEST SUCCEEDED over whatever else matched. Before you trust a filtered run: `grep -n '@Suite\|^struct\|^final class' <file>` to read the real suite names, build the filter from them, and confirm the "Executed N tests" line shows the count you expected (never 0, and equal to the number of `@Test`s in the suites you named).
10. **A parameter that IS the fix gets no default.**
11. **Cite a tag, never a release.** A release note can announce a feature that was reverted in the same release (`hasKanban` at 0.12). Every floor is `git show <tag>:<path>` opened at the floor tag AND the tag before, and the doc cites the tag.
12. **When a verdict has a `confidence` / `.unconfirmed` arm, grep every consumer for a two-way `if`.** P47b fixed one consumer and left its sibling from the same commit.
13. **C1 for an ADDED gate is argued on every version range outside the window.** A gate added to a previously ungated surface removes the control on every range outside it; the source says which ranges render differently than the last release, and why that is correct.
14. **Every validation `cron edit` performs must live in the iOS `jobs.json` form.** iOS writes what the CLI would have validated; no argparse stands behind the write.
15. **`Task.detached` is not an opt-out; `OffPool.run { }` is.** Blocking work (a sync SSH read, a process wait, `enrichedEnvironment()`) goes through `OffPool.run`, never `Task.detached`. The brace-matched sweep in `scarfTests` enforces it across all three roots; do not add an exemption.

## Tests

- **NEVER run the UI tests (`scarfUITests`, `xcodebuild test` without `-only-testing:scarfTests`, or `./scripts/build-detached.sh`).** Unit tests only. Do not launch the app.
- Every fix ships with a test that fails without the fix. Name the file after the phase (`…P54Tests.swift`) in the suite where the surrounding code's tests live (ScarfCore package tests for ScarfCore code; ScarfIOS package tests for ScarfIOS code; `scarf/scarfTests` for the app target).
- ScarfCore: `cd scarf/Packages/ScarfCore && swift test` (rerun a flaky suite with `--filter`; `ACPClientStartIdempotenceTests` is a known parallel-load flake).
- ScarfIOS: `cd scarf/Packages/ScarfIOS && swift test` when you touch it.
- Mac app tests: `xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf -destination 'platform=macOS' -parallel-testing-enabled NO -skipPackagePluginValidation -derivedDataPath /private/tmp/claude-501/-Users-awizemann-Developer-Scarf/55131d9b-1064-4223-b4c3-e522792de0a8/scratchpad/dd-<phase> -only-testing:scarfTests/<SuiteName>` — serial is the usable signal. At minimum run your own new suite(s) plus the suites of the files you touched (lesson 9); the orchestrator runs the full serial pass after P58.
- iOS: build `xcodebuild -project scarf/scarf.xcodeproj -scheme "scarf mobile" -destination 'generic/platform=iOS Simulator' build` when you touch `scarf/Scarf iOS/` or `scarf/Packages/ScarfIOS/`.
- Scripts: `python3 -m unittest discover -s scripts/tests` when you touch `scripts/`.

## Report back (in addition to the brief's list)

For each finding in your task: fixed (commit), deliberately not fixed (why, and the task you filed), or already fixed by an earlier phase (cite the commit). Name every Hermes citation you re-opened. For every filtered test run, list the suite names you passed and the executed-test count.
