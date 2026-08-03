---
id: t-0fb9f96f
title: v0.20 Wave A — HermesCapabilities v0.20 group + tests
status: done
added: 2026-08-03
---

## Description

Add `// MARK: v0.20 (v2026.8.3) flags` group to HermesCapabilities.swift with isV020OrLater predicate (gate on >= 0.20.0, not patch) and flags needed by later waves: hasCompressCommand (replaces /compact), hasCuratorAdopt, hasApprovalsSuggest, hasCronRuns, hasSessionsExportFormats. HermesCapabilitiesTests mirroring the v0.18 cluster: parse-version-line, all-v0.20-flags-on, v0.19-host-hides-v0.20-flags (degradation), patch-release-still-on. Build + ScarfCore tests green.

## Plan



## Artifacts



