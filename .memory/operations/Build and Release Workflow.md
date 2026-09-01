---
title: Build and Release Workflow
type: note
permalink: scarf/ops/build-and-release-workflow
tags:
- build
- release
- ci
created: 2026-05-29
updated: 2026-06-06
source_sha: 2b9ef15cdddcb1fde12a88556bf755a623ae7758
reviewed: 2026-07-12
reviewed_by: audit:claude-code (audit)
source_paths: scripts/release.sh, scripts/local-build.sh
---

## Observations
- [build] Debug build: `xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build`. For unsigned CLI debug build without Apple Developer account: ./scripts/local-build.sh #build
- [tooling] Requires Xcode 16.0+ to build from source #tooling
- [release-rule] NEVER run manual `xcodebuild archive` / `notarytool` / `gh release create` steps. Always use ./scripts/release.sh — manual steps skip or misorder critical actions #release #rule
- [release-cmd] Full release: `./scripts/release.sh <version>` — bumps version, archives Universal (arm64+x86_64) and ARM64-only variants, signs with Developer ID, notarizes via xcrun notarytool (keychain profile `scarf-notary`), staples, EdDSA-signs Sparkle appcast, pushes appcast to gh-pages, creates GitHub release with both zips #release
- [release-cmd] Draft release: `./scripts/release.sh <version> --draft` — builds + notarizes + uploads, skips appcast/tag so current version stays 'latest' until promoted #release
- [release-notes] Write release notes to releases/v<version>/RELEASE_NOTES.md BEFORE running the script — auto-included in version-bump commit and used as GitHub release body. Absent → placeholder used #release
- [canonical-prompts] Triggering phrases: 'Release v1.6.2', 'Release v1.6.2 as draft', 'Prepare v1.6.2 release notes from recent commits, then release' #release
- [prereqs] One-time setup on Alan's machine: Developer ID Application cert in login Keychain (team 3Q6X2L86C4), notarytool keychain profile `scarf-notary`, Sparkle EdDSA private key in Keychain item `https://sparkle-project.org`, gh-pages branch + GitHub Pages enabled #setup
- [sparkle-key-constraint] The Sparkle private key is per-machine — Keychain items don't sync between Macs by default. Running `release.sh` from a fresh machine WITHOUT importing the production key (or after running `generate_keys`, which mints an unrelated keypair) produces an appcast signature no installed Scarf can verify. v2.10.2 shipped this way and had to be re-signed same-day. `release.sh` now refuses to proceed if the Keychain pubkey doesn't match `Info.plist:SUPublicEDKey`. Recovery / fresh-machine import procedure: [[Sparkle Key Recovery]] #setup #release #gotcha
- [distribution] Two artifacts per release: Scarf-vX.X.X-Universal.zip (arm64+x86_64) and Scarf-vX.X.X-ARM64.zip (smaller, Apple Silicon only). Auto-updates via Sparkle (daily check + manual) #distribution
- [icloud-gotcha] Repo lives in iCloud Drive — `release.sh` must build under `${TMPDIR}/scarf-release-build`, NOT `$REPO_ROOT/build`, or codesign verify fails with `"Disallowed xattr com.apple.FinderInfo"`. See [[Releases under iCloud Drive]] for the full story #gotcha

## Relations
- documented_in [[Wiki Maintenance Workflow]]
- constrained_by [[Releases under iCloud Drive]]
- constrained_by [[Sparkle Key Recovery]]