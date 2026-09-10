---
title: Hermes Capability Gating Pattern
type: note
permalink: scarf/architecture/hermes-capability-gating-pattern
tags: [architecture, capabilities, versioning]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift]
source_paths_inferred: false
source_sha: 012316d0d66c732c238b25f4990bc173867747cf
created: 2026-05-29
updated: 2026-09-08
reviewed: 2026-09-09
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


- [gotcha] A capability flag can need an UPPER bound. A patch tag can RE-ADD a surface an earlier release removed — `plugins/web/tavily/` was deleted at v2026.8.31 (0.21.0) and restored at v2026.9.7 (0.21.1) — so a removal modelled as `!isV021OrLater` hides a live backend on every later host. Model a removal as a WINDOW (`semver == 0.21.0`), and only collapse it back to a floor once a later tag confirms the surface stayed gone. #hermes #capabilities
- [gotcha] "Absent at the old tag" must be established by walking the SYMBOL across every tag over every file location it has ever had, never by `git show <old-tag>:<new-path>`. The v0.21.1 modularization moved most argparse blocks out of `hermes_cli/main.py` into `hermes_cli/subcommands/<verb>.py`, so the old-tag path lookup fails and reads as "absent" — that alone mis-floored four surfaces (`skills search --json` is v0.17, `browse-sh` v0.15, `debug share -y` and `computer-use permissions status --json` v0.18). Use `git log -S<needle> --oneline -- <old path> <new path>` plus `git tag --contains <commit>`. #hermes #capabilities #verification
