import Foundation
import ScarfCore
import AppKit
import UniformTypeIdentifiers

struct SessionStoreStats {
    let totalSessions: Int
    let totalMessages: Int
    let databaseSize: String
    let platformCounts: [(platform: String, count: Int)]
}

@Observable
final class SessionsViewModel {
    let context: ServerContext
    private let dataService: HermesDataService

    init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
    }


    var sessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]
    var selectedSession: HermesSession?
    var messages: [HermesMessage] = []
    var searchText = ""
    var searchResults: [HermesMessage] = []
    var isSearching = false
    var storeStats: SessionStoreStats?
    var subagentSessions: [HermesSession] = []

    var renameSessionId: String?
    var renameText = ""
    var showRenameSheet = false
    var showDeleteConfirmation = false
    var deleteSessionId: String?

    // MARK: - Project attribution (v2.5)
    //
    // Session-to-project lookup populated from `~/.hermes/scarf/session_project_map.json`
    // + the project registry. Drives the "Project" filter Menu above the
    // list and the badge chip in each session row. Mirrors the same
    // services iOS uses on the Dashboard's Sessions tab — both platforms
    // read the same sidecar.

    /// session ID → project display name. Empty when no sessions on screen
    /// are project-attributed.
    private(set) var sessionProjectNames: [String: String] = [:]
    /// Every project in the registry, used to populate the filter Menu.
    private(set) var allProjects: [ProjectEntry] = []
    /// Currently selected project filter.
    /// - `nil` (default): show all sessions.
    /// - `""` sentinel: show only unattributed sessions.
    /// - any other string: project name to match against `sessionProjectNames`.
    var projectFilter: String?

    /// Sessions to actually render — applies `projectFilter` over `sessions`.
    /// Inset is O(n) which is fine at the 500-session window we load.
    var filteredSessions: [HermesSession] {
        guard let filter = projectFilter else { return sessions }
        if filter.isEmpty {
            return sessions.filter { sessionProjectNames[$0.id] == nil }
        }
        return sessions.filter { sessionProjectNames[$0.id] == filter }
    }

    /// Project display name for a session, or nil for unattributed.
    func projectName(for session: HermesSession) -> String? {
        sessionProjectNames[session.id]
    }

    func load() async {
        // refresh() forces a fresh snapshot on remote contexts. The DB stays
        // open after load() so selectSession()/search() can query without
        // re-opening — cleanup() closes on disappear.
        let opened = await dataService.refresh()
        guard opened else { return }
        sessions = await dataService.fetchSessions(limit: 500)
        sessionPreviews = await dataService.fetchSessionPreviews(limit: 500)

        // Load attribution + registry off the main actor in one batch so
        // 500 rows don't trigger 500 SFTP reads. Failure is silent — the
        // absence of project labels is a cosmetic degradation, not a
        // data-loss problem (matches the iOS Dashboard pattern).
        let ctx = context
        let bundle: (names: [String: String], projects: [ProjectEntry]) = await Task.detached {
            let attribution = SessionAttributionService(context: ctx)
            let registry = ProjectDashboardService(context: ctx).loadRegistry()
            let pathToName = Dictionary(
                uniqueKeysWithValues: registry.projects.map { ($0.path, $0.name) }
            )
            let map = attribution.load().mappings
            var names: [String: String] = [:]
            for (sessionID, path) in map {
                if let name = pathToName[path] {
                    names[sessionID] = name
                }
            }
            return (names: names, projects: registry.projects)
        }.value
        sessionProjectNames = bundle.names
        allProjects = bundle.projects

        computeStats()
    }

    func previewFor(_ session: HermesSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = sessionPreviews[session.id], !preview.isEmpty { return preview }
        return session.id
    }

    func selectSession(_ session: HermesSession) async {
        selectedSession = session
        messages = await dataService.fetchMessages(sessionId: session.id)
        subagentSessions = await dataService.fetchSubagentSessions(parentId: session.id)
    }

    func selectSessionById(_ id: String) async {
        if let session = sessions.first(where: { $0.id == id }) {
            await selectSession(session)
        }
    }

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchResults = await dataService.searchMessages(query: query)
    }

    func cleanup() async {
        await dataService.close()
    }

    // MARK: - Session Actions

    func beginRename(_ session: HermesSession) {
        renameSessionId = session.id
        renameText = previewFor(session)
        showRenameSheet = true
    }

    func confirmRename() {
        guard let sessionId = renameSessionId else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let result = runHermes(["sessions", "rename", sessionId, title])
        if result.exitCode == 0 {
            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                let updated = sessions[idx].withTitle(title)
                sessions[idx] = updated
                if selectedSession?.id == sessionId {
                    selectedSession = updated
                }
            }
            sessionPreviews[sessionId] = title
        }
        showRenameSheet = false
        renameSessionId = nil
    }

    func beginDelete(_ session: HermesSession) {
        deleteSessionId = session.id
        showDeleteConfirmation = true
    }

    func confirmDelete() {
        guard let sessionId = deleteSessionId else { return }
        let result = runHermes(["sessions", "delete", "--yes", sessionId])
        if result.exitCode == 0 {
            sessions.removeAll { $0.id == sessionId }
            if selectedSession?.id == sessionId {
                selectedSession = nil
                messages = []
            }
            computeStats()
        }
        showDeleteConfirmation = false
        deleteSessionId = nil
    }

    func exportSession(_ session: HermesSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.id).jsonl"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runHermes(["sessions", "export", url.path, "--session-id", session.id])
    }

    func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hermes-sessions.jsonl"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runHermes(["sessions", "export", url.path])
    }

    // MARK: - Stats

    private func computeStats() {
        let totalMessages = sessions.reduce(0) { $0 + $1.messageCount }

        var platformCounts: [String: Int] = [:]
        for s in sessions {
            platformCounts[s.source, default: 0] += 1
        }
        let sorted = platformCounts.sorted { $0.value > $1.value }.map { (platform: $0.key, count: $0.value) }

        let dbPath = context.paths.stateDB
        let fileSize: String
        if let stat = context.makeTransport().stat(dbPath) {
            fileSize = Int64(stat.size).formatted(.byteCount(style: .file))
        } else {
            fileSize = "unknown"
        }

        storeStats = SessionStoreStats(
            totalSessions: sessions.count,
            totalMessages: totalMessages,
            databaseSize: fileSize,
            platformCounts: sorted
        )
    }

    // MARK: - Hermes CLI

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }
}
