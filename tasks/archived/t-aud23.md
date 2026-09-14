---
id: t-aud23
title: **[t-aud23]** Swift 6 main-actor-isolation warning backlog — CLEARED (74 → 0). Marked the per-service `static let` loggers/constants `nonisolated` (~18 files), the `Core/Models` template/config data types `nonisolated` (so synthesized Codable/Equatable conformances work from nonisolated code), the read-only `InstalledTemplatesIndex` / `NousSubscriptionState` structs `nonisolated`, and made `KanbanSummaryWidgetView.readTenant` take `context` as a param. These were all "error in the Swift 6 language mode" warnings. Verified: clean macOS build SUCCEEDED, 0 main-actor warnings. 5 unrelated pre-existing warnings remain → t-aud26.
status: archived
---

## Description



## Plan



## Artifacts



