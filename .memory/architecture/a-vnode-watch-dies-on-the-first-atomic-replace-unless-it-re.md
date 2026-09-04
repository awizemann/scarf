---
title: A vnode watch dies on the first atomic replace unless it re-arms on .delete
type: note
permalink: scarf/architecture/a-vnode-watch-dies-on-the-first-atomic-replace-unless-it-re
tags: [watcher, fsevents, projects, phase-5, gotcha]
source_paths: [scarf/scarf/Core/Services/HermesFileWatcher.swift, scarf/scarfTests/HermesFileWatcherAtomicReplaceTests.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/LocalTransport.swift]
source_paths_inferred: false
source_sha: d21211a80383f52362a245594865a321c60dc058
created: 2026-09-03
updated: 2026-09-03
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
