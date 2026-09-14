---
title: Driving Cron and Kanban from XCUITest: what actually works
type: note
permalink: scarf/conventions/driving-cron-and-kanban-from-xcuitest-what-actually-works
tags: [testing, xcuitest, cron, kanban, gotcha]
source_paths: [scarf/scarf/ContentView.swift, scarf/scarf/Features/Cron/Views/CronView.swift, scarf/scarf/Features/Kanban/Views/KanbanColumnView.swift]
source_paths_inferred: false
source_sha: 698bee2966bf21228c03b00df7fe0105d7e61781
created: 2026-09-08
updated: 2026-09-08
reviewed: 2026-09-12
reviewed_by: claude-opus-5
---

Learned building the P2b write-path journeys (t-cd7d1c11, 2026-09-08), measured on this Mac against Hermes v0.21.0.

## Observations
- [gotcha] `hermes kanban list` parenthesises the assignee column ONLY when there is none — `(unassigned)` vs a bare `test-override`. A regex requiring the parens parses zero rows for every card Scarf creates (Scarf assigns the active profile), which reads as "the create never reached the CLI" #kanban #gotcha
- [convention] Identify a record created through the UI by DIFFING ids before/after, never by the typed name: synthesized typing drops and leaks characters between SwiftUI fields (a job typed `UIG-9799` was created as `UIG-9799n`) #testing
- [gotcha] `WindowFrameAutosave` keeps the window frame in UserDefaults.standard, which SCARF_HERMES_HOME does not isolate — the gate's result depended on the developer's last window size, because CronView's HSplitView detail pane gets CLIPPED and a clipped SwiftUI subtree is absent from the a11y tree. Pin it with a `-ScarfWindowFrame.Scarf.Window.<localID>` launch arg whose value is QUOTED: a bare `{…}` parses as an old-style plist dict, not a string. `ScarfUITestCase.makeApp()` now does this for every launch, with the origin lifted to `{{40, 140}, …}`: AppKit's y=0 is UNDER the Dock, and a window pinned there had its bottom strip occluded — the Kanban inspector's Block button (y 2835–2868 on a 2880 pt screen, visible frame ending at 2850) took every click into the Dock, which read as "the sheet never presented" #testing #gotcha
- [gotcha] CronView's job list WAS inert to XCUITest — no click selection, no context menu, and therefore a detail pane with nothing to show. Cause (t-0fb3b91f, fixed 2026-09-08): a `.plain` Button's hit area is its label's OPAQUE content, and an unselected row's background is `Color.clear`, so only the glyphs took clicks — a click at the row's CENTRE (what XCUITest does, and where a mouse user aims) fell through to the ScrollView. `.contentShape(Rectangle())` inside the label is the fix; any hand-rolled row whose only fill is its selected-state background needs it #cron #a11y
- [convention] A hosted `NSHostingView` publishes NO accessibility children in a test process until `NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")` is set — with it, a plain XCTest can walk the real AppKit AX tree (roles, identifiers, labels, values, frames) of a SwiftUI view and assert what VoiceOver/XCUITest would see, WITHOUT running the UI gate. `scarf/scarfTests/CronViewAccessibilityTreeTests.swift` is the worked example; always include a probe-works test or a harness regression reads as green #testing #a11y
- [gotcha] `HermesVersionCache` keys its persisted answer on the HOME PATH, so every isolated test home is a cold `hermes --version` probe (10 s subprocess timeout). Until 2026-09-08 a single miss hid every capability-gated row (Kanban, Models, Peers, Proxy) for the life of the window; the async probe now retries twice (1.5 s, 4 s) and logs a persistent .error when all attempts fail — a journey that still finds the row absent should read that log line before blaming the host version #testing #gotcha

## Relations
- relates_to [[XCUITest runner gotchas: env vars need TEST_RUNNER_, identifiers propagate, ⌘1 keystrokes get dropped]]
- relates_to [[UI gate: section root identifiers and the Smoke/Full/Live test plans]]
