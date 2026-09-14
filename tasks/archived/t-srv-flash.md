---
id: t-srv-flash
title: gh#105 menu-bar 10s flash: `ServerLiveStatus.pollOnce()` now guards each `hermesRunning` / `gatewayRunning` assignment behind an equality check. `@Observable` invalidates on every setter call (not on value change) so an unchanging healthy poll was re-rendering every dependent surface on the 10s cadence.
status: archived
source: gh#105 follow-up
---

## Description



## Plan



## Artifacts



