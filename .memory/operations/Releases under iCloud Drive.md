---
title: Releases under iCloud Drive
type: note
permalink: scarf/ops/releases-under-icloud-drive
tags:
- release
- codesign
- icloud
- gotcha
created: 2026-06-04
updated: 2026-06-04
source_sha: 1599452d48106de9c87bf5286d2b0f6eeee70adb
source_paths: scripts/release.sh, scarf/scarf/Info.plist
source_paths_inferred: false
reviewed: 2026-07-17
reviewed_by: audit:claude-code (background)
---

## Observations
- [constraint] The Scarf repo lives under `~/Library/Mobile Documents/com~apple~CloudDocs/Development/Scarf/` — iCloud Drive. iCloud's file-provider extension (fpfs) actively stamps `com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P` xattrs onto any bundle directory it observes, and re-attaches them within ~2 seconds of being stripped. `codesign --strict` rejects both, failing post-export verify with `"resource fork, Finder information, or similar detritus not allowed"` #codesign #icloud
- [fix] `scripts/release.sh` sets `BUILD_DIR="${TMPDIR:-/tmp}/scarf-release-build"` so the entire archive/export/staple/zip pipeline runs OUTSIDE iCloud. This is load-bearing — do not move BUILD_DIR back under `$REPO_ROOT` even if it seems tidier. The final distribution `.zip`s still land in `$REPO_ROOT/releases/v<VERSION>/` (zips are flat files; xattrs on the outer `.zip` don't affect the bundle inside) #fix #release
- [why-not-strip] A `xattr -drs` step was tried first (a65dc57) but didn't work: even after stripping the top-level bundle, iCloud re-added xattrs before `codesign --verify` ran, AND every nested .app/.framework (e.g. Sparkle's `Updater.app`) got tagged separately. The bundle-out-of-iCloud approach (e5ee888) is the durable fix #design-decision
- [defense-in-depth] The xattr-strip lines in `build_variant` are kept as cheap defense in case the path is ever accidentally moved back inside iCloud — they're no-ops in the normal case but cost nothing #defense
- [resume] `release.sh` is idempotent on the version bump — if MARKETING_VERSION already matches the requested VERSION, the bump+commit step is skipped. So a mid-pipeline failure can be retried by re-running the same `./scripts/release.sh <version>` without `git reset` #resume
- [new-machine-setup] When setting up signing on a new machine, the iCloud constraint is NOT obvious from prereqs — it surfaces only when codesign verify fails on the first build_variant. Symptom is the FinderInfo error above. If you see it on a fresh setup: confirm `BUILD_DIR` is set to TMPDIR (not $REPO_ROOT/build) and the issue resolves immediately #setup
- [credentials-on-this-machine] Developer ID Application cert hash `97042FD9A5AFD12161C4DAE2374415D04DAA01E5` (team 3Q6X2L86C4) imported from .p12. App Store Connect API key id `YK9BD2B26S`, issuer `6e7e83cb-afd5-4bc1-bc8b-46b3e0d46bcc`, `.p8` at `~/.private/AuthKey_YK9BD2B26S.p8` (chmod 600), registered as notarytool keychain profile `scarf-notary`. Sparkle EdDSA private key already in Keychain item `https://sparkle-project.org` #setup

## Relations
- referenced_by [[Build and Release Workflow]]
- referenced_by [[Release Distribution and Updates]]
