---
title: Build and Release Workflow
type: note
permalink: scarf/ops/build-and-release-workflow
tags: [build, release, ci]
source_paths: [scripts/release.sh, scripts/local-build.sh]
source_sha: 01db68bc58591526915adb0ff47c6983d3a81118
created: 2026-05-29
updated: 2026-09-26
reviewed: 2026-10-29
reviewed_by: audit:claude-code (background)
---

## Observations
- [build] Debug build: `xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build`. For unsigned CLI debug build without Apple Developer account: ./scripts/local-build.sh #build
- [tooling] Requires Xcode 16.0+ to build from source #tooling
- [release-rule] NEVER run manual `xcodebuild archive` / `notarytool` / `gh release create` steps. Always use ./scripts/release.sh — manual steps skip or misorder critical actions #release #rule
- [ui-gate] Every release runs a two-stage UI release gate before version bump: 1) scripts/ui-gate.sh --unit-only (scarfTests on this Mac, headless + serial), then 2) scripts/ui-gate-vm.sh (Full and Live XCUITest plans in the scarf-ui Tart VM against Hermes HERMES_TARGET_TAG). Gate writes releases/v<VERSION>/UI-GATE.md; failing gate (any FAIL or RUNNER-FAILED) aborts release. Tart VM is booted headless if stopped. #release #gate #vm
- [ui-gate-host] Run all UI tests on this Mac instead of Tart VM with --host-ui-gate flag (~25 min, takes the screen). Useful if Tart VM setup is unavailable. #release #gate
- [ui-gate-bypass] Bypass gate with --skip-ui-tests flag (loud warning recorded in UI-GATE.md, not recommended — see BUILDING.md). Cannot be combined with --host-ui-gate or --gate-only. #release #gate
- [ui-gate-preflight] Run preflight + UI gate, then stop (no version bump, build, or commit) with --gate-only flag. Tree state recorded in UI-GATE.md; allows dirty tree or non-main branch for testing. Useful as a dry run before the real release. #release #gate
- [release-cmd] Full release: `./scripts/release.sh <version>` — runs two-stage UI gate (VM by default), bumps version, archives Universal (arm64+x86_64) and ARM64-only variants, signs with Developer ID, notarizes via xcrun notarytool (keychain profile `scarf-notary`), validates analytics channel stamping, extracts Sparkle minimumSystemVersion from built app, staples, EdDSA-signs Sparkle appcast, pushes appcast to gh-pages, creates GitHub release with both zips #release
- [release-cmd] Draft release: `./scripts/release.sh <version> --draft` — runs UI gate, builds + notarizes + uploads, skips appcast/tag so current version stays 'latest' until promoted #release
- [release-notes] Write release notes to releases/v<version>/RELEASE_NOTES.md BEFORE running the script — auto-included in version-bump commit and used as GitHub release body. Absent → placeholder used #release
- [canonical-prompts] Triggering phrases: 'Release v1.6.2', 'Release v1.6.2 as draft', 'Prepare v1.6.2 release notes from recent commits, then release' #release
- [prereqs] One-time setup on Alan's machine: Developer ID Application cert in login Keychain (team 3Q6X2L86C4), notarytool keychain profile `scarf-notary`, Sparkle EdDSA private key in Keychain item `https://sparkle-project.org`, gh-pages branch + GitHub Pages enabled, scarf-ui Tart VM (see scripts/ui-fixture/README.md for setup) #setup
- [tart-vm] Tart VM (scarf-ui) is required for the default release flow. On first run it boots headless, mounting this Mac's Xcode read-only and a work disk (SCARF_VM_WORK_DISK, default ~/.tart/scarf-ui-logs/scarf-work.img). VM stays running after release. Set DEVELOPER_DIR to ensure the VM and this script build with the same Xcode. #release #vm #setup
- [sparkle-key-constraint] The Sparkle private key is per-machine — Keychain items don't sync between Macs by default. Running `release.sh` from a fresh machine WITHOUT importing the production key (or after running `generate_keys`, which mints an unrelated keypair) produces an appcast signature no installed Scarf can verify. v2.10.2 shipped this way and had to be re-signed same-day. `release.sh` now refuses to proceed if the Keychain pubkey doesn't match `Info.plist:SUPublicEDKey`. Recovery / fresh-machine import procedure: [[Sparkle Key Recovery]] #setup #release #gotcha
- [analytics-channel] Every release stamps the built app with ScarfAnalyticsChannel=release and validates SwiftStatsWriteKey is present. Only release builds have this stamp; dev builds report as dev. release.sh checks both in the exported app before signing. #release #analytics #validation
- [sparkle-min-os] Sparkle appcast minimumSystemVersion is now extracted from the built app's LSMinimumSystemVersion plist (was hardcoded to 14.6 for 12 releases, outliving the 15.0 deployment-target bump). release.sh extracts it from the zip, validates it's a proper version string, and embeds it in the appcast. #release #sparkle
- [distribution] Two artifacts per release: Scarf-vX.X.X-Universal.zip (arm64+x86_64) and Scarf-vX.X.X-ARM64.zip (smaller, Apple Silicon only). Auto-updates via Sparkle (daily check + manual) #distribution
- [icloud-gotcha] Repo lives in iCloud Drive — `release.sh` must build under `${TMPDIR}/scarf-release-build`, NOT `$REPO_ROOT/build`, or codesign verify fails with `"Disallowed xattr com.apple.FinderInfo"`. See [[Releases under iCloud Drive]] for the full story #gotcha
- [gotcha] `release.sh` archives with whatever `DEVELOPER_DIR`/`xcode-select` resolves — on Alan's Mac that is Xcode-beta, whose compiler emits MainActor-default-isolation warnings (`#ActorIsolatedCall`, main-actor static lets read from nonisolated code) that the stable Xcode Debug builds and the UI gate never show; release.sh does not fail on warnings. Before a cut, run `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme scarf -configuration Release CODE_SIGNING_ALLOWED=NO build` (and the same for `scarf mobile` with `-destination 'generic/platform=iOS'`) and require zero Scarf warnings. Fixed to zero on 2026-09-26 (9df0ab9d); beta warnings are expected to return over time #release #warnings

## Relations
- documented_in [[Wiki Maintenance Workflow]]
- constrained_by [[Releases under iCloud Drive]]
- constrained_by [[Sparkle Key Recovery]]
- documented_in [[ui-gate.sh contract and how release.sh calls it]]
- documented_in [[scripts/ui-fixture/README.md]] (Tart VM setup)
