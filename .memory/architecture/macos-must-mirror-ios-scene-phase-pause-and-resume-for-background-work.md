---
title: macOS must mirror iOS scene-phase pause and resume for background work
type: note
permalink: scarf/architecture/macos-must-mirror-ios-scene-phase-pause-and-resume-for-background-work
tags: [lifecycle, performance, macos, architecture, audit-2026-06-13]
source_paths: [scarf/Scarf iOS/App/ScarfIOSApp.swift, scarf/scarf/scarfApp.swift]
source_paths_inferred: true
source_sha: 6a12139b218190d8a99ba679bd1a191c0bc13396
created: 2026-06-13
updated: 2026-06-13
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 Any recurring/background task (polling loops, live-status refreshers, SSH log tails) must be gated on app foreground state on macOS just as iOS gates them on scene phase — otherwise they keep running (and timing out against unreachable remotes, once per open window) when the app is backgrounded or all windows are minimized. #rule
- [pattern] macOS already listens for `NSApplication.didBecomeActiveNotification`; pair it with `didResignActiveNotification` and route both to a central pause/resume (IMPLEMENTED 2026-06-13, t-aud05, as SLOW-DOWN not full-suspend: floor the poll cadence at 60s while backgrounded rather than stopping entirely — the macOS MenuBarExtra status is always visible so a hard stop would freeze it; 60s still kills the idle 10s SSH-poll storm; fire an immediate refresh on foreground return via `ServerLiveStatus.pollNow()`). iOS reference: `ScarfGoCoordinator.setScenePhase` (`ScarfIOSApp.swift:164`) + `ChatController` via `scenePhaseTick` (`ChatView.swift:234-237`).
- [check] `grep -rn 'didResignActive\|scenePhase\|startPolling' --include="*.swift" scarf`
- [history] 2026-06-13 Cycle 3: `scarfApp.swift:346-515` — `ServerLiveStatus.startPolling` 10s loop never pauses; static fingerprint of gh#102 "100% CPU on idle connection". #history

## Relations
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
- relates_to [[Prefer .task over .onAppear for view-load fetches behind switch-based navigation]]
