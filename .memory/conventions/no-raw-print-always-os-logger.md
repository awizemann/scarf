---
title: No raw print() — always os.Logger
type: note
permalink: scarf/conventions/no-raw-print-always-os-logger
tags: [logging, conventions, rule, audit-2026-06-13]
source_paths: [scarf/scarf/Core/Services/HermesFileService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesProfileResolver.swift, scarf/scarf/Features/Projects/Views/Widgets/WebviewWidgetView.swift]
source_paths_inferred: false
source_sha: 6fd25f3061fd0b2dda55594c4f138b5d5f8c73dd
created: 2026-06-13
updated: 2026-06-13
reviewed: 2026-09-14
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 All production code logs through `Logger(subsystem: "com.scarf", category: "<Name>")` (os.Logger) — raw `print()` is forbidden, including in `catch` blocks, validation guards, and `WKNavigationDelegate` callbacks. `print()` goes to stderr and never reaches the structured logging system queried via `log stream` / Console. #rule
- [rule] Subsystem naming: Cross-platform `ScarfCore` / `ScarfDesign` use subsystem `"com.scarf"`; `"com.scarf.app"` is macOS-app-only and `"com.scarf.ios"` is iOS-only. Performance/monitoring diagnostics use `"com.scarf.mon"` (e.g., `ScarfMon` phase metrics, caller attribution). #rule
- [pattern] Expected/transient failures (decode errors, WebView nav/load failures, SSH/auth/network 4xx–5xx, path-rejection probes) log at `.warning`/`.notice`, NOT `.error`. `.error` is for programmer-invariant violations. Apply `\(value, privacy: .public)` redaction and never log secrets.
- [check] Quick audit: `grep -rn 'print(' --include="*.swift" scarf | grep -v /Tests/ | grep -vi preview`
- [done] Violations from 2026-06-13 Cycle 1 audit have been resolved: no raw `print()` found in HermesFileService.swift, HermesProfileResolver.swift, or WebviewWidgetView.swift. All Logger calls use correct subsystems. #history

## Relations
- relates_to [[Scarf Architecture Rules]]
