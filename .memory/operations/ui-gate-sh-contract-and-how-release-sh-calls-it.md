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

scripts/ui-gate.sh is the standalone entry point for the UI release gate (t-b7d43521, phase 3 of the 2026-09-08 UI gate plan); scripts/release.sh calls it before the archive step.

## Observations
- [fact] scripts/ui-gate.sh builds the seeded fixture (make-ui-fixture.sh --self-check) into TMPDIR, then runs Full and Live plans (or just Smoke with --smoke-only; --skip-live drops Live) against ONE -derivedDataPath (--derived-data reusable) with a per-plan -resultBundlePath; --keep-fixture skips fixture cleanup
- [fact] Streams xcodebuild through `grep --line-buffered` (never tail), keeps full per-plan logs under a TMPDIR logs/ dir, and writes a markdown summary (date, git hash, hermes version, per-plan pass/fail with the XCTest UI total — parsed from the LAST "Executed N tests, with [K skipped and] F failures" line, since per-class lines precede it — plus the Swift Testing "Test run with N tests in M suites" unit total, wall time, result bundle path, fixture build time) to --summary <file> or stdout
- [fact] release.sh runs `scripts/ui-gate.sh --summary "$RELEASE_DIR/UI-GATE.md"` after preflight and BEFORE the version bump (moved 2026-09-08: a failed gate leaves no stray bump commit, and the bump commit `git add`s UI-GATE.md so each release carries its gate evidence); failure aborts via die(). On a resume run pass --skip-ui-tests if the gate already passed for that tree. `--skip-ui-tests` bypasses it with a loud multi-line warn() and writes 'SKIPPED by --skip-ui-tests' into UI-GATE.md instead
- [fact] Measured 2026-09-08 on Alan's Mac: --smoke-only = 74s fixture + 179s tests; --skip-live (Full) = 44s fixture + 507s tests, 14 executed/2 failed. Both runs FAILED on real app bugs (Dashboard error.banner, TemplateInstallUITests sidebar-suffix journey), not gate-script bugs. RESOLVED 2026-09-21 (t-6fec1932): neither reproduces and no app change was needed. The Dashboard banner was the SQLITE_CANTOPEN "Can't read Hermes state" read error that `d8f8b090` fixed two minutes after ui-gate.sh landed that same morning (a WAL state.db with no `-shm` sidecar — exactly the shape of a CLI-seeded fixture home); the TemplateInstall journey now passes end to end. Do not re-hunt these. Fixture dirs confirmed removed after each run unless --keep-fixture
- [gotcha] Exits non-zero on any plan failure or infra problem (missing xcodebuild, missing test plan file, non-existent --summary dir, failed fixture build) so a failed gate cannot be mistaken for a pass; --skip-ui-tests arg-parse/warn/summary logic was verified via an isolated standalone copy since release.sh's preflight (xcconfig, git-clean, signing cert, notarytool, Sparkle keypair) dies before reaching the gate hook without a maintainer's full signing setup

## Relations
- relates_to [[UI release gate: XCUITest is the gate, Harness is exploratory, fixture home built by the hermes CLI]]
- relates_to [[Build and Release Workflow]]
