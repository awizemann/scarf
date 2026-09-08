---
id: t-ba501bbf
title: GW-F1: uninstall refusal-ordering — cleanup must survive a MEMORY.md refusal
status: done
added: 2026-09-04
priority: urgent
---

## Description

From documents/reports/2026-09-04-gw-e5-full-surface-audit.md (SEC F1, DI M1/M2/M3). Move the MEMORY.md read-proof into the uninstall plan phase before any destructive step; catch stripMemoryBlock refusal → warning → ALWAYS run Keychain deletion and later steps (ProjectLifecycleService pattern); add compensating Keychain delete when config-sheet save refuses after writing the item.

## Plan



## Artifacts



