---
title: Post-v2.24 Backfill Decisions
type: note
permalink: scarf/decisions/post-v2-24-backfill-decisions
tags: [i18n, settings, chat, config-parity, backfill]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift, scarf/scarfTests/HermesFileServiceConfigParityTests.swift, scarf/scarf/Core/Utilities/MarkdownContentView.swift, tools/merge-translations.py]
source_paths_inferred: false
source_sha: 5a8954e5110b96175500f8d2a949ef936ce828af
created: 2026-09-01
updated: 2026-09-01
reviewed: 2026-09-03
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] Capability-aware display defaults (tag-verified): checkpoints.enabled false at ALL supported tags (ungated), max_snapshots 20 from v0.13, delegation 250/10 from v0.20.2 (isV0202OrLater) — resolved via display*(capabilities:) sentinels; unknown version resolves to the older default #settings
- [gotcha] The v2.24.0 go/no-go board's floor claims (checkpoints v0.21, delegation v0.20.4) were BOTH wrong — charter C2 applies to internal audit boards too; only tagged Hermes source counts #capability-gating
- [gotcha] ACPClient is a reentrant actor — pre-await guards are not mutual exclusion; use in-flight task + generation counter, and stop() must never await an in-flight request #acp
- [fact] .stringsdata build intermediates are the authoritative string-extraction oracle under headless xcodebuild; diff them against Localizable.xcstrings #i18n
- [gotcha] Plural-hack key detection requires %lld AND letter-before-%@ conjoined; bare pattern falsely flags the v%@ version family #i18n
- [decision] Config-parity gate widened to all 21 config-writer files (AllConfigWritersParityTests); new writer files must register in knownWriters — it caught the google_chat read-loop gap immediately #config-parity

## Relations
- relates_to [[Hermes v0.21 Compatibility Decisions]]
- relates_to [[Localization Workflow]]
- relates_to [[macOS Accessibility Label Conventions]]
