---
id: t-0fb3b91f
title: Cron detail pane is unreachable: no click/context menu, absent from a11y tree
status: done
added: 2026-09-08
priority: high
---

## Description

Found while building the P2b UI-gate journeys (t-cd7d1c11).

`CronView`'s job list does not respond to synthesized interaction at all, and its detail pane never appears in the accessibility tree:

- Left-clicking `cron.row.<id>` never selects the job (retried 6x per run, across window sizes up to full screen, both with and without the fixture home).
- Right-clicking the row never presents its context menu (Pause / Run Now / Edit / Delete).
- The detail pane — the second child of `CronView`'s `HSplitView` — has NO elements in the tree: not `cron.detail.pauseToggle`, not the trash button, not even the "Select a cron job" placeholder text. The list pane is fully present.

Consequences: (1) the UI gate cannot exercise cron pause/delete — `CronKanbanJourneyUITests.testCronJobCreatePauseDelete` wraps those steps in `XCTExpectFailure(strict: false)` so the suite stays green while this is open; (2) more seriously, "absent from the accessibility tree" is the same condition VoiceOver sees, so a VoiceOver user likely cannot reach the cron detail pane or act on a job at all.

Repro: run `xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf -destination 'platform=macOS' -testPlan Full -only-testing:scarfUITests/CronKanbanJourneyUITests/testCronJobCreatePauseDelete` and read the expected-failure detail in the result bundle. Remove the `XCTExpectFailure` wrapper once fixed — the assertions underneath are already written.

Worth checking whether `HSplitView` is the cause (Kanban's plain `HStack` panes are fully addressable) and whether the row `Button(...).buttonStyle(.plain)` inside `LazyVStack` reports a usable frame.

## Plan



## Artifacts

Root cause: a .plain Button whose background is Color.clear only takes clicks on its glyphs; the empty row middle fell through to the ScrollView. Fixed with .contentShape(Rectangle()), HSplitView replaced by HStack + resizableColumn (the split's min-widths overflowed and a clipped subtree leaves the AX tree), row label/value/isSelected per the a11y conventions. Unit test CronViewAccessibilityTreeTests walks the AX tree via NSHostingView (needs accessibilityEnhancedUserInterface). Context-menu items carry cron.contextMenu.pauseToggle/.delete (the Edit menu also has a Delete). Cron create → pause → delete journey passes unwrapped (58 s) against the seeded fixture.

