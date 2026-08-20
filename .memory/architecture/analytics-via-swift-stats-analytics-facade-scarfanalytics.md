---
title: Analytics via swift-stats: Analytics facade, ScarfAnalytics seam, event conventions
type: note
permalink: scarf/architecture/analytics-via-swift-stats-analytics-facade-scarfanalytics
source_paths: [scarf/scarf/Core/Services/Analytics.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfAnalytics.swift, scarf/scarf/Core/Services/StatsScarfMonBackend.swift, scarf/scarf/Features/Settings/Views/Tabs/AdvancedTab.swift]
source_paths_inferred: false
source_sha: e5d393a54cb1c256c90b30c162ea79d52b0c1a35
created: 2026-08-20
updated: 2026-08-20
---

The macOS app ships privacy-first usage analytics via the swift-stats package (github.com/awizemann/swift-stats, SaaS backend api.swiftstats.co; write key in Keychain vendor `swift-stats`; iOS will use a SEPARATE write key, not yet integrated).

**Architecture (three layers):**
1. `scarf/scarf/Core/Services/Analytics.swift` — nonisolated facade owning one lazily-built StatsClient (appId com.scarf.app, installIdSalt "scarf-macos-2026" — NEVER change the salt). `Analytics.record(name, props)` is the app-wide fire-and-forget entry point. No-ops under XCTest/previews (isSyntheticHost) and when disabled; degrades to no-op if construction throws. isPreRelease=true for DEBUG/dev-detached builds. Master opt-out toggle in Settings → Advanced ("Usage Analytics", default on).
2. `scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfAnalytics.swift` — injectable process-wide recorder seam. **ScarfCore must NEVER import Stats** (shared with iOS). macOS installs a bridge in scarfApp.init; iOS installs nothing → no-op. `durationBucket`/`toolCallCountBucket` helpers live here so both sides bucket identically.
3. `scarf/scarf/Core/Services/StatsScarfMonBackend.swift` — ScarfMonBackend emitting perf_measure only for over-budget interval samples, rate-capped 30/category/process; installed via AppScarfMonBoot alongside (not replacing) signpost/logger backends.

**Event conventions (why: swift-stats validates and drops violations; privacy is the design center):**
- snake_case names; flat string props from CLOSED vocabularies only — never user text, hostnames, usernames, paths, URLs, session/project names, setting values, or raw error strings. Map errors via case-only switches (e.g. `analyticsErrorKind` in TransportErrors.swift).
- Durations/counts as coarse bucket enums; emit state TRANSITIONS and once-per-turn/process latches, never polling ticks.
- Tests: app-target facade no-ops under XCTest, so app-side tests assert pure decision logic; ScarfCore seam tests use a captured recorder and MUST nest under one `.serialized` parent suite (process-global recorder) with `defer { install(nil) }`.
- Taxonomy + accepted deviations: documents/analytics/swift-stats-adoption-event-taxonomy.md. Privacy manifest declares Product Interaction + Other Diagnostic Data; `identify()` is never called (no User ID declaration).

Landed as commits 8d1c5dc, 7887687, 453465a, 9bc58c4, abdd0e7, e5d393a plus an audit-fix commit (Aug 2026). Deployment target was bumped 14.6 → 15.0 for the package.



## Observations
- [fact] ScarfCore must never import Stats; analytics from ScarfCore goes through the ScarfAnalytics injectable seam, installed only by the macOS app #architecture
- [fact] installIdSalt "scarf-macos-2026" must never change — changing it re-identifies every install as new #constraint
- [fact] Analytics props must come from closed vocabularies: no user text, hostnames, paths, URLs, names, values, or raw error strings #privacy
- [fact] Analytics.record no-ops under XCTest/previews, so app-target tests assert pure decision logic; ScarfCore seam test suites must share one .serialized parent #testing
- [fact] iOS (ScarfGo) will use a separate SwiftStats write key; not yet integrated as of Aug 2026 #roadmap
