---
title: Never run synchronous transport I/O on the MainActor from a file-watcher tick or view body
type: note
permalink: scarf/conventions/never-run-synchronous-transport-i/o-on-the-mainactor-from-a-file-watcher-tick-or-view-body
created: 2026-06-21
updated: 2026-09-04
---

## Observations
- [gotcha] On a REMOTE (SSH) context, these all do SYNCHRONOUS scp/SSH round-trips: `HermesFileService.readFile/loadConfig/loadGatewayState`, `ServerContext.runHermes/readText/readData`, `HermesEnvService.load()`. Calling any of them on the MainActor from a HOT/REPEATED path — a `.onChange(of: fileWatcher.lastChangeDate)` handler (fires per persisted message during an ACP stream) or a view `body`/computed property — stalls the main thread → typing lag / UI jank. This was the gh#102 *typing-lag* follow-up (distinct from the original gh#102 Dashboard FSEvent close/reopen fix, v2.10.3). #gotcha #perf #remote
- [pattern] Fix: do the read off-main (`Task.detached`, or mark the reader `nonisolated`) and commit `@Observable` state back on the MainActor. For watcher-driven loads ALSO add cancel-prior + a recency guard: store the `Task`, `cancel()` the prior on each tick, `if Task.isCancelled { return }` before committing, and advance any freshness/change token ONLY on a committed read. The synchronous loads these replace couldn't interleave, so a naive async port introduces out-of-order-completion stale-clobber (a fresh-eyes audit caught exactly this). Mirrors `ChatViewModel.loadRecentSessions` (inFlightSessionLoad coalescing) + `HealthViewModel` (t-aud11) + `PlatformsViewModel.load`. #pattern
- [render-hot] Worst variant = synchronous remote reads in a view `body`/computed (e.g. `PlatformsViewModel.connectivity` → `hasConfigBlock` read config.yaml + .env per platform per render). Fix = compute once off-main in `load()`, cache the result (e.g. `configuredPlatforms: Set<String>`), body reads the cache. NOTE `context.readText` is NOT cached — it's `makeTransport().fileExists` + `readFile` (two live round-trips) every call. #render
- [sweep] 2026-06-21 sweep of every app `.onChange(fileWatcher.lastChangeDate)` handler: Gateway/Cron/Memory/CredentialPools/Sessions/Activity/Insights/Dashboard/RichChat were already off-main/debounced; Chat/Platforms/Projects were not — fixed on branch `fix/remote-sync-io-on-main`. When adding a watcher-driven load, follow the off-main + cancel-prior pattern.

## Relations
- relates_to [[Scarf Architecture Rules]]
- relates_to [[Hermes Integration]]
- relates_to [[macOS must mirror iOS scene-phase pause and resume for background work]]



## Audit-found refinements (2026-06-21)
- [sweep-gotcha] Checking "is load() async?" is NOT enough: SessionsViewModel.load() was async but called a synchronous computeStats() that did a stat() on main. The first sweep cleared it; a second audit caught it. Trace INTO the async load body for nested synchronous transport calls (stat/readText/readFile/runHermes), not just the method signature. So Sessions belongs in the "was NOT off-main" set alongside Chat/Platforms/Projects.
- [recency-pattern] Across MULTIPLE suspension points, Task.isCancelled only orders the FIRST commit. If a load writes observable state both before AND after a later await (e.g. registry then dashboard), use a monotonic generation token: gen += 1 at start, capture it, and guard gen == currentGen before EACH commit. isCancelled cannot order a write that sits behind a second suspension. See ProjectsViewModel.reload/reloadDashboard.


## PF (2026-09-04): the MUTATORS finally moved too — the P2 deferral is closed

t-45594d27.

- [sweep] The 2026-06-21 sweep covered the watcher-driven LOADS and deliberately left the user-initiated MUTATORS alone as one-shot paths. That deferral is now closed: `ProjectsViewModel.addProject / removeProject / renameProject / moveProject / archiveProject / unarchiveProject` (and `registryForMutation`, `mutateEntry`, `propagateRenameToRecord`, `cleanUpAfterRemoval`) are `async` and do their transport work in `Task.detached`. A mutation was 3-5 blocking SSH round-trips on the main actor, and since `RegistryWriteLock` landed it could also sit on a 2s lock wait on top of them. Charter C10.
- [sweep] `selectProject` was 2 blocking round-trips per SIDEBAR CLICK (`dashboardExists` + `loadDashboard`) before the selection could paint. It now touches no transport at all: `ProjectsViewModel.dashboard`/`dashboardError` are GONE (the cockpit view model owns loading and rendering the dashboard), replaced by `selectedHasDashboard`, a single off-main `stat` that exists only so the sidebar can pick a glyph.
- [gotcha] Async mutators break an invariant the sync ones had for free: **a shared baseline slot on the view model is no longer safe**, because two mutators can now interleave across their reads and the second one's baseline becomes the thing the first one writes against. `registryForMutation` returns the registry and its fingerprint together as a value (`LoadedForMutation`). The same reasoning applies to any per-mutation state you are tempted to park on the instance.
- [gotcha] Detaching a post-commit side effect changes its ORDERING, not just its thread. Making `cleanUpAfterRemoval` fire-and-forget broke `removalRevokesGrantsAndStripsTheAgentsBlock` — `removeProject` returning true has always meant the removal is complete, and callers read the grant store straight after. Detach it, but AWAIT it.

- [gotcha] With SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (the app target's setting), an off-main service type must opt out at the TYPE level (nonisolated struct, SE-0449) — marking only the work method nonisolated leaves init AND its default arguments main-actor-isolated (defaults evaluate in the caller's context), which breaks exactly the Task.detached C10 call sites the nonisolated was added for. Nested types need their own opt-out. And Release surfaces isolation errors Debug hides (laxer diagnostic level), so a green Debug build is not evidence of isolation correctness — t-bb02177b, ProjectsMCPRegistrar vs scarfApp.swift:151. #concurrency



## F1 (2026-09-04): the sweep has to include CONSENT SHEETS, not just view models

t-0a9ff9e3. Both remaining holds were in a SwiftUI view rather than a view
model, which is why two sweeps of the view models missed them.

- [sweep] `MiniAppLaunchView`: the permission sheet's `save()` ran
  synchronously in the button action → `MiniAppGrantStore.mutate` →
  `RegistryWriteLock` (up to a 60s remote wait, with `Thread.sleep`) plus a
  guarded SSH read-modify-write — beachballing the window on the one press
  a user makes at a security prompt. Now `Task.detached`-and-await
  (`ProjectsViewModel.save` shape), with Approve disabled + a progress
  spinner while in flight and the failure SURFACED in the sheet rather than
  only logged: since G2 the store legitimately refuses the write, and
  silently running afterwards told the user their decision had stuck.
- [sweep] Same file's `.task`: three blocking transport reads (`hasDecision`
  ×2 + `grantedPermissions`) on the MainActor just to decide WHICH sheet to
  show — worse on a cold start that quarantines a corrupt grants file. One
  detached hop now answers all three together.
- [gotcha] A view is not exempt from the recency rule. `.task(id:)`
  cancellation does not stop a suspended `await` resuming, and a detached
  child doesn't inherit cancellation at all, so an off-main port inside a
  view needs the same `guard !Task.isCancelled` before it commits — here, a
  switch to another mini-app could otherwise be followed by the PREVIOUS
  one's read driving the view into `.run` with the wrong grant set.
- [convention] When auditing for C10 holds, grep the VIEWS for
  store/service constructions inside button actions and `.task` blocks, not
  only the view models. A consent surface is the worst place to block: it
  is modal-feeling, user-initiated, and the one interaction the user cannot
  skip.
