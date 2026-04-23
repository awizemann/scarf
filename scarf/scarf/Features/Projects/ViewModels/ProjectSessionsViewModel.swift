import Foundation
import os

/// Drives the per-project Sessions tab introduced in v2.3. Pulls the
/// global session list from `HermesDataService`, filters by the
/// attribution sidecar, and exposes a minimal surface for the view:
/// the filtered sessions array, loading state, and a refresh entry
/// point that the view can call on appearance + on file-watcher
/// change.
@Observable
@MainActor
final class ProjectSessionsViewModel {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectSessionsViewModel")

    private let dataService: HermesDataService
    private let attribution: SessionAttributionService
    private let project: ProjectEntry

    init(context: ServerContext, project: ProjectEntry) {
        self.dataService = HermesDataService(context: context)
        self.attribution = SessionAttributionService(context: context)
        self.project = project
    }

    /// Sessions attributed to the owning project, in the order
    /// `HermesDataService.fetchSessions` returns them (newest first).
    var sessions: [HermesSession] = []

    /// True from `load()` start to its completion. The view renders
    /// a ProgressView during the first fetch; afterwards, re-fetches
    /// triggered by file-watcher changes happen silently.
    var isLoading: Bool = false

    /// Short diagnostic string for an empty list — nil when sessions
    /// are loaded and populated, otherwise explains the empty state
    /// (no sessions ever created in this project, vs. no sessions
    /// matched the project's attribution map).
    var emptyStateHint: String?

    /// Refresh the session list. Safe to call repeatedly; the data
    /// service reconnects to state.db on demand and the attribution
    /// service reads the sidecar afresh each call.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        let attributed = attribution.sessionIDs(forProject: project.path)
        if attributed.isEmpty {
            sessions = []
            emptyStateHint = "No chats have been started in this project yet. Click New Chat to begin."
            return
        }

        // Fetch a generous page; we filter client-side by attribution
        // map membership. The 200 ceiling matches other feature VMs
        // (ActivityViewModel, InsightsViewModel). HermesDataService
        // is an actor so this crosses the isolation boundary — the
        // SQLite read happens off the MainActor. If a single project
        // accumulates more than 200 attributed sessions, we'll need
        // a paged query; roadmap item, not a v2.3 problem.
        let all = await dataService.fetchSessions(limit: 200)
        let filtered = all.filter { attributed.contains($0.id) }
        sessions = filtered

        if filtered.isEmpty {
            // Attribution map has entries but none appear in the
            // recent session fetch — likely stale sidecar entries
            // for sessions Hermes has since deleted. The view shows
            // an informational empty state; pruning stale entries
            // is a roadmap follow-up, not a blocker.
            emptyStateHint = "This project has \(attributed.count) attributed session\(attributed.count == 1 ? "" : "s"), but none are in the recent history. They may have been deleted from Hermes."
        } else {
            emptyStateHint = nil
        }
    }
}
