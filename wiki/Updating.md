---
title: Updating
type: note
permalink: scarf-wiki/updating
created: 2026-05-29
updated: 2026-05-29
---

# Updating

> **ScarfGo updates differently.** The iOS app updates through TestFlight (and, in future, the App Store) — Apple's standard update channel. The Sparkle flow described below is **macOS only**.

Scarf uses [Sparkle](https://sparkle-project.org/) to deliver automatic updates from a GitHub-Pages-hosted appcast at `https://awizemann.github.io/scarf/appcast.xml`. Each release is EdDSA-signed by the maintainer's private key; Scarf refuses any update whose signature doesn't verify against the embedded `SUPublicEDKey`.

## Automatic updates

By default, Scarf checks for updates on launch and every 24 hours after that. When a new version is available, Sparkle pops up its standard dialog with the release notes and asks whether to install.

To **disable automatic checks**, open **Settings → General → Updates**. You can re-enable later from the same place.

## Manual check

Two ways to force a check:

- **Settings → General → Updates → Check for Updates Now**
- **Menu bar → Check for Updates**

## Beta / draft releases

Scarf does not ship beta channels — the appcast only carries the latest published release. Drafts pushed via `./scripts/release.sh <ver> --draft` are uploaded to GitHub but not added to the appcast, so they don't reach existing installs until promoted manually.

## Downgrading

There's no in-app downgrade. To run an older build:

1. Quit Scarf.
2. Move the current `Scarf.app` to the Trash.
3. Download the older zip from [Releases](https://github.com/awizemann/scarf/releases) and drag it to `/Applications`.
4. Disable **automatic checks** in **Settings → General → Updates**, otherwise Sparkle will offer to update you back.

App preferences live in `~/Library/Preferences/com.scarf.app.plist` and are forward/backward compatible across versions in normal cases.

## Update fails to apply

If Sparkle reports a signature mismatch or download error, see the [Health](Gateway-Cron-Health-Logs) view for details. Re-trigger the check; if it persists, file an issue with the Sparkle log content.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (clarified macOS-only Sparkle vs ScarfGo TestFlight)_