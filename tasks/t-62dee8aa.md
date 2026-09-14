---
id: t-62dee8aa
title: MCPServersViewModel.deleteServer is a two-way if on a three-state verdict
status: todo
added: 2026-09-13
priority: low
---

## Description

Found during P54's lesson-12 sweep (grep every consumer of a verdict with a `confidence` for a two-way `if`). This one is a consumer of a PRE-EXISTING verdict (`HermesMCPRemoveVerdict`, P40), not of a verdict P54 added, so it was out of scope and is filed rather than fixed.

`scarf/scarf/Features/MCPServers/ViewModels/MCPServersViewModel.swift:~157-168`: `fileService.removeMCPServer(name:)` returns a full `HermesCLIOutcome`, and the call site branches on `.succeeded` only. `HermesMCPRemoveVerdict.judge` returns `.unconfirmed` for exit 0 with neither `Removed '` (`hermes_cli/mcp_config.py:524` @ `v2026.9.7`) nor a refusal marker, so that arm falls into the failure branch and shows `Remove failed: <last line>` — quoting an unrelated tail as Hermes's reason for a refusal it never made.

This is the same class as the bug P54's own review caught in five new helpers: the fix there was to gate the honest branch on `outcome.confidence == .unconfirmed` ALONE (never on `detail` being empty, because `judge` fills `detail` with `lines.last` on every arm). Apply the same shape here, and give it an unconfirmed-WITH-output test — an unconfirmed fixture that is the empty string passes the buggy version too.

Precedents to mirror: `CredentialPoolsViewModel.removeFailureSummary` (P53), `HealthViewModel.sessionsOptimizeSummary` (P47b), `SettingsViewModel.backupFailureSummary` (P54).

## Plan



## Artifacts



