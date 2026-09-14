---
id: t-ma2brg
title: **[miniapps/M2 · test-gap]** Add ScarfMiniAppBridge dispatch tests — DONE. Extracted a WebKit-free `dispatch(method:args:reply:)` seam (`userContentController` now just decodes `{method,args}` then delegates; behavior identical) so the trust boundary is testable without a `WKScriptMessage`. Added `scarfTests/ScarfMiniAppBridgeTests` (12 tests, `@MainActor`): preflight default-deny carries `errorCode: errorMessage` AND leaves the service untouched (agent-wire spy `sentCount==0` + no store state file); per-surface gating (`prompt` denied w/o grant, `store` get/set round-trip); the dynamic `query:<kind>` gate at ScarfMiniAppBridge.swift ~178 (granted kind runs → `[]`, non-granted → permission_denied, privacy-deferred sessions/messages → not_implemented even when granted); and `file.read` containment (in-root UTF-8 returns text; `..`/absolute/symlink-escape → not_found, proving it calls the symlink-hardened `containedFilePath`). Reused the `FakeACPChannel` harness. Full app-target build + all 12 green.
status: archived
---

## Description



## Plan



## Artifacts



