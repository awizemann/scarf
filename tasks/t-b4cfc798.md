---
id: t-b4cfc798
title: Charter C3: allow user-initiated Server Restore to swap Hermes .db files
status: todo
added: 2026-09-26
---

## Description

Tag: charter. Alan decided 2026-09-26 (remediation R05, t-a419f1fa) that a user-initiated Server Restore may replace state.db and other Hermes *.db files on the target when no process holds them, mirroring Hermes's own `hermes import` (backup.py:536-559 @ v2026.9.24: holder check, sidecar removal, atomic move). Proposed C3 wording: "Never write to state.db — Scarf reads it read-only; all mutations go through the hermes CLI or ACP, except a user-initiated Server Restore that swaps whole database files while nothing holds them." Charter is human-only — Alan to edit.

## Plan



## Artifacts



