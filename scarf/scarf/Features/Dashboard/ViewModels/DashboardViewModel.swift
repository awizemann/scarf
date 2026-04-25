import Foundation
import ScarfCore

@Observable
final class DashboardViewModel {
    let context: ServerContext
    private let dataService: HermesDataService
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
        self.fileService = HermesFileService(context: context)
    }


    var stats = HermesDataService.SessionStats.empty
    var recentSessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]
    /// Last few tool calls across all sessions, flattened to
    /// `ActivityEntry` rows for the Dashboard's "Recent activity" card.
    /// Same data source as ActivityView, just a smaller slice.
    var recentActivity: [ActivityEntry] = []
    var config = HermesConfig.empty
    var gatewayState: GatewayState?
    var hermesRunning = false
    var isLoading = true

    /// User-presentable error banner. Set when any of the remote reads
    /// (state.db snapshot, config.yaml, gateway_state.json, pgrep) failed
    /// in a way that's not just "file doesn't exist yet". Dashboard renders
    /// this above the stats with a "Run Diagnostics…" button. `nil` = no
    /// surfaceable error.
    var lastReadError: String?

    func load() async {
        isLoading = true
        // refresh() = close + reopen, forces a fresh remote snapshot. Cheap
        // on local (live DB reopen).
        let opened = await dataService.refresh()
        var collectedErrors: [String] = []
        if opened {
            stats = await dataService.fetchStats()
            recentSessions = await dataService.fetchSessions(limit: 5)
            sessionPreviews = await dataService.fetchSessionPreviews(limit: 5)
            let activityMessages = await dataService.fetchRecentToolCalls(limit: 8)
            recentActivity = activityMessages.flatMap { msg in
                msg.toolCalls.map { call in
                    ActivityEntry(
                        id: call.callId,
                        sessionId: msg.sessionId,
                        toolName: call.functionName,
                        kind: call.toolKind,
                        summary: call.argumentsSummary,
                        arguments: call.arguments,
                        messageContent: msg.content,
                        timestamp: msg.timestamp
                    )
                }
            }
            .prefix(6)
            .map { $0 }
            await dataService.close()
        } else if let msg = await dataService.lastOpenError {
            collectedErrors.append(msg)
        }
        // The fileService methods are synchronous and route through the
        // transport. For remote contexts each call is a blocking ssh
        // round-trip — do them off the main thread to avoid spinning the
        // beach ball during the load.
        let svc = fileService
        struct LoadResults: Sendable {
            let cfg: Result<HermesConfig, Error>
            let gw: Result<GatewayState?, Error>
            let running: Result<pid_t?, Error>
        }
        let results = await Task.detached { () -> LoadResults in
            LoadResults(
                cfg: svc.loadConfigResult(),
                gw: svc.loadGatewayStateResult(),
                running: svc.hermesPIDResult()
            )
        }.value

        switch results.cfg {
        case .success(let c): config = c
        case .failure(let e):
            config = .empty
            collectedErrors.append("config.yaml — \(e.localizedDescription)")
        }
        switch results.gw {
        case .success(let g): gatewayState = g
        case .failure(let e):
            gatewayState = nil
            collectedErrors.append("gateway_state.json — \(e.localizedDescription)")
        }
        switch results.running {
        case .success(let pid): hermesRunning = (pid != nil)
        case .failure(let e):
            hermesRunning = false
            collectedErrors.append("pgrep — \(e.localizedDescription)")
        }

        // Only surface when there's a real error AND we're on a remote
        // context. Local contexts rarely hit these paths (live DB, local
        // filesystem), and a transient "file doesn't exist yet" on fresh
        // installs shouldn't scare users.
        if context.isRemote, !collectedErrors.isEmpty {
            lastReadError = collectedErrors.joined(separator: "\n")
        } else {
            lastReadError = nil
        }
        isLoading = false
    }
}
