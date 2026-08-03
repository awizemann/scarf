---
id: t-44f5de1b
title: v0.20 Wave C3 — approvals suggest + cron runs history
status: done
added: 2026-08-03
---

## Description

Gated on hasApprovalsSuggest / hasCronRuns: (1) `hermes approvals suggest --json [--days --min-count]` → proposals list in Settings/Health with an apply action (`--apply N,...`). (2) `hermes cron runs [job_id] [--limit]` → per-job execution history in the Cron tab. Parse real output shapes (check --json first; runs may be tabular). Tests for parsers.

## Plan



## Artifacts



