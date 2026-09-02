---
title: No raw print() — always os.Logger
type: note
permalink: scarf/conventions/no-raw-print-always-os-logger
tags: [logging, conventions, rule, audit-2026-06-13]
source_paths: [scarf/scarf/Core/Services/HermesFileService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesProfileResolver.swift, scarf/scarf/Features/Projects/Views/Widgets/WebviewWidgetView.swift]
source_paths_inferred: false
source_sha: 73ff36e8d264366ed074a105fe88d39d73b27f7b
created: 2026-06-13
updated: 2026-06-13
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 All production code logs through `Logger(subsystem: "com.scarf", category: "<Name>")` (os.Logger) — raw `print()` is forbidden, including in `catch` blocks, validation guards, and `WKNavigationDelegate` callbacks. `print()` goes to stderr and never reaches the structured logging system queried via `log stream` / Console. #rule
- [rule] Cross-platform `ScarfCore` / `ScarfDesign` use subsystem `"com.scarf"`; `"com.scarf.app"` is macOS-app-only and `"com.scarf.ios"` is iOS-only. #rule
- [pattern] Expected/transient failures (decode errors, WebView nav/load failures, SSH/auth/network 4xx–5xx, path-rejection probes) log at `.warning`/`.notice`, NOT `.error`. `.error` is for programmer-invariant violations. Apply `\(value, privacy: .public)` redaction and never log secrets.
- [check] Quick audit: `grep -rn 'print(' --include="*.swift" scarf | grep -v /Tests/ | grep -vi preview`
- [history] Found across 6+ sites in the 2026-06-13 Cycle 1 audit: `HermesFileService.swift:599/659/2006`, `WebviewWidgetView.swift:111/115` (macOS), `Scarf iOS/Projects/Widgets/WebviewWidgetView.swift:117/121` (iOS); subsystem mismatch at `HermesProfileResolver.swift:37`. macOS and iOS twins must be fixed together; deferral comments do not exempt code. #history

## Relations
- relates_to [[Scarf Architecture Rules]]
