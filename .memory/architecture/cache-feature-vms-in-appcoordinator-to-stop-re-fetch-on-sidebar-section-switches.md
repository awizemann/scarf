---
title: Cache feature VMs in AppCoordinator to stop re-fetch on sidebar section switches
type: note
permalink: scarf/architecture/cache-feature-vms-in-appcoordinator-to-stop-re-fetch-on-sidebar-section-switches
tags: [navigation, performance, swiftui, observation, appcoordinator, macos]
created: 2026-06-13
updated: 2026-09-04
---

macOS `ContentView`'s detail pane is a `@ViewBuilder switch` over `coordinator.selectedSection` (26 sections). A `switch` in a `@ViewBuilder` yields a different view type per case, so SwiftUI **destroys + recreates** the section view on every sidebar switch — recreating its `@State` VM and re-running `load()` over SSH on every re-entry. Swapping `.onAppear`→`.task` does NOT fix this (the view is recreated, so `.task` fires every switch too — see [[prefer-task-over-onappear-for-view-load-fetches-behind-switch-based-navigation]], which this note supersedes for the *re-fetch* problem).

The fix (t-aud24, Option A/B): cache the VM in the coordinator so it (and its loaded data) survive switches, and guard `load()` so re-entry is a no-op.

## Observations

- [pattern] `AppCoordinator.featureViewModel<VM: AnyObject>(for: SidebarSection, make: () -> VM) -> VM` — an `@ObservationIgnored private var featureViewModels: [SidebarSection: AnyObject]` cache; build-on-miss. `ContentView` resolves each feature VM through a `cachedVM(_:_:)` helper and injects it into the view's `init(viewModel:)`. #appcoordinator
- [scope] The cache is correctly scoped for free: `AppCoordinator` lives in `ContextBoundRoot`, which is keyed `.id(context.id)` — so the coordinator (and cache) is recreated on server switch and is per-window. No manual serverID invalidation. #scope
- [ownership] Migrated feature views hold the VM as a plain `let viewModel` (NOT `@State`) — Observation still tracks it because tracking is based on property reads in `body`, not on `@State`. Views that need `$viewModel` bindings (e.g. `$viewModel.searchText`, `.sheet(isPresented: $viewModel.show…)`) must use `@Bindable var viewModel` instead (plain `let` has no `$` projection). Grep the view for `$viewModel` to decide. #observation #swiftui
- [freshness] `load()` gains a guard so re-entry skips the refetch: watcher-backed views (have `@Environment(HermesFileWatcher.self)` + `.onChange(of: fileWatcher.lastChangeDate)`) pass `changeToken: fileWatcher.lastChangeDate` and skip when unchanged (a real on-disk change advances the token → reload); watcher-less views use a `hasLoaded || isLoading` guard. Reload buttons and post-mutation internal reloads must pass `force: true` (else `hasLoaded` makes them no-ops). #freshness
- [chose-A/B-over-C] Rejected "keep all views alive" (Option C) because 26 sections held simultaneously is heavy AND their always-on observers (Dashboard FSEvent reload from gh#102, `ServerLiveStatus` poller, `HermesFileWatcher`, Chat ACP, Kanban poller) would keep firing off-screen — reintroducing the idle work other tickets killed. Pairs with [[macos-must-mirror-ios-scene-phase-pause-and-resume-for-background-work]]. #decision
- [scope-done] Applied to the 8 list-style feature VMs: Platforms, Plugins, QuickCommands, Webhooks, Cron, MCPServers, Models, Settings. Heavy/special sections (Chat, Dashboard, Kanban, Health) stay `@State` (own lifecycles). Goal #2 (t-aud11 cancellable-load on the async VMs) + runtime/multi-window/memory verification deferred to t-aud30 — goal #1 already makes an in-flight load populate the cache rather than waste it. #scope

## Relations

- supersedes [[prefer-task-over-onappear-for-view-load-fetches-behind-switch-based-navigation]]
- relates_to [[Scarf Architecture Rules]]
- relates_to [[macos-must-mirror-ios-scene-phase-pause-and-resume-for-background-work]]


Extended 2026-09-04 by the sidebar restructure (t-e5bc2ad4), which found a second job for this cache.

- [decision] The coordinator's feature-VM cache is also the SHARING seam, not just a survival one: the main sidebar's projects well and `ProjectsView` both resolve `featureViewModel(for: .projects)`, so the always-visible list and the cockpit read one `ProjectsViewModel` — one registry read per window instead of two, and no way for the two surfaces to disagree about selection or damage #navigation
- [gotcha] A view that takes a cached VM must switch from `@State private var vm` (built in `init`) to `@Bindable var vm` passed in — leaving it as `@State` silently keeps a SECOND instance alive and the shared-state guarantee is quietly false #swiftui
- [convention] Only ONE surface should subscribe a shared VM to `fileWatcher.lastChangeDate`. When the well was added it deliberately did NOT add a second `.onChange` — `ProjectsView` already reloads the same instance per tick, and a second subscriber doubles every registry read over SSH during a chat stream #performance
