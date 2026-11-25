---
id: t-24fcd8cd
title: Test-mode Scarf launches hang (unit runner + UI gate)
status: done
added: 2026-11-24
priority: high
---

## Description

`xcodebuild test -only-testing:scarfTests/GatewayProcessScopeR07Tests` fails with "The test runner hung before establishing connection"; host logs `[HermesFileService] pgrep failed (exit 255)`. Reproduced on unchanged main 2026-11-24.

2026-11-24 v3.9.1 host UI gate: Full 16/39 failed, Live 11/18 failed — EVERY failure is "Failed to get matching snapshots: Timed out while evaluating UI query" at UITestIsolation.swift:357 (launchAndSurface waiting for the first window), ~195 s each. The 3 tests that launch Scarf plainly (no --scarf-test-mode, no isolated HERMES_HOME) pass. So the app is unresponsive to accessibility queries after a test-mode launch; no feature assertion was ever reached.

Lead (unproven as the cause): ~/Library/Preferences/com.scarf.app.plist is 3.8 MB (5,186 keys), near the 4 MB CFPreferences limit:
- 3,332 `NSWindow Frame SwiftUI.WindowGroup<…(unknown context at $ADDR)…>` keys = 3.4 MB. SwiftUI's derived autosave name embeds a per-build address, so every build (every test run) adds ~1 KB. Scarf restores frames from its own `ScarfWindowFrame.*` key (WindowFrameAutosave.swift), so these are useless.
- 1,737 legacy `scarf.hermesVersionLine.*` keys (1,736 temp test homes). The 2be2ebad migration is unreleased, so it hasn't run in the real app yet.
No "4194304"/CFPreferences refusal found in the last 4 h of system log.

## Plan

1. After the v3.9.1 release finishes (it uses the screen/CPU): run one failing UI test (TemplateInstallUITests/testAppLaunchesAndSurfacesAWindow) and `sample` the scarf process while it hangs — get the main-thread stack, don't guess.
2. A/B: back up com.scarf.app.plist, prune the SwiftUI window-frame and temp-home keys (with Alan's OK), rerun the same test.
3. Fix per the stack. If prefs are implicated: prune stale `NSWindow Frame SwiftUI.*`/`NSSplitView Subview Frames SwiftUI.*` keys at launch, and keep test-mode launches out of the real com.scarf.app domain.
4. Rerun the host UI gate.

## Artifacts

Fixed in fa6bc426. Root cause (sampled): HermesVersionCache.migrateLegacyKeysIfNeeded removed ~1,700 old keys one removeObject at a time on the main thread during the first window's build. Each removal posts a defaults-change notification that SwiftUI @AppStorage answers by re-reading the whole 5,000-key domain, which took seconds per key. Test launches were killed first, so the migration never finished. The fix removes them in one CFPreferencesSetMultiple call. Verified: TemplateInstallUITests/testAppLaunchesAndSurfacesAWindow went from failing at 199 s to passing in 22 s; the full scarfTests suite now runs to completion. Alan's com.scarf.app.plist was backed up to ~/Library/Preferences/com.scarf.app.plist.bak-2026-11-24, then 3,427 stale SwiftUI window-frame keys were pruned (3.4 MB → 2.6 KB). Follow-up: ~80 app-hosted tests fail, previously hidden by the hang.

