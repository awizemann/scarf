---
title: Hermes v0.21.4 non-zero exits that are NOT failures (backup, profile delete, peer dm) and the optimize holder refusal
type: note
permalink: scarf/architecture/hermes-v0-21-4-non-zero-exits-that-are-not-failures-backup
tags: [hermes-cli, hermes-v0-21-4, capability-gating, verdicts]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPeerCLI.swift, scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift, scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift]
source_paths_inferred: false
source_sha: 7b7bc9fb67279185d89be0cb114238b45687025f
created: 2026-09-26
updated: 2026-09-26
---

From v2026.9.21 several verbs Scarf runs exit 1 on outcomes that completed, and `sessions optimize` refuses under any holder. Scarf recognises each by tagged bytes (plus flags in HermesCapabilities v0.21.4 group). Verified at v2026.9.21 and v2026.9.24.

## Observations
- [gotcha] `hermes sessions optimize` exits 1 with `Refusing \`hermes sessions optimize\`:` whenever ANY process holds state.db/-wal/-shm (hermes_state_holders.py foreign_state_db_holders counts readers too) — on a local host Scarf's own LocalSQLiteBackend connection is always a holder, so only `--force` (hasSessionsOptimizeForce) can run it from Scarf #hermes-cli
- [fact] `hermes backup` exits 1 on an incomplete archive but KEEPS the zip (main.py:2254, backup.py:750 `Archive kept, but N file(s) could not be added:`); HermesBackupVerdict.judge needs capabilities to read that as a partial success #hermes-cli
- [fact] `profile delete` can exit 1 with `was deleted, but its session/routing identity settlement is still pending` AFTER the directory is gone — HermesProfileDeleteVerdict reports a completed delete with Hermes's retry sentence #hermes-cli
- [gotcha] `peer dm` exit 1 `accepted the message … Do NOT resend` and the `{status: queued}` payload both mean the peer HAS the message; Scarf's 600s process timeout used to kill the CLI before that line printed, so v0.21.4+ gets 660s (HermesPeerCLI.dmProcessTimeout) #hermes-cli
- [fact] v0.21.4 removed the cron create-time model snapshot (_compute_provider_model_snapshots, cron resnap): unpinned jobs follow the main model at fire time; `cron create --pin` / `cron edit --pin|--unpin` (unpin clears model AND provider) are the only freeze #cron

## Relations
- relates_to [[Judging a Hermes verb by its output: the exit-0 refusal FAMILY and the anchored-prefix rule]]
