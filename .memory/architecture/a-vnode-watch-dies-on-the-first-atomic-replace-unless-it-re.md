---
title: A vnode watch dies on the first atomic replace unless it re-arms on .delete
type: note
permalink: scarf/architecture/a-vnode-watch-dies-on-the-first-atomic-replace-unless-it-re
tags: [watcher, fsevents, projects, phase-5, gotcha]
source_paths: [scarf/scarf/Core/Services/HermesFileWatcher.swift, scarf/scarfTests/HermesFileWatcherAtomicReplaceTests.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/LocalTransport.swift]
source_paths_inferred: false
source_sha: d21211a80383f52362a245594865a321c60dc058
created: 2026-09-03
updated: 2026-09-04
---

Found during the Phase-5 adversarial audit (projects-first-class, t-3d915f7f) and fixed there. `HermesFileWatcher.makeSource` armed a `DispatchSource` vnode watch with `eventMask: [.write, .extend, .rename]` — and nearly every file it watches is written by `transport.writeFile`, which is `Data.write(.atomic)`: temp file plus `rename(2)` over the destination. The watched INODE is therefore never modified, only unlinked.

## Observations
- [gotcha] MEASURED, not reasoned: a `[.write, .extend, .rename]` vnode watch sees ZERO events for two atomic replaces of the watched path. Adding `.delete` and re-opening the path in the handler sees both. `.rename` fires when the WATCHED file is renamed away, not when another file is renamed OVER it — that is a `.delete` on the old inode. #fsevents
- [fact] The bug was latent for as long as Scarf was the only writer: every view model reloads explicitly after its own save, so nobody noticed the watch was dead. It became user-visible in Phase 5, when the bundled `scarf-projects` MCP server made a SECOND PROCESS a writer of `projects.json` — an agent registers a project and the sidebar never shows it. #projects
- [decision] `makeSource` now watches `[.write, .extend, .rename, .delete]` and calls `rearm(_:for:)`, which cancels the dead source and swaps a fresh one into whichever of `coreSources`/`projectSources` held it. A path that is genuinely gone re-opens as nil and simply drops out — same behaviour as a path that never existed, and no re-arm loop. This affects EVERY watched path (state.db, config.yaml, cron jobs, dashboards), not just the registry. #watcher
- [convention] `HermesFileWatcherAtomicReplaceTests` pins it by asserting the SECOND atomic replace still ticks `lastChangeDate`. Verified to FAIL with the `.delete` removed from the mask — a watcher test that passes both ways is worthless, so re-check that before trusting it. #testing
- [gotcha] The remote (SSH) half is unaffected: `startRemotePoller` stats mtime by PATH, which follows the replacement inode for free. Only the local FSEvents path had this failure mode. #remote

## Relations
- relates_to [[scarf-projects MCP server: bundled helper, ScarfCore services, no parallel writers]]
- relates_to [[Projects registry is salvage-decoded, quarantined, and empty-save-guarded]]


## R2: the two gaps the re-arm left open

t-1a1a9ce3.

- [gotcha] **The arming race.** Between `open(2)` and the source going live there is a window in which an atomic replace unlinks the inode we just opened — before anything is listening, so the `.delete` that drives the re-arm is never delivered and the watch is DEAD ON ARRIVAL, watching a file nobody will write again. `makeSource` now compares `stat(path)` against `fstat(fd)` after arming and re-arms on the new inode when they differ, bounded to three attempts (the alternative to a bound is a loop that spins for as long as a writer keeps replacing).
- [decision] **A core path deleted WITH A GAP is remembered, not abandoned.** `rearm` used to drop the source when `makeSource` returned nil, which is right for a project's uninstalled `.scarf` dir and wrong for `state.db` / `config.yaml` / `projects.json`: an `rm` plus a rewrite a second later (an agent, a restore from `.bak`, a git checkout) left the path unwatched for the rest of the process's life. Dropped core paths go into `unarmedCorePaths` and are retried on the coalesced tick.
- [gotcha] The tick is a FREE driver but only fires while some OTHER watch is alive — and the case that loses the only live watch is exactly the case where none is. So a bounded retry Timer (5s × 12 ≈ one minute) starts on a drop-out and stops the moment the path returns. Deliberately NOT seeded from `startWatching`: several core paths are legitimately absent on a normal machine (`mcp-tokens/`, `memories/MEMORY.md`, the session map), so seeding from there would leave the set permanently non-empty and reinstate — under another name — the unconditional 5s heartbeat this watcher removed on purpose. The steady state is a watcher with no timers.
- [gotcha] The `deletedPathDropsOut` test asserted NOTHING (delete, sleep, stop), so it passed identically whether the watcher dropped the path, span on a re-arm loop, or kept a dead source. It now pins both halves: the path drops out, and it comes back. The doc comment on the first-replace assertion was also wrong — it claimed that replace fired before the fix, when the old `[.write, .extend, .rename]` mask saw neither.


## PF: the watch set is now DIFFED, and what that costs the re-arm

t-45594d27.

- [decision] `updateProjectWatches` used to cancel and rebuild every project watch on each call, and its busiest caller is the coalesced tick — ~2N `open(2)`s per tick locally, and remotely a full SSH poller teardown + re-baseline. `projectSources` is now a `[path: source]` dictionary and the update touches only the difference; an identical set is a no-op. `rearm` looks the dead source up by value instead of by array index.
- [gotcha] **The rebuild was accidentally doing retry work.** A project path that did not exist when we tried to arm it (a fresh project's `.scarf/dashboard.json`) got a free retry on every tick purely because the whole set was rebuilt. The diff would never revisit it, so `unarmedProjectPaths` was added — same idea as `unarmedCorePaths`, retried on the coalesced tick but deliberately NOT on the retry Timer: project paths are legitimately absent forever (a project with no dashboard), so seeding the timer from them would reinstate the unconditional heartbeat this watcher removed on purpose. `rearm` feeds the same set when a project path vanishes with a gap.
- [convention] `ProjectsPFTickDecouplingTests` re-checks the atomic-replace property against the new keyed storage (two replaces of a watched `dashboard.json` must both tick), because a storage change is exactly the kind of thing that silently un-fixes this. It also pins the no-op (`projectArmCount` must not move for an unchanged set) — an assertion the old shape fails.
- [decision] The REMOTE half is no longer unaffected. `startRemotePoller` now hands `transport.watchPaths` a `WatchBaselineStore` the watcher owns, so a restart resumes from the previous stream's per-path signatures instead of silently re-baselining. A polling watcher is silent on its first poll by construction; with once-per-tick restarts that meant the remote watcher could go a whole streaming session without reporting a single delta. The signature is `mtime:size` per path, not one joined mtime blob.


## P2: the poller's blob fallback was eating the baselines it was meant to protect

t-7d05e066, from the P8 audit (DI H6/H7, PERF L4).

- [gotcha] **A fallback that REPLACES is not a fallback.** `SSHTransport.watchPaths` handled a reply it couldn't line up with the watched paths by storing the whole stdout under one `"\0blob"` key — via `WatchBaselineStore.apply`, which replaces the entire map. So one misaligned reply forgot every per-path signature; the next aligned reply then re-baselined those paths silently, and every change that landed in the gap was swallowed. Exactly the failure the caller-owned baseline was introduced to close, re-entered through the error path. #watcher
- [decision] `WatchBaselineStore` grew `merge(_:)` — fold in the keys you have, keep the ones you don't — and the blob path uses it. `apply` stays the authoritative form (a full poll legitimately knows about every path, so forgetting the rest is correct there, and it is what drops the stale blob key when alignment returns). #transport
- [gotcha] An empty poll reply `continue`d — PAST the 3s sleep at the bottom of the loop. A host answering with nothing (wedged sshd, a dropped ControlMaster) turned the watcher into a tight SSH spawn loop. Every iteration now reaches the sleep; the empty case simply reports nothing.
- [decision] `unarmedProjectPaths` retries on one tick in eight rather than every tick. A project with no dashboard has none forever, so the per-tick retry was one permanent `open(2)` per dashboard-less project for a file that will most likely never appear. The counter only ever DELAYS a retry — `updateProjectWatches` still arms a returning path immediately — which is what keeps this a backoff rather than a give-up.
