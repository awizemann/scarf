---
title: XCUITest runs must be serialized on one Mac: parallel agents cannot each drive Scarf
type: note
permalink: scarf/conventions/xcuitest-runs-must-be-serialized-on-one-mac-parallel-agents
tags: [testing, xcuitest, orchestration, gotcha]
created: 2026-09-08
updated: 2026-09-08
---

Learned 2026-09-08 orchestrating the UI-gate build with parallel sub-agents in worktrees. Three `xcodebuild test` runs plus an orphaned test-mode Scarf were alive at once; the orchestrator's own Smoke run then took 175 s to surface a window, Dashboard took 67 s, and a sidebar click hung 16 s — all interference, not product bugs.

## Observations
- [constraint] Only ONE XCUITest session may run on a Mac at a time: macOS UI tests share activation, keyboard focus and the ⌘1 window-surface nudge, so concurrent runners steal each other's focus, `Wait for app to idle` balloons to 15-30 s, and `launchAndSurface` exhausts its retries #testing #orchestration
- [convention] Sub-agents that need to run UI tests must wait for `pgrep -f 'xcodebuild test'` to be empty before starting and must never kill another run; the orchestrator runs its own verification only after every agent has finished #orchestration
- [gotcha] A UI-test run that is killed or times out can leave `scarf --scarf-test-mode …` alive (seen from scripts/ui-gate.sh's DerivedData under /private/tmp/scarf-uigate-dd); check `pgrep -f 'scarf.app/Contents/MacOS/scarf'` before blaming the product for slow idle #testing
- [gotcha] Symptoms of interference in the emitted test log: `[DisplayManager] Could not find any displays containing rect`, repeated `Retrying Type '1' key`, and `Check for interrupting elements` taking >10 s; a real hang shows the same shape, so rerun alone before filing a C10 finding #testing

## Relations
- relates_to [[XCUITest runner gotchas: env vars need TEST_RUNNER_, identifiers propagate, ⌘1 keystrokes get dropped]]
- relates_to [[UI gate: section root identifiers and the Smoke/Full/Live test plans]]
