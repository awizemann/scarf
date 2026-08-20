---
id: t-2c07bda8
title: Analytics P2: opt-out UI in Settings → Advanced + privacy manifest declarations
status: done
added: 2026-08-20
---

## Description

Add an Analytics section next to the existing Telemetry row in scarf/Features/Settings/Views/Tabs/AdvancedTab.swift: master toggle bound to StatsClient setEnabled (persisted by the package), copy explaining anonymous usage stats, no user content. Default: enabled. Update the app's PrivacyInfo.xcprivacy: collected data types Product Interaction and Other Diagnostic Data, not linked to identity, not used for tracking (no User ID — we never call identify()). Supply screenMetrics and colorScheme to StatsConfiguration. Acceptance: build succeeds; toggle round-trips (off → no events recorded, verified with StatsTesting InMemorySink). Taxonomy: documents/analytics/swift-stats-adoption-event-taxonomy.md.

## Plan



## Artifacts



