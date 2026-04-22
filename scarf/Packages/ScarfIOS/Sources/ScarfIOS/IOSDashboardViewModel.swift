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

        await dataService.close()
        isLoading = false
    }

    /// Called from the pull-to-refresh gesture.
    public func refresh() async {
        await load()
    }
}

#endif // canImport(SQLite3)
