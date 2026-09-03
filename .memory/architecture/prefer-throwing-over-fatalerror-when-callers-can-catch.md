---
title: Prefer throwing over fatalError when callers can catch
type: note
permalink: scarf/architecture/prefer-throwing-over-fatalerror-when-callers-can-catch
tags: [error-handling, architecture, rule, audit-2026-06-13]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/SQLValueInliner.swift, scarf/scarf/Features/MCPServers/Views/MCPServerPresetPickerView.swift]
source_paths_inferred: true
source_sha: 6a12139b218190d8a99ba679bd1a191c0bc13396
created: 2026-06-13
updated: 2026-06-13
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 A helper reachable from code already wrapped in `try`/catch should `throw` a typed error rather than `fatalError()`/force-unwrap on invariant violations — even when a comment calls it a "programmer error". Crashing the whole app to signal a recoverable caller bug is strictly worse than propagating an error the existing handlers can absorb. #rule
- [pattern] Reserve `fatalError`/force-unwrap for truly impossible states (compile-time-constant literals). Prefer `??` without a force-unwrapped fallback.
- [check] Quick audit: `grep -rn 'fatalError|try!' --include="*.swift" scarf | grep -v /Tests/`
- [done] 2026-06-13 Cycle 1: `SQLValueInliner.swift` fatalError on mismatch → `throw InlineError` (commit 597edaa t-aud08); `MCPServerPresetPickerView.swift` force-unwrap → safe binding (same commit). #history

## Relations
- relates_to [[Scarf Architecture Rules]]
