---
title: Post-v2.24 Backfill Decisions
type: note
permalink: scarf/decisions/post-v2-24-backfill-decisions
tags: [i18n, settings, chat, config-parity, backfill]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift, scarf/scarfTests/HermesFileServiceConfigParityTests.swift, scarf/scarf/Core/Utilities/MarkdownContentView.swift, tools/merge-translations.py]
source_paths_inferred: false
source_sha: f5b18d494f956578e678accb6d7185187ce29791
created: 2026-09-01
updated: 2026-09-01
---

Durable decisions/gotchas from the post-v2.24.0 backfill cycle (branch feat/post-v2.24-backfill, worktree build). Covers the Settings follow-ups, Chat follow-ups, and the l10n backfill (+489 catalog keys, six locales).

**Settings.** Hermes default flips requiring the sentinel+resolver pattern — TAG-VERIFIED after the fresh-eyes audit caught the audit-board claims being wrong: checkpoints.enabled defaults to FALSE at every supported tag (v0.6.0 cli.py:1163 through v0.21.0 cli.py:5501 — the "true→false flip at v0.21" was fabricated history; Scarf's old true default was never real at any supported tag); checkpoints.max_snapshots 50→20 at v0.13.0 (v2026.5.7 cli.py:2311; gate isV013OrLater); delegation max_iterations 50→250 and max_concurrent_children 3→10 at v0.20.2 (v2026.8.16 config_defaults.py:1821/:1846, same tag as migrations 36/37 — NOT v0.20.4 as the go/no-go board said; new HermesCapabilities.isV0202OrLater). `boolOpt` + `Bool?` is the Bool analogue of the 0/nil int sentinel; unknown host version resolves to the OLDER default. The widened config-parity gate (`AllConfigWritersParityTests`, 19-file `knownWriters` manifest, all five write shapes) found a real bug on day one: `google_chat.gateway_restart_notification` was written but excluded from the gateway-platform read loop, so the toggle snapped back on next load.

**Chat/ACP.** ACPClient is a reentrant actor — any guard evaluated before an `await` is not a mutual-exclusion guard; lifecycle idempotence needs an in-flight task + generation counter, and `stop()` must never await an in-flight ACP request (60s watchdog on the user's cancel path). `pendingPermission` is now a read-only computed head over a FIFO queue; resolve by requestId, never positionally — SwiftUI sheet-binding setters are inert because dismissal writes double-pop. Streaming markdown settles only at blank lines outside code fences (`StreamingFenceScanner`); unterminated fences deliberately stall settling (correctness over throughput).

**L10n.** `.stringsdata` build intermediates are the authoritative extraction oracle under headless xcodebuild (JSON per source file with key + file:line) — diff their union against the catalog instead of regex-guessing literals. Plural-hack detector must be `%lld` AND `[A-Za-z]%@` conjoined (bare `[A-Za-z]%@` falsely flags the `v%@` version family). Two plural-hack keys are deliberately translated (allow-listed in `LocalizationCatalogTests`, do not grow the list). Xcode writes `en` columns with state "new" — catalog invariants must exempt the source language. View-model banner strings (`"Saved \(key)"` in @MainActor VMs) are a systematic extraction-leak class — compose with `String(localized:)` at construction. merge-translations.py's `unknown-keys-skipped` count is the cheapest drift signal (non-zero = English copy edited under a locale key).

## Observations
- [decision] Capability-aware display defaults (tag-verified): checkpoints.enabled false at ALL supported tags (ungated), max_snapshots 20 from v0.13, delegation 250/10 from v0.20.2 (isV0202OrLater) — resolved via display*(capabilities:) sentinels; unknown version resolves to the older default #settings
- [gotcha] The v2.24.0 go/no-go board's floor claims (checkpoints v0.21, delegation v0.20.4) were BOTH wrong — charter C2 applies to internal audit boards too; only tagged Hermes source counts #capability-gating
- [gotcha] ACPClient is a reentrant actor — pre-await guards are not mutual exclusion; use in-flight task + generation counter, and stop() must never await an in-flight request #acp
- [fact] .stringsdata build intermediates are the authoritative string-extraction oracle under headless xcodebuild; diff them against Localizable.xcstrings #i18n
- [gotcha] Plural-hack key detection requires %lld AND letter-before-%@ conjoined; bare pattern falsely flags the v%@ version family #i18n
- [decision] Config-parity gate widened to all 19 config-writer files (AllConfigWritersParityTests); new writer files must register in knownWriters — it caught the google_chat read-loop gap immediately #config-parity

## Relations
- relates_to [[Hermes v0.21 Compatibility Decisions]]
- relates_to [[Localization Workflow]]
- relates_to [[macOS Accessibility Label Conventions]]
