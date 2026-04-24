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
    /// Recent 5 sessions for the Overview sub-tab (glance-only surface).
    public var recentSessions: [HermesSession] = []
    /// Deeper session list for the Sessions sub-tab — larger window +
    /// filterable by project. Default 25; enough to cover "what did I
    /// work on this week" without paging.
    public var allSessions: [HermesSession] = []
    public var sessionPreviews: [String: String] = [:]
    public var isLoading: Bool = true

    /// session-id → project display name, for sessions attributed to
    /// a registered Scarf project. Populated in `load()` by a single
    /// SFTP read of `session_project_map.json` + the project registry;
    /// subsequent row renders are O(1) dict lookups. Empty when no
    /// sessions on screen are attributed.
    public private(set) var sessionProjectNames: [String: String] = [:]

    /// Every configured project, for the filter picker in the
    /// Sessions sub-tab. Populated alongside `sessionProjectNames`.
    public private(set) var allProjects: [ProjectEntry] = []

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
        allSessions = await dataService.fetchSessions(limit: 25)
        sessionPreviews = await dataService.fetchSessionPreviews(limit: 25)

        // Attribution lookup (pass-2 UX): load the session→project
        // sidecar + project registry once so Dashboard rows can show
        // which project each session belongs to. Batched (not per-row)
        // so we don't pay a SFTP round-trip for every Recent Sessions
        // cell. Failure is silent — the absence of project labels is
        // a cosmetic degradation, not a data-loss problem.
        let ctx = context
        let bundle: (names: [String: String], projects: [ProjectEntry]) = await Task.detached {
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
            return (names: result, projects: projectRegistry.projects)
        }.value
        sessionProjectNames = bundle.names
        allProjects = bundle.projects

        await dataService.close()
        isLoading = false
    }

    /// Sessions matching the given project filter. `nil` returns
    /// all 25 recent sessions (no filtering). `projectName` is the
    /// ProjectEntry.name that's the key in `sessionProjectNames`, so
    /// the filter is an O(n) dict lookup per session — cheap at our
    /// 25-session window. Sorting is preserved (newest first) from
    /// the upstream `fetchSessions(limit:)` query.
    public func sessions(filteredBy projectName: String?) -> [HermesSession] {
        guard let projectName, !projectName.isEmpty else { return allSessions }
        return allSessions.filter { session in
            sessionProjectNames[session.id] == projectName
        }
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
