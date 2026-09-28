---
title: Whole-server operations must cover every profile home, not just the root
type: note
permalink: scarf/conventions/whole-server-operations-must-cover-every-profile-home-not
tags: [profiles, backup, restore, cron]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteBackupService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift]
source_paths_inferred: false
source_sha: 12018c8f8fa9d17404a94138589a6d39f7a61d97
created: 2026-09-27
updated: 2026-09-27
reviewed: 2026-09-27
reviewed_by: audit:claude-code (background)
---

Recurring issue class found in the v0.21.5 audit (R14 X2/X3, fixed in R16a): Server Back Up and Restore treated the Hermes home root as the only home. Each `profiles/<name>/` is a complete HERMES_HOME with its own credentials, tokens and cron store, so anything a whole-server operation does "for the home" has to be done for each profile too.

## Observations
- [convention] A Scarf operation that acts on a whole server (backup, restore, cron pause, cleanup) must apply each per-home rule at the root AND at every profiles/<name>/ — per-profile files include auth.json (hermes_cli/auth.py:481-482), mcp-tokens/ (tools/mcp_oauth.py:229-232), gateway_state.json, logs/, cron/jobs.json (cron/jobs.py:62-74 @ v2026.9.24) #profiles
- [gotcha] Tar --exclude `*` crosses `/` in GNU tar and bsdtar but NOT in BusyBox tar; `profiles/*/auth.json` over-excludes deeper same-named files on the first two (fine for secrets) — for user-data dirs like logs/, name each profile exactly from a listing instead #backup
- [gotcha] Hermes cron: a job with no `enabled` key is armed (default True), and is_job_runnable also honours pause markers (state==paused / truthy paused_at, cron/jobs.py:516-524); jobs.json may be a dict-with-list, an id-keyed map, or a bare list (:1355-1376) #cron
- [decision] RemoteRestoreService.pauseAllCronJobs tries every home (root first), collects failures, and throws one error naming each file left armed after pausing the rest #restore

## Relations
- relates_to [[Skills "What's New" snapshot is keyed per (server, profile)]]
