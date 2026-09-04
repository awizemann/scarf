---
title: Registry writes take a reentrant cross-process file lock; remote is best-effort local
type: note
permalink: scarf/decisions/registry-writes-take-a-reentrant-cross-process-file-lock
tags: [projects, registry, concurrency, mcp, dataloss, locking]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RegistryWriteLock.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift]
source_paths_inferred: false
source_sha: 1d6a6ecb3075529e5d58bb2e2897546d061811f9
created: 2026-09-04
updated: 2026-09-04
---

t-db8c745b. Since the `scarf-projects` MCP helper shipped, `projects.json` has had two writing PROCESSES plus ~6 in-app writers, and the chokepoint's inspect-then-publish was a TOCTOU between them: both sides publish atomically so nothing tears, but the loser's rows vanish and `.bak` holds the loser's state rather than the user's previous one. `RegistryWriteLock` closes it with a lock FILE and a staleness timeout — deliberately not a clever protocol.

## Observations
- [decision] The lock is taken at `ProjectDashboardService.saveRegistry` AND at `ProjectStore.indexInRegistry`, because the latter is itself a read-modify-write — a lock around only the inner publish would leave exactly the window it exists to close #projects
- [decision] It is REENTRANT within a thread via a `Thread.threadDictionary` depth keyed on the lock path; every call in the chain is synchronous and `nonisolated`, so there is no suspension point between acquire and release. Non-reentrant, indexInRegistry self-deadlocks on every project save #gotcha
- [constraint] LOCAL contexts lock `<path>/projects.json.lock` via `O_CREAT|O_EXCL` beside the registry, so the app and the helper (which resolves the LOCAL home only) contend on one inode. REMOTE contexts lock a local stand-in in Application Support keyed by a digest of host|path: every remote writer funnels through this app's transports, so two Macs on one remote ~/.hermes are NOT serialized — documented, not half-built #remote
- [gotcha] Waiting is bounded at 2s and then throws `ProjectRegistryError.registryBusy` (a reportable failure, not a clobber); a lock older than 30s is BROKEN, so a crashed holder cannot brick the registry. A context with no derivable lock path proceeds UNLOCKED rather than losing the ability to save at all #constraint
- [gotcha] The lock file is a sibling of `projects.json`, and `HermesFileWatcher` watches the registry FILE (not `~/.hermes/scarf/`), so creating/removing it per save does not add watcher ticks — verify this again if the watcher is ever widened to the directory #performance

## Relations
- relates_to [[Projects registry is salvage-decoded, quarantined, and empty-save-guarded]]
- relates_to [[scarf-projects MCP server: bundled helper, ScarfCore services, no parallel writers]]
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]


## PF: the baseline check that covers what the lock cannot

t-45594d27, from the P7 audit addendum ("`saveRegistry` never compares against its load baseline — a ≥3s stale-overwrite window on remotes").

- [decision] `RegistryLoadResult` now carries a `contentFingerprint` (FNV-1a over the bytes, prefixed with their length — cheap, in-process, explicitly NOT a security digest), and `saveRegistry(_:allowEmpty:expecting:)` refuses with `ProjectRegistryError.refusedStaleOverwrite` when the file on disk no longer matches the baseline the write was computed from. The comparison happens INSIDE the lock, so the file compared is the file about to be replaced.
- [constraint] This is deliberately NOT a sync protocol: no negotiation, no merge, no retry. It exists for the case the constraint above names as unserialized — two Macs on one remote `~/.hermes`, where the read and the write are seconds apart over SSH and the lock is a local stand-in. Same-machine writers are still the lock's job.
- [decision] `expecting:` defaults to `nil`, and a nil baseline skips the check entirely — an installer writing a registry it just built has no baseline to offer, and must keep working. Only `ProjectsViewModel`'s mutators pass one today, carried as a VALUE beside the registry (`LoadedForMutation`) rather than parked on the view model, because the mutators are async now and two of them can interleave across their reads.


## L2: ownership token, context-aware bounds, and the rest of the read-modify-writes

t-07e909e0, from the P8 audit (DI H4/H5/M4/M5, SEC M5). The lock was correct about the race it named and wrong about everything it inherited from the local case.

- [decision] `release()` verifies OWNERSHIP before removing. `tryCreate` writes `owner=<uuid>` into the lock file; `release(token:)` reads it back and removes ONLY on a match, otherwise logs and walks away. Without it the H4 sequence was live data loss: a slow remote holder is declared stale, a contender breaks the lock and creates its own, the first holder finishes and deletes the CONTENDER's file, and two writers then run the registry RMW unserialized. `O_CREAT|O_EXCL` still does the excluding; the token only decides who may delete. The read-then-remove is a microsecond-wide TOCTOU that is deliberately not closed (no atomic compare-and-delete exists) — it restores the old behaviour, it does not add a new failure #gotcha
- [decision] `staleAfter` and `acquireTimeout` are per-CONTEXT instance properties, not global constants. Local 30s/2s (unchanged — a local write is microseconds). Remote 300s/60s: one remote save is an inspect + a `.bak` scp + a staged scp + a rename, measured near 60s on a bad link, so the old bounds declared live holders dead (H4's root cause) and reported `registryBusy` in ordinary use (M5). A 60s wait is defensible against C10 because a caller blocked there was about to block ~60s on its own write anyway #remote
- [decision] Chose a bigger `staleAfter` over a holder HEARTBEAT. A heartbeat keeps the stale bound small but needs a timer/thread beside a synchronous write, on every platform, with teardown-on-throw, and it writes the lock file while contenders read it. The cost of the boring option is that a genuinely crashed remote holder wedges contenders for up to 5 minutes — bounded, rare, and now harmless thanks to the token #constraint
- [decision] Lock + `expecting:` extended to every remaining registry RMW: `ProjectDoctorService.repair` (the whole repair, load included), `ProjectTemplateInstaller.registerProject`, `ProjectTemplateUninstaller`'s row removal (extracted to `removeRegistryRow`), and `RemoteRestoreService.reanchorProjectsRegistry` (DI-L1, locking on the restore's OWN target path — a restore can target an overridden home). Each loads INSIDE the lock and passes that load's fingerprint to the save #projects
- [decision] `repairAllSafe` takes the lock PER REPAIR rather than across the pass: repairs are independent, one can be a slow SSH record write, and re-reading per repair is what lets the pass see rows that appeared while it ran. This is what fixes "Repair All erases a concurrent project_register" #gotcha
- [decision] SIDECARS (M4): `MiniAppGrantStore.mutate` and `SessionAttributionService.mutate` take the same lock, keyed on their OWN file path (`<path>.lock`), so a permission write never queues behind a projects.json save. Cross-DEVICE stays last-write-wins BY CONSTRUCTION and is now documented as such: a Mac and an iPhone on one remote `~/.hermes` hold local stand-in locks that cannot see each other. Tolerable where it is not for the registry — a dropped grant re-prompts, a dropped attribution is re-derived, a dropped project row exists nowhere else #remote
- [gotcha] The lock file is AGENT-WRITABLE (SEC-M5) and now says so in its own header: anything with write access to `~/.hermes/scarf/` can hold it (DoS until the staleness bound) or delete a live one (re-opening the race for one write). It is a protocol between COOPERATING Scarf processes, never an integrity guarantee. The integrity layer is `saveRegistry`'s guarded inspect — refuse over damage, over an unexpected `expecting:` fingerprint, over a non-empty file with an empty list — which holds whether or not the lock was honoured #security
- [constraint] Every new hold is one SYNCHRONOUS `nonisolated` frame, verified case by case: reentrancy is a `Thread.threadDictionary` depth, so a hold spanning an `await` would set the depth on one thread and clear it on another and leak the file lock. `RemoteRestoreService.reanchorProjectsRegistry` is `async` but its locked closure is not, which is the shape to copy. No cross-lock cycle exists either — the uninstaller's grant cleanup runs AFTER the registry lock is released, and registry→sidecar is the only ordering anywhere #gotcha
