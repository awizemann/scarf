---
id: t-ba7bbc57
title: v0.22.5 S5: session source display and session fixes
status: done
added: 2026-10-25
priority: high
---

## Description

Read created_source (PRAGMA-detected) and show the real surface when source='local'; desktop platform entry; sessions delete refusal reasons; last-active bad-timestamp guard. Plan A3 display, B9, E.

## Plan



## Artifacts

Commit 43a65475 cherry-picked. Audit: one C1 note — tui/desktop rows on older hosts now get correct icons; accepted as a cosmetic bug fix under the 2026-09-27 rule (byte-identical protects new affordances, not wrong icons).

