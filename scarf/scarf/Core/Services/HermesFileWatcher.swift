import Foundation

@Observable
final class HermesFileWatcher {
    private(set) var lastChangeDate = Date()
    private var coreSources: [DispatchSourceFileSystemObject] = []
    private var projectSources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?

    func startWatching() {
        let paths = [
            HermesPaths.stateDB,
            HermesPaths.stateDB + "-wal",
            HermesPaths.configYAML,
            HermesPaths.memoryMD,
            HermesPaths.userMD,
            HermesPaths.cronJobsJSON,
            HermesPaths.gatewayStateJSON,
            HermesPaths.errorsLog,
            HermesPaths.gatewayLog,
            HermesPaths.projectsRegistry
        ]

        for path in paths {
            if let source = makeSource(for: path) {
                coreSources.append(source)
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.lastChangeDate = Date()
        }
    }

    func stopWatching() {
        for source in coreSources + projectSources {
            source.cancel()
        }
        coreSources.removeAll()
        projectSources.removeAll()
        timer?.invalidate()
        timer = nil
    }

    func updateProjectWatches(_ dashboardPaths: [String]) {
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
