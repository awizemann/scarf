import Foundation

@Observable
final class HermesFileWatcher {
    private(set) var lastChangeDate = Date()
    private var sources: [DispatchSourceFileSystemObject] = []
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
            HermesPaths.gatewayLog
        ]

        for path in paths {
            watchFile(path)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.lastChangeDate = Date()
        }
    }

    func stopWatching() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func watchFile(_ path: String) {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }

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
        sources.append(source)
    }

    deinit {
        stopWatching()
    }
}
