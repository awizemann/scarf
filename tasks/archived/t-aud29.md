---
id: t-aud29
title: **[t-aud29]** ScarfCore-*package* build warnings — CLEARED (8 → 0). Surfaced by `swift build` (SwiftPM), invisible to the xcodebuild app build. Started from 3 (ACPMessages/GatewayConfigWriter/RichChatViewModel); a clean build surfaced 5 more of the same `?? Data()` class, all folded in (t-aud29's goal is "clear the package warnings," not a fixed list). Fixes: (1) `ACPEvent` + `ACPToolCallEvent` → `@unchecked Sendable` — their only non-Sendable members are JSON value-graphs from ACP notifications (`[[String: Any]]` commands, `[String: Any]?` rawInput), immutable post-construction; same rationale/treatment as `AnyCodable` in the same file; preserves the public API (no macOS/iOS/test ripple). (2) `GatewayConfigWriter` — removed dead `blockHeaderText` let + its unreachable `_ =` after the exhaustive returning switch. (3) `RichChatViewModel:1821` — `_ = messages.remove(at: idx)` inside `withTransaction` (closure was returning the removed element). (4) `LocalTransport` ×2 / `SSHTransport` ×2 / `RemoteBackupService` — dropped dead `?? Data()` (`try?` flattens `readToEnd()`'s `Data?`, so `flatMap`'s `$0` is already non-optional `Data`). Verified: clean `swift build` 0 warnings; macOS + iOS BUILD SUCCEEDED; `swift test` passes except 1 intermittent pre-existing parallelism flake (env-enricher global race) unrelated to these changes → t-aud31.
status: archived
---

## Description



## Plan



## Artifacts



