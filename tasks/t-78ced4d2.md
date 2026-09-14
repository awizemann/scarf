---
id: t-78ced4d2
title: Wire iOS log streaming: CitadelServerTransport.streamLines is an M3 stub
status: todo
added: 2026-09-13
---

## Description

`ScarfIOS/CitadelServerTransport.streamLines(executable:args:)` returns `AsyncThrowingStream { $0.finish() }` — an M3 stub. `HermesLogService.openLog(path:)`'s remote branch drives `tail -n N -F <path>` through `transport.streamLines`, so on iOS that branch yields nothing and the Logs pane shows only whatever the snapshot read produced. Found in round-6 P58: the comment at `HermesLogService.swift:82-84` CLAIMED iOS streamed through a Citadel exec channel. P58 fixed the comment only (commit on `fix/whole-surface-audit-r6`) and did not wire it.

To wire it: Citadel's raw exec channel already drives `CitadelServerTransport.runExec` / `withExec` (bounded since round-5 P48/P48b) — a streaming variant needs to yield lines as they arrive instead of accumulating, and needs a cancellation path that closes the channel when the consumer drops the stream (the Mac twin's `StreamingChild` + `PipeReader` shape, round-6 P58). A `tail -F` never ends, so the ceiling that bounds `runExec` cannot simply be reused.

## Plan



## Artifacts



