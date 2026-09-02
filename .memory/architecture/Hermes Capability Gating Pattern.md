---
title: Hermes Capability Gating Pattern
type: note
permalink: scarf/architecture/hermes-capability-gating-pattern
tags: [architecture, capabilities, versioning]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift]
source_paths_inferred: false
source_sha: 676f7d8dffc2c34a567124e08b36d30c650ca587
created: 2026-05-29
updated: 2026-09-01
reviewed: 2026-09-02
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


- [gotcha] Verify a new flag's floor against EVERY intervening tag, not just the previous target. For the v0.21.0 cycle the audit scoped 0.20.5 → 0.21.0, but the intermediate v2026.8.27 (0.20.6) tag already shipped four surfaces the v0.21 release notes advertise — `cron incidents`, `cron resume --run-now/--at`, `--deliver bot-chat`, and the top-level `browser` subcommand — so they gate on a patch-level `isV0206OrLater`, not `isV021OrLater`. Only `peer run/status/stop`, `cron doctor`, and config dotted-key escaping (commit a42aee9585) are genuinely v0.21.0. Check with `git -C ~/.hermes/hermes-agent show <tag>:<file>` plus `git tag --contains <commit>`. #hermes #capabilities
