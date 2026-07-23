---
title: Troubleshooting-Sparkle-Update
type: note
permalink: scarf-wiki/troubleshooting-sparkle-update
created: 2026-06-06
updated: 2026-06-06
---

# Troubleshooting: "Update is improperly signed"

**Symptom.** Scarf offers an update via **Scarf → Check for Updates…**, you click **Install**, and Sparkle shows an error like _"Update is improperly signed"_, _"signing was incorrect"_, or _"EdDSA signature verification failed"_. The update never installs.

## What the error means

Every Scarf binary ships with the production Sparkle EdDSA public key (`SUPublicEDKey`) baked into `Info.plist`. When Sparkle downloads an update zip, it verifies the appcast's `sparkle:edSignature` against that public key. If the signature was produced by a different private key — for example, a release accidentally signed from a fresh build machine that didn't have the production key imported — Sparkle correctly refuses to install. The update zip itself may be perfectly fine; only the signature attached to the appcast entry is wrong.

This page exists because it happened once: v2.10.2 (2026-06-05) was published with the wrong signature. It was corrected within ~9.5 hours and the live appcast served the corrected signature from `2026-06-06 06:57 UTC` onward.

## If you're hitting this now

**1. Try again.** Most cases heal themselves:

- Quit Scarf completely (⌘Q, not just close the window).
- Relaunch Scarf.
- Click **Scarf → Check for Updates…**

If Sparkle had cached a bad appcast response, the quit forces a fresh fetch on relaunch. Should offer the update normally — accept it.

**2. If "Check for Updates" says you're up to date but you know you're not**, your local cache may still be stale. Clear it:

```bash
rm -rf ~/Library/Caches/com.scarf.app
defaults delete com.scarf.app SULastCheckTime 2>/dev/null || true
```

Then relaunch Scarf and **Check for Updates** again.

**3. If you previously clicked "Skip This Version"** while the bad signature was being offered, Sparkle remembers the skip and won't re-offer that version. Either wait for the next release (Sparkle will offer it normally), or download the zip manually from the [GitHub Releases page](https://github.com/awizemann/scarf/releases) and replace your `/Applications/Scarf.app` with the extracted bundle.

**4. Manual install always works.** The release zip on GitHub is Developer-ID-signed and Apple-notarized regardless of the Sparkle signature state:

- Visit <https://github.com/awizemann/scarf/releases/latest>
- Download `Scarf-v<version>-Universal.zip` (or the ARM64 variant if you're on Apple Silicon and prefer the smaller bundle)
- Unzip, drag `Scarf.app` into `/Applications` (replacing the existing copy)
- Launch — Gatekeeper will accept it on the strength of the Developer ID + notarization ticket; no first-launch right-click-to-open required

## When to file a bug

Open an issue at <https://github.com/awizemann/scarf/issues> if:

- All three steps above failed and you're still seeing the signature error against the **latest** release.
- You're seeing a signing error on a release **older than the current one** (the appcast only advertises one version at a time; older signatures are not re-served).

Include the version of Scarf installed (About → version), the version offered by the update sheet, and the relevant lines from Console.app filtered by `subsystem == "org.sparkle-project.Sparkle"`.

## How this is prevented going forward

[`scripts/release.sh`](https://github.com/awizemann/scarf/blob/main/scripts/release.sh) now refuses to run on a machine whose Sparkle Keychain item doesn't match the embedded `SUPublicEDKey`, and asserts the produced signature decodes to the correct Ed25519 length before pushing the appcast. The operator-side runbook for setting up the key on a fresh release machine lives in [`Release-Process`](Release-Process).
