---
id: t-db8c745b
title: Projects follow-up: cross-process registry write lock (all writers)
status: done
added: 2026-09-03
---

## Description

P4/P5 deferral, deliberately not landed piecemeal: with the scarf-projects MCP server, projects.json now has two writing processes (app + helper) plus ~6 in-app writers. A lock helps only if EVERY writer takes it across the whole read-modify-write; locking just the helper would read as safety while the app-side race stayed open. Design one shared advisory-lock (or single-writer funnel) covering ProjectDashboardService.saveRegistry callers in both processes. See the Phase-4 doctor note's deferral edit for reasoning.

## Plan



## Artifacts

Landed as `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RegistryWriteLock.swift`, taken at BOTH registry chokepoints: `ProjectDashboardService.saveRegistry` (inspect → guards → `.bak` → publish) and `ProjectStore.indexInRegistry` (load → row edit → saveRegistry), so the lock covers whole read-modify-writes, not just the publish.

**Semantics**
- LOCAL context: `O_CREAT|O_EXCL` on `<hermes home>/scarf/projects.json.lock`, beside the registry — the app and the bundled `scarf-projects` MCP helper (which resolves the LOCAL home only) contend on one inode. That is the two-process case the ticket is about.
- REMOTE context: a LOCAL stand-in lock in `Application Support/Scarf/locks/<digest(host|path)>.lock`. Every writer to a remote registry funnels through this app's transports, so this serializes the real population; two different Macs on one remote `~/.hermes` are explicitly NOT serialized (an advisory file over SSH needs its own create-exclusive primitive, and the stale-lock story over a flaky link is worse than the race). Documented, not half-built.
- Reentrant within a thread (`Thread.threadDictionary` depth keyed on the lock path) — every call in the chain is synchronous/`nonisolated`, so there is no suspension point; non-reentrant would self-deadlock on every project save.
- Bounded wait 2s → throws `ProjectRegistryError.registryBusy(path:)` (reportable failure, never a silent clobber, and bounded against charter C10). Locks older than 30s are broken, so a crashed holder can't brick the registry. A context with no derivable lock path proceeds unlocked rather than losing the ability to save.

**Verification**: `concurrentRegistryWritersDoNotLoseEachOthersRows` (8 concurrent read-modify-writes, all 9 rows survive) — falsified by disabling the lock, where it fails. Plus exclusivity/timeout, stale-break, reentrancy, and lock-path tests. Memory: `scarf/decisions/registry-writes-take-a-reentrant-cross-process-file-lock`.

**Residual**: grants / session map / cron have the guarded shape but no cross-process lock. Under contention `saveRegistry` can now block a main-actor caller up to 2s (pre-existing main-actor sync transport IO, audit PF-M1).

