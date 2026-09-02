import Foundation
import Observation

@Observable
public final class LogsViewModel {
    public let context: ServerContext
    private let logService: HermesLogService

    public init(context: ServerContext = .local) {
        self.context = context
        self.logService = HermesLogService(context: context)
    }

    public var entries: [LogEntry] = [] { didSet { recomputeFilteredEntries() } }

    /// Hard ceiling on retained entries. The 2-second tail poll appended
    /// forever: a Logs tab left open on a chatty host grew `entries` without
    /// bound until the app was quit. Oldest entries are dropped first.
    public static let maxRetainedEntries = 5_000

    /// True once the retention cap has actually dropped anything. A cap that
    /// degrades silently is indistinguishable from a quiet log, so the view
    /// renders a banner off this rather than the user wondering where the
    /// start of the file went.
    public private(set) var didDropOldEntries = false
    /// True during initial load + log-file switch so the view can show a
    /// `.loadingOverlay` (the 2s tail poll does NOT toggle this). (t-aud07)
    public var isLoading = false
    public var selectedLogFile: LogFile = .agent
    public var filterLevel: LogEntry.LogLevel? { didSet { recomputeFilteredEntries() } }
    public var selectedComponent: LogComponent = .all { didSet { recomputeFilteredEntries() } }
    public var searchText = "" { didSet { recomputeFilteredEntries() } }
    private var pollTimer: Timer?

    public enum LogFile: String, CaseIterable, Identifiable {
        case agent = "agent.log"
        case errors = "errors.log"
        case gateway = "gateway.log"

        public var id: String { rawValue }

        #if canImport(Darwin)
        public var displayName: LocalizedStringResource {
            switch self {
            case .agent: return "Agent"
            case .errors: return "Errors"
            case .gateway: return "Messaging Gateway"
            }
        }
        #endif
    }

    private func path(for file: LogFile) -> String {
        switch file {
        case .agent: return context.paths.agentLog
        case .errors: return context.paths.errorsLog
        case .gateway: return context.paths.gatewayLog
        }
    }

    public enum LogComponent: String, CaseIterable, Identifiable {
        case all = "All"
        case gateway = "Gateway"
        case agent = "Agent"
        case tools = "Tools"
        case cli = "CLI"
        case cron = "Cron"

        public var id: String { rawValue }

        #if canImport(Darwin)
        public var displayName: LocalizedStringResource {
            switch self {
            case .all: return "All"
            case .gateway: return "Messaging Gateway"
            case .agent: return "Agent"
            case .tools: return "Tools"
            case .cli: return "CLI"
            case .cron: return "Cron"
            }
        }
        #endif

        public var loggerPrefix: String? {
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

    /// MEMOIZED, not computed. As a computed property this ran a full filter
    /// — including a `localizedCaseInsensitiveContains` per entry, which is
    /// an ICU collation call, not a byte compare — over up to 5,000 entries
    /// on EVERY SwiftUI body evaluation, while a 2-second poll kept
    /// invalidating that body. Its four inputs (`entries`, `filterLevel`,
    /// `selectedComponent`, `searchText`) each recompute it on `didSet`.
    public private(set) var filteredEntries: [LogEntry] = []

    private func recomputeFilteredEntries() {
        let level = filterLevel
        let search = searchText
        let prefix = selectedComponent.loggerPrefix
        filteredEntries = entries.filter { entry in
            let levelOk = level == nil || entry.level == level
            let searchOk = search.isEmpty || entry.raw.localizedCaseInsensitiveContains(search)
            let componentOk = prefix.map { entry.logger.hasPrefix($0) } ?? true
            return levelOk && searchOk && componentOk
        }
    }

    /// Test seam for `appendBounded` — the retention cap is the contract,
    /// and it is only reachable through the poll timer in production.
    func appendBoundedForTesting(_ newEntries: [LogEntry]) { appendBounded(newEntries) }

    /// Append new tail lines, enforcing `maxRetainedEntries`.
    private func appendBounded(_ newEntries: [LogEntry]) {
        guard !newEntries.isEmpty else { return }
        var combined = entries + newEntries
        if combined.count > Self.maxRetainedEntries {
            combined.removeFirst(combined.count - Self.maxRetainedEntries)
            didDropOldEntries = true
        }
        entries = combined
    }

    public func load() async {
        isLoading = true
        didDropOldEntries = false
        await logService.openLog(path: path(for: selectedLogFile))
        entries = await logService.readLastLines(count: 500)
        await logService.seekToEnd()
        startPolling()
        isLoading = false
    }

    public func switchLogFile(_ file: LogFile) async {
        isLoading = true
        selectedLogFile = file
        entries = []
        didDropOldEntries = false
        await logService.openLog(path: path(for: file))
        entries = await logService.readLastLines(count: 500)
        await logService.seekToEnd()
        isLoading = false
    }

    public func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.appendBounded(await self.logService.readNewLines())
            }
        }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    public func cleanup() async {
        stopPolling()
        await logService.closeLog()
    }
}
