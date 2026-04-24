// iOS-specific Dashboard state. Uses `HermesDataService` directly via
// a Citadel-backed `ServerTransport` — no Mac-only `HermesFileService`
// dependency, so the Dashboard shows session + token stats only, not
// the config.yaml / gateway-state / pgrep checks the Mac dashboard
// surfaces. Those come in a later phase once `HermesFileService` is
// either moved to ScarfCore or replicated in an iOS-compatible form.
#if canImport(SQLite3)

import Foundation
import Observation
import ScarfCore

/// iOS Dashboard view-state. Loaded on view appear; refreshes on
/// pull-to-refresh. The VM owns a `HermesDataService` instance which
/// (via the transport factory wired in `ScarfIOSApp.init`) routes all
/// DB reads through Citadel SFTP + SSH exec.
@Observable
@MainActor
public final class IOSDashboardViewModel {
    public let context: ServerContext
    private let dataService: HermesDataService

    public init(context: ServerContext) {
        self.context = context
        self.dataService = HermesDataService(context: context)
    }

    // MARK: - Published state

    public var stats: HermesDataService.SessionStats = .empty
    public var recentSessions: [HermesSession] = []
    public var sessionPreviews: [String: String] = [:]
    public var isLoading: Bool = true

    /// session-id → project display name, for sessions attributed to
    /// a registered Scarf project. Populated in `load()` by a single
    /// SFTP read of `session_project_map.json` + the project registry;
    /// subsequent row renders are O(1) dict lookups. Empty when no
    /// sessions on screen are attributed.
    public private(set) var sessionProjectNames: [String: String] = [:]

    /// Surfaced when the SQLite snapshot or DB open fails. Shown in a
    /// yellow banner above the stats with a "Retry" button. `nil` means
    /// the last load was healthy.
    public var lastError: String?

    // MARK: - Loading

    /// Refresh the dashboard. Does a `dataService.refresh()` (close +
    /// reopen, forces a fresh Citadel snapshot on iOS) then reads the
    /// visible bits.
    public func load() async {
        isLoading = true
        lastError = nil

        let opened = await dataService.refresh()
        if !opened {
            lastError = await dataService.lastOpenError
                ?? "Couldn't read the Hermes database — check that the server is reachable and that `~/.hermes/state.db` exists."
            isLoading = false
            return
        }

        stats = await dataService.fetchStats()
        recentSessions = await dataService.fetchSessions(limit: 5)
        sessionPreviews = await dataService.fetchSessionPreviews(limit: 5)

        // Attribution lookup (pass-2 UX): load the session→project
        // sidecar + project registry once so Dashboard rows can show
        // which project each session belongs to. Batched (not per-row)
        // so we don't pay a SFTP round-trip for every Recent Sessions
        // cell. Failure is silent — the absence of project labels is
        // a cosmetic degradation, not a data-loss problem.
        let ctx = context
        let attributions: [String: String] = await Task.detached {
            let attribution = SessionAttributionService(context: ctx)
            let projectRegistry = ProjectDashboardService(context: ctx).loadRegistry()
            let pathToName = Dictionary(
                uniqueKeysWithValues: projectRegistry.projects.map { ($0.path, $0.name) }
            )
            let map = attribution.load().mappings
            var result: [String: String] = [:]
            for (sessionID, path) in map {
                if let name = pathToName[path] {
                    result[sessionID] = name
                }
            }
            return result
        }.value
        sessionProjectNames = attributions

        await dataService.close()
        isLoading = false
    }

    /// Helper used by DashboardView rows. Returns the project display
    /// name a session is attributed to, or nil for unattributed
    /// sessions (CLI-started, or started before v2.3).
    public func projectName(for session: HermesSession) -> String? {
        sessionProjectNames[session.id]
    }

    /// Called from the pull-to-refresh gesture.
    public func refresh() async {
        await load()
    }
}

#endif // canImport(SQLite3)
