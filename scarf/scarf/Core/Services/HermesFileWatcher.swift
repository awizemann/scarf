import Foundation

@Observable
final class HermesFileWatcher {
    private(set) var lastChangeDate = Date()
    private var coreSources: [DispatchSourceFileSystemObject] = []
    private var projectSources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    /// Remote polling task. Non-nil only when `context.isRemote`. Cancelled
    /// on `stopWatching()`.
    private var remotePollTask: Task<Void, Never>?

    let context: ServerContext
    private let transport: any ServerTransport

    init(context: ServerContext = .local) {
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
            paths.mcpTokensDir
        ]
    }

    func startWatching() {
        if context.isRemote {
            // FSEvents doesn't reach across SSH. Drive lastChangeDate off
            // the transport's AsyncStream, which polls stat mtime on a
            // shared ControlMaster channel (~5ms per tick).
            let stream = transport.watchPaths(watchedCorePaths)
            remotePollTask = Task { [weak self] in
                for await _ in stream {
                    await MainActor.run { [weak self] in
                        self?.lastChangeDate = Date()
                    }
                }
            }
            return
        }

        for path in watchedCorePaths {
            if let source = makeSource(for: path) {
                coreSources.append(source)
            }
        }
        // No heartbeat timer: every observing view runs its `.onChange`
        // refresh whenever `lastChangeDate` ticks, so a 5s unconditional
        // tick was triggering wasted reloads across many subscribers
        // (Dashboard, Memory, Cron, Gateway, Platforms, Projects, Chat).
        // FSEvents reliably fires on real changes; menu-bar Start/Stop
        // touches `gateway_state.json` which the watcher catches.
    }

    func stopWatching() {
        for source in coreSources + projectSources {
            source.cancel()
        }
        coreSources.removeAll()
        projectSources.removeAll()
        timer?.invalidate()
        timer = nil
        remotePollTask?.cancel()
        remotePollTask = nil
    }

    func updateProjectWatches(_ dashboardPaths: [String]) {
        // Remote contexts don't support per-project FSEvents watches today —
        // the shared mtime poll covers the core set. Adding per-project
        // polling is a Phase 4 polish item.
        guard !context.isRemote else { return }
        for source in projectSources {
            source.cancel()
        }
        projectSources.removeAll()
        for path in dashboardPaths {
            if let source = makeSource(for: path) {
                projectSources.append(source)
            }
        }
    }

    private func makeSource(for path: String) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.lastChangeDate = Date()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return source
    }

    deinit {
        stopWatching()
    }
}
