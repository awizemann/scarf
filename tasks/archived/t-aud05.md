---
id: t-aud05
title: **[t-aud05]** macOS background poll storm (gh#102-adjacent) — FIXED. `ServerLiveStatus` now floors its poll cadence at 60s while the app is not frontmost (was flat 10s + backoff). `ServerLiveStatusRegistry` observes `NSApplication.didResignActive`/`didBecomeActive` (via `MainActor.assumeIsolated` on the `.main` queue), propagates `lowPowerMode` to every status, and fires an immediate `pollNow()` on return so the menu bar refreshes promptly. Chose slow-down over full-suspend deliberately: a hard stop would freeze the always-visible MenuBarExtra status; 60s cadence keeps it fresh while killing the idle 10s SSH-poll storm. (Memory note [[macOS must mirror iOS scene-phase pause and resume for background work]] to be reconciled to slow-down at wrap-up.) Verified: macOS BUILD SUCCEEDED, no new warnings.
status: archived
---

## Description



## Plan



## Artifacts



