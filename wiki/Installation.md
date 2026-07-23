---
title: Installation
type: note
permalink: scarf-wiki/installation
created: 2026-05-29
updated: 2026-05-29
---

# Installation

> **Looking for the iPhone?** This page covers the macOS desktop app. ScarfGo, the iOS companion, ships via TestFlight — see [ScarfGo](ScarfGo) and [ScarfGo Onboarding](ScarfGo-Onboarding) for that flow.

## System requirements

- **macOS 14.6+ (Sonoma)** or newer.
- **Hermes** installed at `~/.hermes/` for the local server window. (Remote servers are reached over SSH and don't need anything on the Mac side beyond what's already there.)
- Apple Silicon or Intel Mac (Universal binary). An ARM64-only build is also published if you want a smaller download.

## Download

Get the latest release from [GitHub Releases](https://github.com/awizemann/scarf/releases/latest):

- **`Scarf-v<version>-Universal.zip`** — works on every supported Mac.
- **`Scarf-v<version>-ARM64.zip`** — Apple Silicon only, smaller download.

## First launch (Gatekeeper)

Scarf is signed with a Developer ID and notarized by Apple, so the first launch should not require any right-click-to-open dance. If macOS still complains:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the message about Scarf being blocked and click **Open Anyway**.
3. Confirm in the prompt that follows.

This only happens once per install.

## What gets installed

Scarf is a self-contained `.app` bundle. It does **not** install background services, launch agents, or kernel extensions. It reads `~/.hermes/` directly (sandbox is intentionally off — see [Architecture Overview](Architecture-Overview)).

Caches written by Scarf:

- `~/Library/Caches/scarf/snapshots/<server-id>/` — atomic SQLite snapshots pulled from remote servers.
- `~/Library/Preferences/com.scarf.app.plist` — preferences and the server registry (when added).

## Auto-updates

Scarf uses [Sparkle](https://sparkle-project.org/) for automatic updates from a GitHub-Pages-hosted appcast. See [Updating](Updating).

## Next

- [First Run](First-Run) — what Scarf expects in `~/.hermes/`.
- [Servers & Remote](Servers-and-Remote) — adding remote Hermes hosts.
- [Uninstalling](Uninstalling) — removing the app and its files.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (added ScarfGo cross-link)_