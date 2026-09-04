import Foundation
import ScarfCore

@Observable
final class HermesFileWatcher {
    private(set) var lastChangeDate = Date()
    private var coreSources: [DispatchSourceFileSystemObject] = []
    private var projectSources: [DispatchSourceFileSystemObject] = []
    /// Core paths with no live source: either absent when `startWatching`
    /// ran, or deleted with a gap before anything re-created them.
    ///
    /// Core paths are not optional the way a project's `.scarf` dir is — a
    /// `projects.json` that is deleted and written fresh a second later (an
    /// agent's `rm` plus a rewrite, a restore from `.bak`, a git checkout)
    /// left `state.db`, `config.yaml` or the registry unwatched for the rest
    /// of the process's life, and nothing but a window reopen brought them
    /// back. Retried on the coalesced tick — the other core paths tick
    /// constantly on a live host, and this costs one `open(2)` per still-
    /// missing path per burst, only while the set is non-empty.
    private var unarmedCorePaths: Set<String> = []
    /// Test seam: how many core paths are currently unwatched.
    var unarmedCorePathCount: Int { unarmedCorePaths.count }
    private var timer: Timer?
    /// Remote polling task. Non-nil only when `context.isRemote`. Cancelled
    /// on `stopWatching()`.
    private var remotePollTask: Task<Void, Never>?
    /// Project directory paths fed to the SSH poller alongside `watchedCorePaths`.
    /// Updated by `updateProjectWatches` so the remote stream restarts whenever
    /// the project list changes.
    private var remoteProjectPaths: [String] = []

    /// Coalescing timer for `lastChangeDate` ticks. v0.13 Hermes writes to
    /// `state.db-wal` and rotating logs at ~10 Hz during gateway activity;
    /// every observing view (`DashboardView`, `ProjectsView`,
    /// `ProjectSessionsView`, half a dozen widgets) re-fires its `.onChange`
    /// or `.task(id:)` on every tick, which stacked concurrent dashboard
    /// loads on v0.13 hosts and tripped sqlite contention on the read-only
    /// state.db handle. We coalesce to at most one tick per
    /// `coalesceWindow` so a burst of FSEvents collapses into one observable
    /// state mutation.
    ///
    /// **Two limits, not one.** A pure trailing-debounce would starve under
    /// sustained WAL writes — the timer would keep getting cancelled and
    /// rescheduled, and a coincident `gateway_state.json` Start/Stop touch
    /// would never propagate until WAL activity quieted down. So we publish
    /// when EITHER (a) `coalesceWindow` of quiet has elapsed since the last
    /// fire, OR (b) `maxWait` has elapsed since the first fire of the
    /// current burst — whichever comes first. The max-wait guarantees a
    /// floor of one observable mutation per `maxWait` even during sustained
    /// activity. Numbers picked to keep the dashboard responsive on a
    /// single `touch` while surviving v0.13's WAL-write storm.
    private var pendingCoalesceTimer: DispatchWorkItem?
    private var pendingTickDate: Date?
    /// Wall-clock when the current burst began. Set on the first
    /// `scheduleCoalescedTick` fire after a quiet window; cleared whenever
    /// the timer fires. Drives the `maxWait` floor below.
    private var burstStartDate: Date?
    private static let coalesceWindow: TimeInterval = 0.5
    private static let maxWait: TimeInterval = 1.5

    let context: ServerContext
    private let transport: any ServerTransport

    nonisolated init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    /// Canonical list of paths we observe. Used for both FSEvents (local)
    /// and mtime polling (remote).
    private var watchedCorePaths: [String] {
        let paths = context.paths
        return [
            paths.stateDB,
            paths.stateDB + "-wal",
            paths.configYAML,
            paths.home + "/.env",
            paths.memoryMD,
            paths.userMD,
            paths.cronJobsJSON,
            paths.gatewayStateJSON,
            paths.agentLog,
            paths.errorsLog,
            paths.gatewayLog,
            paths.projectsRegistry,
            // v2.3: sidecar attributing Hermes session IDs to Scarf project
            // paths. Written by SessionAttributionService when a chat
            // starts with a project context; read by
            // ProjectSessionsViewModel to filter the session list. Without
            // watching this file, the per-project Sessions tab would only
            // pick up new sessions when the user re-entered the tab
            // (triggering .task(id:) re-fire) — switching directly back
            // to the project's Sessions tab after a chat left the tab
            // stale.
            paths.sessionProjectMap,
            paths.mcpTokensDir
        ]
    }

    func startWatching() {
        if context.isRemote {
            startRemotePoller()
            return
        }

        for path in watchedCorePaths {
            if let source = makeSource(for: path) {
                coreSources.append(source)
            }
            // A path that isn't there YET is not a drop-out and is
            // deliberately NOT remembered. Several core paths are legitimately
            // absent on a normal machine (`mcp-tokens/`, `memories/MEMORY.md`,
            // the session map), so seeding the retry set from here would leave
            // it permanently non-empty — reinstating, under another name, the
            // unconditional heartbeat this watcher removed on purpose. The
            // next `startWatching` picks them up; `rearm` handles the case
            // that actually loses a live watch.
        }
        // No heartbeat timer: every observing view runs its `.onChange`
        // refresh whenever `lastChangeDate` ticks, so a 5s unconditional
        // tick was triggering wasted reloads across many subscribers
        // (Dashboard, Memory, Cron, Gateway, Platforms, Projects, Chat).
        // FSEvents reliably fires on real changes; menu-bar Start/Stop
        // touches `gateway_state.json` which the watcher catches.
    }

    /// (Re)start the SSH polling stream over the union of `watchedCorePaths`
    /// and the current `remoteProjectPaths`. Called on initial start and
    /// whenever `updateProjectWatches` changes the project set.
    ///
    /// ScarfMon — `mac.fileWatcher.remoteRestart` (event) fires once per
    /// poller restart with `bytes` carrying the path count. Frequent
    /// restarts mean the project-list update path is churning; pair
    /// with `mac.fileWatcher.remoteTick` from the upstream transport
    /// (`ssh.streamScript` / `transport.watchPaths`) to see actual
    /// poll cadence.
    private func startRemotePoller() {
        remotePollTask?.cancel()
        let pathSet = watchedCorePaths + remoteProjectPaths
        ScarfMon.event(.transport, "mac.fileWatcher.remoteRestart", count: 1, bytes: pathSet.count)
        let stream = transport.watchPaths(pathSet)
        remotePollTask = Task { [weak self] in
            for await _ in stream {
                ScarfMon.event(.transport, "mac.fileWatcher.remoteDelta", count: 1)
                await MainActor.run { [weak self] in
                    self?.scheduleCoalescedTick()
                }
            }
        }
    }

    /// Coalesce a burst of FSEvents (or remote-poll deltas) into a single
    /// `lastChangeDate` mutation. Two limits decide when the publish fires,
    /// whichever comes first:
    ///
    /// 1. **Quiet window**: `coalesceWindow` seconds have elapsed since the
    ///    last fire. Each new fire pushes this out — pure debounce shape.
    /// 2. **Max wait**: `maxWait` seconds have elapsed since the FIRST fire
    ///    of the current burst. This bounds the latency floor under
    ///    sustained activity (v0.13's ~10 Hz WAL-write storm) so a
    ///    coincident `gateway_state.json` Start/Stop touch can't be starved
    ///    indefinitely behind a continuously-rescheduling debounce timer.
    ///
    /// Runs on `.main` (the FSEvents queue and the remote-poll
    /// MainActor.run) so observers see the publish on MainActor without a
    /// hop. The work item self-clears `burstStartDate` when it fires so the
    /// next burst starts a fresh max-wait window.
    private func scheduleCoalescedTick() {
        let now = Date()
        pendingTickDate = now
        if burstStartDate == nil {
            burstStartDate = now
        }
        pendingCoalesceTimer?.cancel()
        // Pick the deadline as the earlier of (a) `coalesceWindow` from now,
        // and (b) `maxWait` from the burst start. The latter only matters
        // when fires keep arriving faster than `coalesceWindow`; in the
        // single-fire / quiet-burst case both reduce to the same value.
        let quietDeadline = now.addingTimeInterval(Self.coalesceWindow)
        let maxWaitDeadline = (burstStartDate ?? now).addingTimeInterval(Self.maxWait)
        let firingDate = min(quietDeadline, maxWaitDeadline)
        let delay = max(0, firingDate.timeIntervalSince(now))
        let work = DispatchWorkItem { [weak self] in
            guard let self, let date = self.pendingTickDate else { return }
            self.pendingTickDate = nil
            self.burstStartDate = nil
            self.reestablishUnarmedCoreWatches()
            self.lastChangeDate = date
        }
        pendingCoalesceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Re-open any core path that has come back since it dropped out.
    /// Cheap and self-limiting: one `open(2)` per still-missing path, and
    /// the set empties as they succeed.
    private func reestablishUnarmedCoreWatches() {
        guard !unarmedCorePaths.isEmpty, !context.isRemote else {
            stopRetryTimer()
            return
        }
        for path in unarmedCorePaths {
            guard let source = makeSource(for: path) else { continue }
            coreSources.append(source)
            unarmedCorePaths.remove(path)
        }
        if unarmedCorePaths.isEmpty { stopRetryTimer() } else { startRetryTimer() }
    }

    /// Drives `reestablishUnarmedCoreWatches` when nothing else can.
    ///
    /// The coalesced tick is the free driver, but it only fires when some
    /// OTHER watch is alive — and a home where the deleted file was the only
    /// thing being written is exactly the case where none is. So: a bounded
    /// burst of retries after a drop-out, not a heartbeat. It stops the
    /// moment the path comes back, and stops anyway after
    /// `maxRetries` × 5s ≈ a minute, after which the coalesced tick is the
    /// only (free) retry. The steady state is a watcher with no timers, which
    /// is the property the removed 5s heartbeat cost us.
    private static let retryInterval: TimeInterval = 5
    private static let maxRetries = 12
    private var retriesLeft = 0

    private func startRetryTimer() {
        retriesLeft = Self.maxRetries
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.retryInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.retriesLeft -= 1
                self.reestablishUnarmedCoreWatches()
                if self.retriesLeft <= 0 { self.stopRetryTimer() }
            }
        }
    }

    private func stopRetryTimer() {
        timer?.invalidate()
        timer = nil
        retriesLeft = 0
    }

    func stopWatching() {
        for source in coreSources + projectSources {
            source.cancel()
        }
        coreSources.removeAll()
        projectSources.removeAll()
        unarmedCorePaths.removeAll()
        timer?.invalidate()
        timer = nil
        remotePollTask?.cancel()
        remotePollTask = nil
        pendingCoalesceTimer?.cancel()
        pendingCoalesceTimer = nil
        pendingTickDate = nil
        burstStartDate = nil
    }

    /// Watch each project's `dashboard.json` AND its enclosing `.scarf/`
    /// directory. Watching both is what lets file-reading widgets
    /// (markdown_file, log_tail, image) refresh when a cron job rewrites
    /// a sidecar file: dir-level FSEvents fire on add/remove/rename inside
    /// `.scarf/`, file-level FSEvents fire on dashboard.json content
    /// changes. In-place writes to an existing sidecar file (e.g., `>>` log
    /// append) are NOT detected — by convention the cron job should write
    /// atomically (write-then-rename) or `touch dashboard.json` after each
    /// run.
    func updateProjectWatches(dashboardPaths: [String], scarfDirs: [String]) {
        if context.isRemote {
            // Restart the SSH poller with the union of core + project dir
            // paths. `stat -c %Y` on a directory tracks mtime, which ticks
            // on add/remove/rename inside the dir — same coverage as the
            // local FSEvents directory watch below.
            let union = Array(Set(dashboardPaths + scarfDirs))
            remoteProjectPaths = union.sorted()
            startRemotePoller()
            return
        }
        for source in projectSources {
            source.cancel()
        }
        projectSources.removeAll()
        for path in dashboardPaths {
            if let source = makeSource(for: path) {
                projectSources.append(source)
            }
        }
        for dir in scarfDirs {
            if let source = makeSource(for: dir) {
                projectSources.append(source)
            }
        }
    }

    /// Watch one path, surviving the atomic replaces that are how almost
    /// everything here is written.
    ///
    /// A vnode source watches an INODE, not a name. `transport.writeFile`
    /// is `Data.write(.atomic)` — temp file plus `rename(2)` over the
    /// destination — so the watched inode is never modified; it is
    /// unlinked, which delivers `.delete` and NOT `.write`. With a
    /// `[.write, .extend, .rename]` mask the first atomic replace killed
    /// the watch silently and every later change was invisible for the
    /// rest of the process's life. Measured: that mask sees 0 events for
    /// 2 atomic writes; `.delete` plus a re-arm sees 2.
    ///
    /// This was survivable while Scarf was the only writer — each view
    /// model reloads after its own save. It stopped being survivable when
    /// the bundled `scarf-projects` MCP server became a SECOND PROCESS
    /// writing `projects.json`: without the re-arm, an agent registers a
    /// project and the sidebar simply never shows it.
    private func makeSource(for path: String) -> DispatchSourceFileSystemObject? {
        // Bounded retries for the arm-time race below. Three is generous: it
        // takes a replace landing inside a few microseconds of our `open`,
        // three times running, and the alternative to a bound is a loop that
        // spins for as long as a writer keeps replacing the file.
        for _ in 0..<3 {
            guard let source = armSource(for: path) else { return nil }
            // The window between `open(2)` and `resume()`: an atomic replace
            // that lands in it unlinks the inode we just opened BEFORE the
            // source is listening, so the `.delete` that drives the re-arm is
            // never delivered and the watch is dead on arrival — watching a
            // file nobody will ever write again. Compare what the NAME points
            // at now with what we opened; if they differ, the replace already
            // happened and we simply arm again on the new inode.
            var onDisk = stat()
            var opened = stat()
            let named = stat(path, &onDisk) == 0
            let armed = fstat(source.handle, &opened) == 0
            if !named || !armed { return source }
            if onDisk.st_dev == opened.st_dev && onDisk.st_ino == opened.st_ino {
                return source
            }
            source.cancel()
        }
        return armSource(for: path)
    }

    private func armSource(for path: String) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // ScarfMon — fires every time FSEvents detects a change on
            // a watched core or project path. High counts during
            // streaming chats are normal (state.db-wal ticks per
            // message persisted); high counts when nothing's happening
            // suggest a runaway watcher install.
            ScarfMon.event(.transport, "mac.fileWatcher.localFire", count: 1)
            self?.scheduleCoalescedTick()
            // The name we were asked to watch now points at a different
            // inode (or none). Re-open it so the NEXT change is seen too.
            let vanished = source.data.contains(.delete) || source.data.contains(.rename)
            if vanished {
                self?.rearm(source, for: path)
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return source
    }

    /// Replace a dead source with one watching the new inode at `path`,
    /// in whichever list held it.
    ///
    /// A path that is genuinely gone (an uninstalled project's `.scarf`
    /// dir) simply drops out: `makeSource` returns nil and the old source
    /// is not replaced, which is exactly the pre-existing behaviour for a
    /// path that never existed. The next `updateProjectWatches` /
    /// `startWatching` re-establishes it if it comes back.
    private func rearm(_ dead: DispatchSourceFileSystemObject, for path: String) {
        dead.cancel()
        let replacement = makeSource(for: path)
        if let index = coreSources.firstIndex(where: { $0 === dead }) {
            if let replacement {
                coreSources[index] = replacement
            } else {
                coreSources.remove(at: index)
                // Remembered, not abandoned: a core path that comes back
                // gets its watch back on the next tick (or the retry timer,
                // when nothing is left alive to tick).
                unarmedCorePaths.insert(path)
                startRetryTimer()
            }
            return
        }
        if let index = projectSources.firstIndex(where: { $0 === dead }) {
            if let replacement {
                projectSources[index] = replacement
            } else {
                projectSources.remove(at: index)
            }
        }
    }

    deinit {
        stopWatching()
    }
}
