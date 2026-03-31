import Foundation

@Observable
final class LogsViewModel {
    private let logService = HermesLogService()

    var entries: [LogEntry] = []
    var selectedLogFile: LogFile = .errors
    var filterLevel: LogEntry.LogLevel?
    var searchText = ""
    private var pollTimer: Timer?

    enum LogFile: String, CaseIterable, Identifiable {
        case errors = "errors.log"
        case gateway = "gateway.log"

        var id: String { rawValue }

        var path: String {
            switch self {
            case .errors: return HermesPaths.errorsLog
            case .gateway: return HermesPaths.gatewayLog
            }
        }
    }

    var filteredEntries: [LogEntry] {
        entries.filter { entry in
            let levelOk = filterLevel == nil || entry.level == filterLevel
            let searchOk = searchText.isEmpty || entry.raw.localizedCaseInsensitiveContains(searchText)
            return levelOk && searchOk
        }
    }

    func load() async {
        await logService.openLog(path: selectedLogFile.path)
        entries = await logService.readLastLines(count: 500)
        await logService.seekToEnd()
        startPolling()
    }

    func switchLogFile(_ file: LogFile) async {
        selectedLogFile = file
        entries = []
        await logService.openLog(path: file.path)
        entries = await logService.readLastLines(count: 500)
        await logService.seekToEnd()
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let newEntries = await self.logService.readNewLines()
                if !newEntries.isEmpty {
                    self.entries.append(contentsOf: newEntries)
                }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func cleanup() async {
        stopPolling()
        await logService.closeLog()
    }
}
