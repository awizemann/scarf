---
id: t-a419f1fa
title: R05 Data safety: backup/restore, memory lock, health status, logs
status: done
added: 2026-09-26
priority: high
---

## Description

Findings S14-F1, S14-F2 (charter C3), S14-F3, S14-F5, S14-F4, S14-F6, S14-F7. Wave 2.

## Plan

R05 plan (worktree Scarf-wt/r05, branch fix/hermes-v0215-audit-r05).
- S14-F2 (P1, C3): RemoteBackupService — drop the `PRAGMA wal_checkpoint(TRUNCATE)` write. Snapshot state.db with a read-only sqlite3 `.backup` into a temp dir on the host, archive the snapshot in place of the live file (tar --exclude of live state.db + append snapshot), manifest flag records only a proven snapshot. Blast radius: ManageServers Back Up (Mac local + SSH). Tests: argv/script builder tests + scratch WAL db proving state.db bytes unchanged and snapshot contains WAL rows.
- S14-F1 (P1): RemoteRestoreService — detect a live Hermes holding state.db (gateway pid / fuser/lsof), refuse with a clear error (sheet says stop the gateway first); remove state.db-wal/-shm/-journal before extracting; never report success when unsafe. Tests: scratch HERMES_HOME with WAL, refusal path.
- S14-F3: restore target defaults to the server's configured Hermes home (context.paths.home parent), not $HOME.
- S14-F5: local memory save uses a Scarf-specific lock name and takes Hermes's flock on MEMORY.md.lock around the write (never deletes it). Tests: lock file survives; held flock blocks save.
- S14-F4: HealthViewModel status parser — glyph in value decides status; parse `_row` lines. Fixtures from real `hermes status` output (scratch HERMES_HOME).
- S14-F6: remote tail starts with `tail -n 0 -F`.
- S14-F7: local tail reopens on inode change / truncation.
Memory/wiki: backup/restore notes, logs, memory lock, health status notes.

## Artifacts

Merged as f17a1d0d (branch head 91d62ef6). Integration ScarfCore 3962 green. Agent: 21 ServerBackupRestoreSafetyTests, three fresh-eyes passes all fixed; full scarfTests 1662 pre-merge — post-merge full run blocked by test-runner hangs under machine load (other projects' xcodebuild sessions) → re-run in R13 gate. GNU tar/find paths unverified on Linux → verify in R14 using docker/OrbStack (available on this Mac). C3 exception approved by Alan (charter task t-b4cfc798).

