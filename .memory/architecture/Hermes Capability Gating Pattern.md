---
title: Hermes Capability Gating Pattern
type: note
permalink: scarf/architecture/hermes-capability-gating-pattern
tags:
- architecture
- capabilities
- versioning
source_sha: c76d37fdd58cef8b1a3b1c24c036f29ab57919f3
source_paths: scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, CLAUDE.md
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-07-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [pattern] Every release-gated UI surface in Scarf is feature-flagged via `HermesCapabilities` (scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift). Detected once per server connection from `hermes --version` (semver + YYYY.M.D parse). #pattern
- [pattern] `HermesCapabilitiesStore` is injected on `ContextBoundRoot` (Mac) and `ScarfGoTabRoot` (iOS) via `.environment(_:)` and `.hermesCapabilities(_:)`. Gated UI reads it through the typed environment key. #dependency-injection
- [convention] Capability flags grouped by Hermes release with MARK comments: `MARK: v0.14 (v2026.5.16) flags`, `MARK: v0.15 (v2026.5.28) flags`, etc. Add a new flag whenever Scarf gains a release-gated UI surface. #convention
- [policy] Pre-target hosts gracefully hide new affordances rather than throwing on unknown CLI subcommands. Pre-v0.15 (and pre-v0.14) hosts must render byte-identical to the previous Scarf release. #compatibility
- [policy] Before implementing a new gate, verify exact flag/config/wire shapes against the corresponding Hermes source tag (e.g., `v2026.5.28`). #verification

## Relations
- implements [[Hermes v0.15 Capability Gating Decisions]]
- relates_to [[Hermes Integration]]