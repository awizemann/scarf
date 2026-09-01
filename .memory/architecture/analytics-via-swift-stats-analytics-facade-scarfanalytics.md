---
title: Analytics via swift-stats: Analytics facade, ScarfAnalytics seam, event conventions
type: note
permalink: scarf/architecture/analytics-via-swift-stats-analytics-facade-scarfanalytics
source_paths: [scarf/scarf/Core/Services/Analytics.swift, scarf/scarf/Core/Services/UsageEvent.swift, scarf/scarf/Core/Services/UsageTracking.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfAnalytics.swift, scarf/scarf/Core/Services/StatsScarfMonBackend.swift, scarf/scarf/Features/Settings/Views/Tabs/AdvancedTab.swift]
source_paths_inferred: false
source_sha: 28d4f8477d145526ed5b38a04ffc199e53d15f52
created: 2026-08-20
updated: 2026-08-26
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

The macOS app ships privacy-first usage analytics via the swift-stats package (github.com/awizemann/swift-stats, SaaS backend api.swiftstats.co). iOS will use a SEPARATE write key, not yet integrated.

**Key management (Phase 1, updated 2026-08-26): NOT hardcoded, NOT read from source at all.** The write key reaches the binary only through build settings: gitignored `scarf/Configs/SwiftStatsLocal.xcconfig` (`SWIFT_STATS_WRITE_KEY`) → committed `scarf/Configs/SwiftStats.xcconfig` (empty default, then `#include?`) → target build configs → Info.plist key `SwiftStatsWriteKey` → runtime read in `Analytics.writeKey`, validated by `Analytics.validWriteKey` (rejects nil/empty/whitespace/an unexpanded `$(` — any of those disables analytics for the process, never falls back to a stale key). The canonical rotated key lives in Keychain vendor **`swift-stats-write-key`**; the previously leaked hardcoded key is being revoked. The key must NEVER appear in source or in any committed file. Practical consequence: a release build archived without `SwiftStatsLocal.xcconfig` present ships with analytics silently off.

**Architecture (updated 2026-08-26 — UsageEvent contract + UsageTracking seam replace the old three-layer description):**
1. `scarf/scarf/Core/Services/UsageEvent.swift` — closed `nonisolated enum` (27 cases) that IS the taxonomy: every case's associated values are closed prop-vocabulary enums or bucket structs (`DurationBucket`, `ServerCountBucket`, `SkillCountBucket`, `SettingKeyToken`) whose only initializer runs a vetted bucketing/sanitizing helper. `name`/`props` reproduce the pre-refactor string wire format byte-for-byte (`UsageEventWireFormatTests` is the acceptance test).
2. `scarf/scarf/Core/Services/UsageTracking.swift` — `UsageTracking` protocol (`record(_:)`, `recordOnce(_:key:)`, plus `record(rawName:props:)` reserved for the ScarfCore bridge only), `StatsUsageTracker.shared` (production, owns the single StatsClient, appId com.scarf.app, installIdSalt "scarf-macos-2026" — NEVER change the salt), `NoopUsageTracker`, and shared lock-guarded `UsageOnceKeys` dedupe. `resetRecordedOnceForTesting()` is gone — dedupe now lives per tracker instance.
3. `scarf/scarf/Core/Services/Analytics.swift` — now a thin, lock-guarded forwarder over an installable `Analytics.tracker` seam (default `StatsUsageTracker.shared`). App call sites are unchanged (`Analytics.record(...)`) but take a `UsageEvent`. Tests swap the seam via `Analytics.install(_:)`; `scarfTests/CapturingUsageTracker.swift` is the test double. No-ops under XCTest/previews (isSyntheticHost) and when disabled. isPreRelease=true for DEBUG/dev-detached builds. Master opt-out toggle in Settings → Advanced ("Usage Analytics", default on).
4. `scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfAnalytics.swift` — injectable process-wide recorder seam, **deliberately still string-based** (comment on `Analytics.CoreBridge` explains why: ScarfCore can't see the app target and so can't name a `UsageEvent`; duplicating a second closed enum there would let the taxonomy fork). **ScarfCore must NEVER import Stats** (shared with iOS). macOS installs a bridge (`Analytics.CoreBridge`) in scarfApp.init; iOS installs nothing → no-op. `durationBucket`/`toolCallCountBucket` helpers live here so both sides bucket identically.
5. `scarf/scarf/Core/Services/StatsScarfMonBackend.swift` — ScarfMonBackend emitting perf_measure only for over-budget interval samples, rate-capped 30/category/process; installed via AppScarfMonBoot alongside (not replacing) signpost/logger backends.

**Accepted deviations from cross-app swift-stats conventions (decisions, not TODOs):** keep event name `section_viewed` (not the cross-app `view_shown`; no `via` prop); no `error_shown` event (failures tracked at the operation layer, e.g. `connect_failed`, `agent_turn_failed`); keep `autoEvents: [.appOpen, .appBackground, .sessions]` including `.appBackground` (macOS has no true background state, so it's the closest analogue to the package's session-gap logic). Full rationale in documents/analytics/swift-stats-adoption-event-taxonomy.md.

**Event conventions (why: swift-stats validates and drops violations; privacy is the design center):**
- snake_case names; flat string props from CLOSED vocabularies only — never user text, hostnames, usernames, paths, URLs, session/project names, setting values, or raw error strings. Map errors via case-only switches (e.g. `analyticsErrorKind` in TransportErrors.swift).
- Durations/counts as coarse bucket enums; emit state TRANSITIONS and once-per-turn/process latches, never polling ticks.
- Tests: app-target facade no-ops under XCTest, so app-side tests assert pure decision logic; ScarfCore seam tests use a captured recorder and MUST nest under one `.serialized` parent suite (process-global recorder) with `defer { install(nil) }`.
- Taxonomy + accepted deviations: documents/analytics/swift-stats-adoption-event-taxonomy.md. Privacy manifest declares Product Interaction + Other Diagnostic Data; `identify()` is never called (no User ID declaration).

Landed as commits 8d1c5dc, 7887687, 453465a, 9bc58c4, abdd0e7, e5d393a plus an audit-fix commit (Aug 2026). Deployment target was bumped 14.6 → 15.0 for the package.



## Observations
- [fact] ScarfCore must never import Stats; analytics from ScarfCore goes through the ScarfAnalytics injectable seam, installed only by the macOS app #architecture
- [fact] installIdSalt "scarf-macos-2026" must never change — changing it re-identifies every install as new #constraint
- [fact] App-target tests capture emitted events by installing CapturingUsageTracker via Analytics.install; every suite that installs into the process-wide seam must share one .serialized parent #testing
- [fact] The write key is never in source; it reaches the binary via gitignored scarf/Configs/SwiftStatsLocal.xcconfig → committed SwiftStats.xcconfig → Info.plist SwiftStatsWriteKey → Analytics.writeKey; canonical copy lives in Keychain vendor swift-stats-write-key #security
- [fact] UsageEvent (scarf/scarf/Core/Services/UsageEvent.swift) is a closed 27-case enum that IS the taxonomy, enforced by the type checker via UsageTracking seam #architecture
