# Remediation phase agent brief (read fully before starting)

You own ONE phase of the Hermes v0.21.5 audit remediation. Your prompt names the phase ID (e.g. R01), its Memophant
task id, your worktree and branch, and the finding IDs. Plan: `documents/plans/hermes-v0215-audit-remediation-plan.md`.

## Paths
- MAIN checkout (read memory/wiki/documents here only): `/Users/awizemann/Developer/Scarf`
- YOUR worktree (all code edits, builds, tests, commits): `/Users/awizemann/Developer/Scarf-wt/<phase>` on branch
  `fix/hermes-v0215-audit-<phase>`. Never edit code in the main checkout or the integration worktree.
- Findings: `documents/audits/hermes-v0.21.5-full-app-audit.md` (ranked table) and the section reports + verifier
  verdicts in `documents/audits/hermes-v0.21.5-full-app-audit/` (`S??-*.md`, `VERDICTS.md`) — read the full entry for
  each of your findings, including evidence and suggested fix. Treat them as leads, not truth: re-verify each on both
  sides before changing code. If one turns out wrong, don't "fix" it — report it as REFUTED with evidence.
- Hermes reference: `~/.hermes/hermes-agent-v0215` (tag v2026.9.24, 0.21.5). Read-only. Do not use
  `~/.hermes/hermes-agent` for current behaviour; you MAY use it with `git log -S`/`git tag --contains` to find a
  symbol's true floor across tags (charter C1/C2).

## Project rules you must obey (charter excerpts — absolute)
- Read the charter first: memophant `read_charter`. C1 gate every Hermes-release-dependent behaviour on its true floor
  (HermesCapabilities flag or schema detection); older hosts must behave as before. C3 never write state.db. C5 every
  argv verified against the tagged argparse; never parse failure output as success. C6 exports land on the Mac.
  C7 never commit managed tiers. C8 never push. C9 no secrets in chat/files. C10 no spawn/SSH/state.db on the main actor;
  every subprocess has a timeout.
- Use plain English in comments and commit messages; match surrounding code style and comment density.

## Workflow
1. `update_task(id, status: "doing", plan: <your short plan>)`. The plan lists each finding, the intended fix, the
   blast radius (callers, Mac + iOS + remote), the tests you'll add, and the memory/wiki notes you'll review.
2. Ground yourself: `build_context`/`search_memories` for each area; read relevant notes. Check `TASKS.md` for
   related open tasks — if a finding is covered by an open task, fix it and note the task id in your report.
3. Implement. Reuse existing helpers; don't add abstractions you don't need. Keep changes scoped to your findings;
   if you find a NEW defect, fix it only if it's small and in your files, otherwise report it (don't widen scope).
4. Tests (real, not checkbox): exercise the behaviour, including the failure path and a round-trip where Scarf both
   writes and reads (write with Scarf → read with Scarf → where feasible check what Hermes would parse, e.g. by
   running the Hermes function from the reference worktree's `.venv` against a scratch HERMES_HOME under your
   worktree — never the real `~/.hermes`). Update tests that pinned the wrong behaviour; say so in the commit.
5. Build and test (from your worktree; use your own DerivedData `-derivedDataPath <worktree>/.dd`):
   - ScarfCore: `swift test --package-path scarf/Packages/ScarfCore --filter <Suite>` (and the whole package once at the end).
   - ScarfIOS if touched: `swift test --package-path scarf/Packages/ScarfIOS --filter <Suite>`.
   - App compile: `xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug -derivedDataPath .dd -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`.
   - iOS compile if you touched `Scarf iOS/` or ScarfIOS: scheme `scarf mobile`, `-destination 'generic/platform=iOS Simulator'`, same flags.
   - App tests: `xcodebuild test ... -destination 'platform=macOS' -only-testing:scarfTests/<SuiteTypeName> -parallel-testing-enabled NO` (type name, not display string; confirm a non-zero test count). Once at the end: `-only-testing:scarfTests` whole bundle, serial. Run long runs in the background with output to a file; pipe through `grep --line-buffered`, never `| tail`.
   - Never run `scarfUITests` / UI plans (the orchestrator does, serialized). Other agents build in parallel on this
     Mac: if a main-actor timeout test fails, rerun that suite alone and compare against the integration base before blaming your change.
6. Fresh-eyes audit: spawn ONE read-only reviewer sub-agent IN THE FOREGROUND (Agent tool with
   `run_in_background: false` — you must wait for its verdict; a phase is not complete without it) (general-purpose, model opus) with your diff
   (`git diff fix/hermes-v0215-audit...HEAD`), the finding entries, and the instruction to try to break the fixes:
   wrong on remote/SSH, older Hermes hosts, iOS, failure paths, C1/C3/C5/C10, tests that don't actually test the
   behaviour. Fix what's real; re-run affected tests. Record its verdict in your report.
7. Memory + wiki (part of the task, not optional):
   - For every finding, search memory (`search_memories`) and the MAIN checkout's `wiki/` (grep) for notes/pages that
     state the behaviour you changed or the premise that was wrong. Correct them with `edit_memory` (find_replace for
     targeted corrections) or wiki edits in the main checkout; retire notes that are now false (`retire_memory`).
   - Write new notes only for durable knowledge: architecture/contract changes, gotchas, recurring issue classes.
     Search first; extend an existing note rather than forking. File under one of the six folders; pass `source_paths`
     for code-grounded notes. Cite Hermes claims as `file:line @ v2026.9.24`.
   - Never edit `.memory/charter.md`; propose charter changes as a task tagged `charter`.
   - List every memory/wiki change in your report (path + one line).
8. Localization: do NOT edit `Localizable.xcstrings`. Use normal SwiftUI/`String(localized:)` patterns; list new
   user-facing strings in your report for the R13 i18n pass.
9. Commit on your branch, by path: `git -C <worktree> commit -- <paths>` with Conventional Commit messages
   (`fix(mcp): …`), one logical change per commit, ending with
   `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never stage managed tiers. Never push.
10. `update_task(id, artifacts: <commits, tests, memory changes>)` — leave status "doing"; the orchestrator moves it to done after its audit.

## Report back (under 40 lines)
Per finding: FIXED / REFUTED / PARTIAL + one line + commit sha. Tests added/updated (suite names, counts, pass).
Build results (Mac, iOS if touched). Full scarfTests result. Fresh-eyes verdict and what you changed after it.
Memory/wiki changes. New user-facing strings. New defects found but not fixed (file:line). Anything the orchestrator must decide.
