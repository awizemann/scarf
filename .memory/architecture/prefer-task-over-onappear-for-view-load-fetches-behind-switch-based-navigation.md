---
title: Prefer .task over .onAppear for view-load fetches behind switch-based navigation
type: note
permalink: scarf/architecture/prefer-task-over-onappear-for-view-load-fetches-behind-switch-based-navigation
tags: [performance, swiftui, navigation, architecture, audit-2026-06-13]
source_paths: [scarf/scarf/ContentView.swift, scarf/scarf/Features/Health/Views/HealthView.swift, scarf/scarf/Features/Projects/Views/ProjectsView.swift]
source_paths_inferred: true
source_sha: 6a12139b218190d8a99ba679bd1a191c0bc13396
created: 2026-06-13
updated: 2026-06-13
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 Navigation here uses `@ViewBuilder switch` on a selected-section/-tab enum that DESTROYS and recreates subtrees per selection, so `.onAppear { load() }` re-fires multi-call remote fetches on every re-entry. Use `.task` (fires once per view instance, auto-cancels on disappear). #rule
- [pattern] `SessionsView`/`ChatView` use `.task` correctly. For true state persistence across switches, hoist the view or cache the loaded data in the coordinator — `.task` alone reduces redundant fetch frequency but does not preserve state across destruction.
- [check] Quick audit: `grep -rn '.onAppear {' --include="*.swift" scarf/scarf/Features | grep -i load`
- [history] 2026-06-13 Cycle 2: `ContentView.swift:50-84` + 9 feature views (e.g. `SettingsView.swift:108`, `HealthView.swift:124-127`), `ProjectsView.swift:454-481` (project tab switch). #history

## Relations
- relates_to [[Scarf Architecture Rules]]
- relates_to [[macOS must mirror iOS scene-phase pause and resume for background work]]
