---
id: t-aud24
title: **[t-aud24]** Eliminate redundant remote re-fetch on sidebar section switches — **goal #1 DONE** (architectural). Chose Option A/B (coordinator data cache) over Option C (keep-views-alive): the detail `switch` has 26 sections and Option C would hold them all + keep their observers — Dashboard FSEvent reload (gh#102), pollers, watchers — running off-screen, reintroducing idle work. Added `AppCoordinator.featureViewModel(for:make:)` — an `@ObservationIgnored` per-section VM cache; the coordinator lives in `ContextBoundRoot` (keyed `.id(context.id)`) so the cache is implicitly per-window/-server and dropped on server switch (no manual invalidation). `ContentView` resolves the 8 feature VMs through it (`cachedVM` helper) so the instance + its loaded data survive section switches; each `load()` gained a freshness guard so re-entry is a no-op not a refetch — token-based (`changeToken: fileWatcher.lastChangeDate`) for the watcher-backed views (Platforms, Cron), `hasLoaded||isLoading`-based for the rest, with Reload/post-mutation reloads passing `force: true`. Views that bind to their VM use `@Bindable var` (Cron, MCPServers); the rest hold a plain `let` (both still observed). 9 features: Platforms/Plugins/QuickCommands/Webhooks/Cron/MCPServers/Models/Settings (+ Health already cancellable from t-aud11). Verified: macOS BUILD SUCCEEDED, 0 warnings (3 commits). NOT runtime-verified (can't drive the GUI headlessly) + goal #2 (cancellable-load) deferred → both split to t-aud30.
status: archived
---

## Description



## Plan



## Artifacts



