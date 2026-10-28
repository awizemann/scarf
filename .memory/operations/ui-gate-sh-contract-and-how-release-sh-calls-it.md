---
title: ui-gate.sh contract and how release.sh calls it
type: note
permalink: scarf/operations/ui-gate-sh-contract-and-how-release-sh-calls-it
source_paths: [scripts/release.sh]
source_paths_inferred: false
source_sha: 7c0b8a6367b4a0c476e0b1a38c63e597abac5af6
created: 2026-09-08
updated: 2026-09-21
reviewed: 2026-09-08
reviewed_by: audit:claude-code (background)
---

## Observations
- [fact] scripts/ui-gate.sh supports: --smoke-only (Smoke plan only), --skip-live (Full but not Live), --unit-only (Full's scarfTests only—no fixture, no UI, nothing on screen; pairs with scripts/ui-gate-vm.sh for the Full+Live UI tests in a Tart VM), --derived-data (reuse a DerivedData dir), --keep-fixture (skip cleanup), --summary FILE (markdown output, default stdout). Fixture is built via scripts/ui-fixture/make-ui-fixture.sh; runs plans serially (-parallel-testing-enabled NO); streams xcodebuild through grep --line-buffered; keeps per-plan logs under TMPDIR/logs/; writes markdown summary with date, git hash, Hermes version, per-plan verdict (PASS/FAIL/RUNNER-FAILED), XCTest UI totals (from final "Executed N tests" line) and Swift Testing unit totals ("Test run with N tests in M suites"), wall time, result bundle path, fixture build time.
- [fact] Exits non-zero on any fixture build failure, test plan failure, or runner failure (RUNNER-FAILED: no test ever executed, not a code failure). RUNNER-FAILED is reported separately from FAIL so environmental wedges don't look like code bugs #gate
- [fact] release.sh's DEFAULT UI release gate (no flags): 1. runs `scripts/ui-gate.sh --unit-only` on this Mac for scarfTests, then 2. boots the scarf-ui Tart VM and runs `scripts/ui-gate-vm.sh --plans Full,Live` against Hermes HERMES_TARGET_TAG from scripts/check-hermes-tables.py. Both summaries are merged into releases/v<VERSION>/UI-GATE.md before the version bump (RUNS BEFORE version bump so a failed gate leaves no stray bump commit; the bump commit carries UI-GATE.md as the release's own evidence). Failure aborts via die().
- [fact] release.sh --host-ui-gate: runs ui-gate.sh (all plans) on this Mac instead of the VM (~25 min, takes the screen), skipping the VM gate entirely. Same --summary behavior.
- [fact] release.sh --skip-ui-tests: bypasses the gate with a loud multi-line warn() and writes 'SKIPPED by --skip-ui-tests' into UI-GATE.md. Intended for resume runs where the gate already passed (pass --skip-ui-tests to reuse the prior gate result without re-running).
- [fact] release.sh --gate-only: NEW (2026-10-26). Runs preflight + the UI gate, then stops before version bump, build, or commit. Skips clean-tree and main-branch checks (the gate records the actual tree state in UI-GATE.md). A rehearsal: the real release run gates again, so --gate-only verifies the gate logic without committing.
- [gotcha] The default VM flow fails loud and early if: the scarf-ui Tart VM is not set up (error says to set up per scripts/ui-fixture/README.md or use --host-ui-gate), the Xcode.app this script builds with is not the one the VM boots with (guest shares host's Xcode read-only; mismatch means re-boot it or set DEVELOPER_DIR), the VM's work disk is missing (SCARF_VM_WORK_DISK env var points at it). The gate never silently downgrades to local.

## Relations
- relates_to [[UI release gate: XCUITest is the gate, Harness is exploratory, fixture home built by the hermes CLI]]
- relates_to [[Build and Release Workflow]]
