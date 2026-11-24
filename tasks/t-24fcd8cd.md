---
id: t-24fcd8cd
title: scarfTests runner hangs before connecting
status: todo
added: 2026-11-24
priority: high
---

## Description

`xcodebuild test -only-testing:scarfTests/GatewayProcessScopeR07Tests` fails with "The test runner hung before establishing connection"; the host logs `[HermesFileService] pgrep failed (exit 255)`. Reproduced on unchanged main (2026-11-24), so it is not caused by gh#154. App-level test suites can't run until this is fixed.

## Plan



## Artifacts



