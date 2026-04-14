import Foundation

@Observable
final class LogsViewModel {
    private let logService = HermesLogService()

    var entries: [LogEntry] = []
    var selectedLogFile: LogFile = .agent
    var filterLevel: LogEntry.LogLevel?
    var selectedComponent: LogComponent = .all
    var searchText = ""
    private var pollTimer: Timer?

    enum LogFile: String, CaseIterable, Identifiable {
        case agent = "agent.log"
        case errors = "errors.log"
        case gateway = "gateway.log"

        var id: String { rawValue }

        var path: String {
            switch self {
            case .agent: return HermesPaths.agentLog
            case .errors: return HermesPaths.errorsLog
            case .gateway: return HermesPaths.gatewayLog
            }
        }
    }

    enum LogComponent: String, CaseIterable, Identifiable {
        case all = "All"
        case gateway = "Gateway"
        case agent = "Agent"
        case tools = "Tools"
        case cli = "CLI"
        case cron = "Cron"

        var id: String { rawValue }

        var loggerPrefix: String? {
            switch self {
            case .all: return nil
            case .gateway: return "gateway"
            case .agent: return "agent"
            case .tools: return "tools"
            case .cli: return "cli"
            case .cron: return "cron"
            }
        }
    }

    var filteredEntries: [LogEntry] {
        entries.filter { entry in
            let levelOk = filterLevel == nil || entry.level == filterLevel
            let searchOk = searchText.isEmpty || entry.raw.localizedCaseInsensitiveContains(searchText)
            let componentOk: Bool = {
                guard let prefix = selectedComponent.loggerPrefix else { return true }
                return entry.logger.hasPrefix(prefix)
            }()
            return levelOk && searchOk && componentOk
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
