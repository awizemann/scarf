---
title: macOS must mirror iOS scene-phase pause and resume for background work
type: note
permalink: scarf/architecture/macos-must-mirror-ios-scene-phase-pause-and-resume-for-background-work
tags: [lifecycle, performance, macos, architecture, audit-2026-06-13]
source_paths: [scarf/scarf/scarfApp.swift, scarf/Scarf iOS/App/ScarfGoCoordinator.swift, scarf/Scarf iOS/App/ScarfGoTabRoot.swift, scarf/Scarf iOS/Chat/ChatView.swift]
source_paths_inferred: false
source_sha: 904c0e60784d0936f39ccbd47242201c12ef23d0
created: 2026-06-13
updated: 2026-06-13
reviewed: 2026-09-22
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 Any recurring/background task (polling loops, live-status refreshers, SSH log tails) must be gated on app foreground state on macOS just as iOS gates them on scene phase — otherwise they keep running (and timing out against unreachable remotes, once per open window) when the app is backgrounded or all windows are minimized. #rule
- [pattern] macOS already listens for `NSApplication.didBecomeActiveNotification`; pair it with `didResignActiveNotification` and route both to a central pause/resume (IMPLEMENTED 2026-06-13, t-aud05, as SLOW-DOWN not full-suspend: floor the poll cadence at 60s while backgrounded rather than stopping entirely — the macOS MenuBarExtra status is always visible so a hard stop would freeze it; 60s still kills the idle 10s SSH-poll storm; fire an immediate refresh on foreground return via `ServerLiveStatus.pollNow()`). iOS reference: `ScarfGoCoordinator.setScenePhase` (defined at `ScarfGoCoordinator.swift:86`, called from `ScarfGoTabRoot.swift:108`) + `ChatView` observes `scenePhaseTick` at `ChatView.swift:284`.
- [check] `grep -rn 'didResignActive\|scenePhase\|startPolling' --include="*.swift" scarf`
- [history] 2026-06-13 Cycle 3: `scarfApp.swift:566-595` — `ServerLiveStatus.startPolling` 10s loop pauses at 60s in lowPowerMode; static fingerprint of gh#102 "100% CPU on idle connection". #history

## Relations
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
- relates_to [[Prefer .task over .onAppear for view-load fetches behind switch-based navigation]]
