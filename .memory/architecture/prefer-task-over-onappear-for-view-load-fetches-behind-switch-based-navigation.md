---
title: Prefer .task over .onAppear for view-load fetches behind switch-based navigation
type: note
permalink: scarf/architecture/prefer-task-over-onappear-for-view-load-fetches-behind-switch-based-navigation
tags: [performance, swiftui, navigation, architecture, audit-2026-06-13]
source_paths: [scarf/scarf/ContentView.swift, scarf/scarf/Features/Health/Views/HealthView.swift, scarf/scarf/Features/Projects/Views/ProjectsView.swift, scarf/scarf/Features/Settings/Views/SettingsView.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-06-13
updated: 2026-09-11
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 Navigation here uses `@ViewBuilder switch` on a selected-section enum that DESTROYS and recreates subtrees per selection, so `.onAppear { load() }` re-fires multi-call remote fetches on every re-entry. Use `.task` (fires once per view instance, auto-cancels on disappear) OR cache the view model via `cachedVM()` in the coordinator. #rule
- [pattern] `ProjectsView` now uses `.task` correctly (line 70). Many views are cached via `cachedVM()` in `ContentView.cachedVM()` — when a VM is cached, even `.onAppear` fires only once per cache miss (e.g., `ProjectsView` at line 125-128, `SettingsView` at line 166 — round-4 P39 added a capability assignment above the `viewModel.load()` in that same `.onAppear`). For true state persistence across switches without data loss, hoist the view or use caching. #pattern
- [issue] `HealthView` (line 163 in ContentView) still uses `.onAppear { load() }` (HealthView:175) without VM caching — this causes redundant loads on every section re-entry. #issue
- [history] 2026-09-04: ProjectsView migrated to `.task`; ContentView now caches view models for 7+ features via `cachedVM()` pattern. SettingsView (line 165) still uses `.onAppear` but is cached so it's mitigated. HealthView remains uncached. #history

## Relations
- relates_to [[Scarf Architecture Rules]]
- relates_to [[macOS must mirror iOS scene-phase pause and resume for background work]]
