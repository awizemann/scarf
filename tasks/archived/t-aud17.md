---
id: t-aud17
title: **[t-aud17]** Perf cleanup — DONE. `ChatQueueIndicator` `ForEach(Array(queuedPrompts.enumerated()), id:.element.id)` → `ForEach(queuedPrompts.indices, id:.self)` (no per-eval Array alloc; `.indices` is a `Range`). `BackupServerSheet` gained `.onDisappear { viewModel.cancel() }` so dismissing mid-backup cancels the remote `tar`/SSH work. Verified: macOS BUILD SUCCEEDED, no new warnings.
status: archived
---

## Description



## Plan



## Artifacts



