---
title: Scarf Project Overview
type: note
permalink: scarf/overview/scarf-project-overview
tags: [overview, scarf]
created: 2026-05-29
updated: 2026-10-05
---

## Observations
- [purpose] Scarf is a native macOS GUI companion app for the Hermes AI agent, providing full visibility into Hermes sessions, tools, memory, cron, plugins, gateway, and settings #product
- [platforms] Two targets: macOS (Scarf, 15.0+ Sequoia) and iOS (ScarfGo, 18.6+) — same Xcode project, both import ScarfDesign #platforms
- [scope] ScarfGo is the iPhone companion: connects to Hermes hosts over SSH (Citadel pure-Swift, no ssh binary on iOS), distributed via public TestFlight #ios
- [multi-server] Scarf 2.0+ is multi-window — each window bound to one Hermes server; local ~/.hermes/ synthesized automatically, remotes added via File → Open Server… #architecture
- [i18n] Ships in 7 locales: English, Simplified Chinese, German, French, Spanish, Japanese, Brazilian Portuguese — initial pass via AI, refined by native speakers #i18n
- [license] MIT licensed; distributed as Developer ID signed + notarized Universal and ARM64 zips via GitHub Releases; auto-updates via Sparkle #distribution

## Relations
- uses [[Hermes Integration]]
- follows [[Scarf Architecture Rules]]
