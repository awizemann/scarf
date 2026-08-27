---
id: t-f2d47f8a
title: Analytics P1: write key via build setting → Info.plist, remove hardcoded literal
status: done
added: 2026-08-26
---

## Description

Replace the hardcoded swift-stats write key in scarf/scarf/Core/Services/Analytics.swift:47 with a SWIFT_STATS_WRITE_KEY build setting sourced from an uncommitted gitignored Local.xcconfig, injected into Info.plist (SwiftStatsWriteKey), read at runtime; empty/missing/unexpanded "$(" values degrade to analytics-off. New key already minted (Keychain vendor swift-stats-write-key); Alan will revoke the leaked key. Agent must NOT handle the secret — orchestrator seeds Local.xcconfig.

## Plan



## Artifacts



