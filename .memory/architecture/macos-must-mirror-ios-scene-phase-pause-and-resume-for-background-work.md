---
title: macOS must mirror iOS scene-phase pause and resume for background work
type: note
permalink: scarf/architecture/macos-must-mirror-ios-scene-phase-pause-and-resume-for-background-work
tags: [lifecycle, performance, macos, architecture, audit-2026-06-13]
source_paths: [scarf/scarf/scarfApp.swift, scarf/Scarf iOS/App/ScarfGoCoordinator.swift, scarf/Scarf iOS/App/ScarfGoTabRoot.swift, scarf/Scarf iOS/Chat/ChatView.swift]
source_paths_inferred: false
source_sha: ebfef32ea30937a78516be06e7bba5bbf07f0ac3
created: 2026-06-13
updated: 2026-06-13
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

## Observations
- [rule] 🚨 Any recurring/background task (polling loops, live-status refreshers, SSH log tails) must be gated on app foreground state on macOS just as iOS gates them on scene phase — otherwise they keep running (and timing out against unreachable remotes, once per open window) when the app is backgrounded or all windows are minimized. #rule
- [pattern] macOS listens for `NSApplication.didBecomeActiveNotification` and `didResignActiveNotification` via `ServerLiveStatusRegistry` (lines 852–859); both route to `setLowPowerMode()` which floors the poll cadence at 60s while backgrounded instead of stopping entirely — the macOS MenuBarExtra status is always visible so a hard stop would freeze it; 60s still kills the idle 10s SSH-poll storm; fire an immediate refresh on foreground return via `ServerLiveStatus.pollNow()`. iOS reference: `ScarfGoCoordinator.setScenePhase` (defined at `ScarfGoCoordinator.swift:86`, called from `ScarfGoTabRoot.swift:107–108`) + `ChatView` observes `scenePhaseTick` at `ChatView.swift:284`.
- [check] `grep -rn 'didResignActive\|scenePhase\|startPolling' --include="*.swift" scarf`
- [history] 2026-06-13 Cycle 3: `ServerLiveStatus.startPolling` (lines 604–633) implements 10s loop floored at 60s in lowPowerMode; `ServerLiveStatusRegistry` (lines 822–859) wires app-active notifications to `setLowPowerMode()`. Static fingerprint of gh#102 "100% CPU on idle connection". #history

## Relations
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
- relates_to [[Prefer .task over .onAppear for view-load fetches behind switch-based navigation]]
