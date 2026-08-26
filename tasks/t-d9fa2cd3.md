---
id: t-d9fa2cd3
title: Analytics P3: UsageTracking protocol + injected tracker + NoopUsageTracker
status: done
added: 2026-08-26
---

## Description

Replace the app-target static Analytics facade call pattern with an injected UsageTracking protocol (record(UsageEvent)), production StatsClient-backed tracker, and NoopUsageTracker; preserve recordOnce semantics; app-target tests capture events via injected tracker instead of relying on the XCTest no-op. Depends on P2.

## Plan



## Artifacts



