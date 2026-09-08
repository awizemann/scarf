---
id: t-e0c3bd4d
title: UI gate writes the developer's window-frame preference
status: done
added: 2026-09-08
priority: low
---

## Description

Found while building the P2b UI-gate journeys (t-cd7d1c11).

`WindowFrameAutosave` persists the window frame in `UserDefaults.standard` under `ScarfWindowFrame.Scarf.Window.<ServerID>` and re-applies it on launch. `SCARF_HERMES_HOME` does not isolate that store, so:

- Running the UI gate WRITES the developer's remembered Scarf window geometry (observed: after a test run, the key held the test window's frame; it was deleted by hand to restore the default).
- Before the fix, the gate's outcome depended on that saved size — at a narrow saved frame, `CronView`'s detail pane was clipped out of the accessibility tree entirely and the journey failed on a correct build.

`CronKanbanJourneyUITests` now pins the key through `NSArgumentDomain` (`Self.windowFrameLaunchArguments`), which out-ranks the persisted value and is never written back — the same trick P1b used for the sidebar collapse keys. But the app's own didEndLiveResize/didMove observers still write on any launch that doesn't get the argument, so this belongs either in `ScarfUITestCase.makeApp()` (so EVERY test in the target is covered, like the sidebar keys should also arguably be) or behind the existing `--scarf-test-mode` launch argument, which could disable the write-back outright.

## Plan



## Artifacts

Done on ui-gate: ScarfUITestCase.makeApp() pins the window frame (origin lifted above the Dock), disables window animations, and opens every sidebar group via NSArgumentDomain for every launch; no journey sizes the window from inside anymore.

