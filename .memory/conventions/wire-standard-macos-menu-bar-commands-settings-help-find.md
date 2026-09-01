---
title: Wire standard macOS menu-bar commands (Settings, Help, Find)
type: note
permalink: scarf/conventions/wire-standard-macos-menu-bar-commands-settings-help-find
tags: [hig, macos, conventions, audit-2026-06-13]
source_paths: [scarf/scarf/scarfApp.swift, scarf/scarf/Features/Sessions/Views/SessionsView.swift]
source_paths_inferred: false
source_sha: c15060dd23b03692780f5b0002fd47f9660d76ef
created: 2026-06-13
updated: 2026-06-15
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 The macOS `.commands` block must provide the menu-bar affordances users reach for by reflex: Settings via ⌘, (route to `coordinator.selectedSection = .settings`), a Help menu (`CommandGroup(replacing: .help)`) linking to docs, and ⌘F to focus the search field in any searchable list (`@FocusState` + `.keyboardShortcut("f")`). Sidebar-only or click-only access does not satisfy macOS keyboard conventions. #rule
- [pattern] As of t-aud06 / t-aud18 (2026-06-13) the `.commands` block wires four CommandGroups: `.appSettings` (⌘, → focused window's `selectedSection = .settings` via a focused-value `AppCoordinator`), `.help` (Link to Hermes docs), Check for Updates, and Open Server. `SessionsView` exposes a hidden ⌘F button that focuses the search field. Apply the same wiring to any future searchable pane.
- [check] Read `scarfApp.swift` `.commands { }`; confirm Settings / Help / Find affordances exist.
- [history] 2026-06-13 Cycle 3: originally `scarfApp.swift:207-218` had no Settings ⌘, no Help menu and `SessionsView.swift:253-280` had no ⌘F (fixed in t-aud06 / t-aud18). #history

## Relations
- relates_to [[Scarf Architecture Rules]]
