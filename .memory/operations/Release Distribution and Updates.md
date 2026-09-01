---
title: Release Distribution and Updates
type: note
permalink: scarf/ops/release-distribution-and-updates
tags: [release, sparkle, distribution]
source_paths: [scripts/release.sh, README.md]
source_sha: 8da06bf74aa0b22581939e623f70e5dc0af37ff6
created: 2026-05-29
updated: 2026-06-06
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---

## Observations
- [distribution] Releases ship two zips: `Scarf-vX.X.X-Universal.zip` (arm64 + x86_64) and `Scarf-vX.X.X-ARM64.zip` (Apple Silicon only). Both are Developer ID signed and notarized. #binaries
- [auto-update] Sparkle handles auto-updates: appcast on `gh-pages` branch, EdDSA-signed entries. Users can disable or trigger manual checks from Settings → General → Updates or the menu bar icon. #sparkle
- [credentials] Release prerequisites (Alan's machine): Developer ID Application cert (team `3Q6X2L86C4`) in login Keychain, notarytool keychain profile `scarf-notary`, Sparkle EdDSA private key in Keychain item `https://sparkle-project.org`, `gh-pages` branch + GitHub Pages enabled. #credentials
- [sparkle-key-recovery] The Sparkle private key is per-machine and unrecoverable if lost — every shipped binary verifies against its baked-in `SUPublicEDKey`, so a key rotation orphans every existing install. The canonical pubkey is `sxHR0OGLmx9I4Fyx1GdPANR9WUiVAz/rI38x3cLYnMU=`. Releasing from a fresh machine without importing the production key produces an unverifiable signature (incident: v2.10.2, 2026-06-05, re-signed same-day). Full import + recovery procedure: [[Sparkle Key Recovery]] #credentials #gotcha
- [gatekeeper] If Gatekeeper rejects on first launch ("Scarf.app is damaged"), only remove the quarantine xattr — never strip all xattrs or re-sign. Every release passes `codesign --verify --strict --deep` and `spctl --assess --type execute`. #troubleshooting
- [user-recovery] User-facing recovery if Sparkle rejects an update ("Update is improperly signed"): quit Scarf, relaunch, Check for Updates; if cached-bad-state persists, `rm -rf ~/Library/Caches/com.scarf.app && defaults delete com.scarf.app SULastCheckTime` and relaunch. Manual zip download from the GitHub release page always works (the zips are Developer-ID signed + notarized regardless of Sparkle signature state). See wiki [Troubleshooting: Update "improperly signed"](https://github.com/awizemann/scarf/wiki/Troubleshooting-Sparkle-Update). #troubleshooting

## Relations
- extends [[Build and Release Workflow]]
- detailed_in [[Sparkle Key Recovery]]
