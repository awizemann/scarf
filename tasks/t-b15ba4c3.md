---
id: t-b15ba4c3
title: Move AppRelauncher.relaunch()'s open(1) wait off the main actor
status: todo
added: 2026-09-10
priority: low
---

## Description

Found in P33 (`t-eff9696b`) while bounding the three ad-hoc `Process` spawns.

`AppRelauncher` is `@MainActor` and `relaunch()` (`scarf/scarf/Core/Services/AppRelauncher.swift:80-100`) spawns `/usr/bin/open -n <bundleURL>` and waits for it synchronously. P33 bounded that wait (`Process.waitDraining(timeout: AppRelauncher.openTimeout, ...)`, 20s) and drains stderr/stdout concurrently, so the C10 "every subprocess has a timeout" half is done — but the wait is still ON the main actor, so a wedged LaunchServices (`lsd` / `launchservicesd`) freezes the window for up to 20s.

The hop was not done in P33 because the only caller is inside a `MainActor.run` block: `ProfilesViewModel.switchAndRelaunch` (`scarf/scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift:85-112`, `Task.detached { ... await MainActor.run { ... try AppRelauncher.relaunch() ... } }`). Making `relaunch()` `async` (or `nonisolated` with a detached spawn+wait) means restructuring that block, which is outside P33's scope.

Fix: make `relaunch()` `nonisolated` — it touches only `Bundle.main`, `Process` and the logger — and either `await` it from a detached task in `switchAndRelaunch`, or keep the sync signature and do the spawn+wait inside a `Task.detached` whose value the caller awaits. Keep the 20s bound and the `waitDraining` drain order; the `NSApp.terminate` follow-up must still run on the main actor after it.

## Plan



## Artifacts



