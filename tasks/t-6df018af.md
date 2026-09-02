---
id: t-6df018af
title: Chat follow-ups: pendingPermission queue, fence-split streaming fix, ACPClient start() footgun
status: done
added: 2026-09-01
---

## Description

Post-v2.24.0 lane 4 (pre-existing, small): (a) queue multiple pendingPermission requests instead of the single slot; (b) streaming markdown fence-split boundary — settle only at blank lines outside code fences; (c) close the ACPClient half-open start()/double-connect footgun.

## Plan



## Artifacts



