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

/// Cross-feature signal (t-5f1d9008): posted on
/// `NotificationCenter.default` after the Sessions tab successfully
/// deletes a session server-side (`hermes sessions delete` exit 0).
/// The Sessions feature and the chat pane live in the same window but
/// hold no references to each other, and there is one ChatViewModel per
/// window (multi-server) — a broadcast each ChatViewModel filters by
/// identity is the minimal seam, matching the app's existing
/// block-observer NotificationCenter idiom (ServerLiveStatusRegistry,
/// t-aud05). NEVER posted for a failed delete.
///
/// userInfo payload:
/// - `sessionIdKey` → `String`: the full deleted session id.
/// - `contextKey` → `ServerContext`: the posting feature's context.
///   Receivers must compare the session-STORE identity — `id` AND
///   `paths.home` — not just `id`: profile scoping (#126) re-points
///   the home while keeping the same `ServerID`, and distinct
///   servers/profiles can each hold a session with the same id. (Not
///   full-struct equality either: cosmetic/cache fields like
///   `displayName` or `hermesBinaryHint` don't move the store, and a
///   drift there must not skip a teardown.)
///
/// `nonisolated` so the constants are readable from the non-MainActor
/// observer block before it hops isolation (they're immutable Sendable
/// values; the app target defaults declarations to MainActor).
enum SessionDeletedSignal {
    nonisolated static let name = Notification.Name("Scarf.sessionDeletedElsewhere")
    nonisolated static let sessionIdKey = "sessionId"
    nonisolated static let contextKey = "context"
}

@Observable
final class SessionsViewModel {
    let context: ServerContext
    private let dataService: HermesDataService

    init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
    }

    /// Runs the `hermes sessions delete --yes <id>` CLI for
    /// `confirmDelete()` and returns its exit code. Production default
    /// shells out through the context's transport (unchanged
    /// semantics); tests inject a stub so pinning the
    /// success-posts / failure-does-NOT-post `SessionDeletedSignal`
    /// contract (t-5f1d9008) doesn't spawn a real CLI process. Same
    /// seam shape as `ChatViewModel.sessionDeleteRunner` (t-01bd55ec).
    @ObservationIgnored
    var sessionDeleteRunner: (ServerContext, String) -> Int32 = { ctx, sessionId in
        ctx.runHermes(["sessions", "delete", "--yes", sessionId]).exitCode
    }

    /// Runs `hermes sessions export …` and hands back stdout bytes, stderr,
    /// and the exit code. Production default shells out through the
    /// context's transport; tests inject a stub so the export contract can
    /// be pinned without an NSSavePanel or a real SSH round-trip. Same seam
    /// shape as `sessionDeleteRunner`.
    ///
    /// Five minutes, not the 60s default: this streams a whole session (or
    /// the entire store, for "export all") back over SSH.
    @ObservationIgnored
    var sessionExportRunner: @Sendable (ServerContext, [String]) -> (stdout: Data, stderr: String, exitCode: Int32) = { ctx, args in
        ctx.runHermesCapturingStdout(args, timeout: 300)
    }


    /// True while `load()` runs so the view can show a `.loadingOverlay`
    /// instead of a blank table on first open / refresh. (t-aud07)
    var isLoading = false
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

    /// Result banner for the last export. Successes clear themselves;
    /// failures stay until the next attempt, because an export that
    /// reports nothing at all is the bug this replaced.
    var exportMessage: String?

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
        isLoading = true
        defer { isLoading = false }
        // refresh() forces a fresh snapshot on remote contexts. The DB stays
        // open after load() so selectSession()/search() can query without
        // re-opening — cleanup() closes on disappear.
        let opened = await dataService.refresh()
        guard opened else { return }
        // v2.7: folded the two serial fetches into one batched round
        // trip via sessionListSnapshot. Pre-fix this paid the 420 ms
        // SSH RTT twice on every Sessions tab open (~840 ms minimum
        // for the two queries alone over remote).
        let snapshot = await dataService.sessionListSnapshot(limit: 500)
        sessions = snapshot.sessions
        sessionPreviews = snapshot.previews

        // Load attribution + registry off the main actor in one batch so
        // 500 rows don't trigger 500 SFTP reads. Failure is silent — the
        // absence of project labels is a cosmetic degradation, not a
        // data-loss problem (matches the iOS Dashboard pattern).
        let ctx = context
        let bundle: (names: [String: String], projects: [ProjectEntry], dbSize: String) = await Task.detached {
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
            // Fold the state.db stat() into this off-main batch so the file-
            // size display doesn't cost a synchronous SSH stat on the main
            // actor on every watcher tick during a stream (gh#102).
            let dbSize: String
            if let stat = ctx.makeTransport().stat(ctx.paths.stateDB) {
                dbSize = Int64(stat.size).formatted(.byteCount(style: .file))
            } else {
                dbSize = "unknown"
            }
            return (names: names, projects: registry.projects, dbSize: dbSize)
        }.value
        sessionProjectNames = bundle.names
        allProjects = bundle.projects

        computeStats(dbSize: bundle.dbSize)
    }

    func previewFor(_ session: HermesSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = sessionPreviews[session.id], !preview.isEmpty { return preview }
        return session.id
    }

    func selectSession(_ session: HermesSession) async {
        selectedSession = session
        messages = await dataService.fetchMessages(sessionId: session.id, limit: HistoryPageSize.macSessionDetail)
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

    /// Server-side delete via `hermes sessions delete --yes`. On success,
    /// ALSO broadcasts `SessionDeletedSignal` (t-5f1d9008): this surface
    /// has no reference to the window's ChatViewModel, and pre-fix,
    /// deleting the chat-ATTACHED session here left the `hermes acp`
    /// client running against the deleted session — orphaned in-flight
    /// turn plus a leaked process (the leak shape t-01bd55ec fixed for
    /// the chat sidebar's own delete). The signal lets the one
    /// ChatViewModel attached to this exact session/context run that
    /// same teardown. A failed CLI delete posts nothing.
    func confirmDelete() {
        guard let sessionId = deleteSessionId else { return }
        if sessionDeleteRunner(context, sessionId) == 0 {
            sessions.removeAll { $0.id == sessionId }
            if selectedSession?.id == sessionId {
                selectedSession = nil
                messages = []
            }
            computeStats()
            NotificationCenter.default.post(
                name: SessionDeletedSignal.name,
                object: nil,
                userInfo: [
                    SessionDeletedSignal.sessionIdKey: sessionId,
                    SessionDeletedSignal.contextKey: context,
                ]
            )
        }
        showDeleteConfirmation = false
        deleteSessionId = nil
    }

    // MARK: - Export

    func exportSession(_ session: HermesSession) {
        beginExport(sessionId: session.id, suggestedName: "\(session.id).jsonl")
    }

    func exportAll() {
        beginExport(sessionId: nil, suggestedName: "hermes-sessions.jsonl")
    }

    /// The export always lands on **this Mac**, whichever host Hermes runs
    /// on — that's what someone driving a Mac GUI is asking for.
    ///
    /// Passing the panel's path to the CLI can't do that: on a remote
    /// context `hermes` executes on the far host over SSH, so a path from
    /// `NSSavePanel` (a path on this Mac) either fails against a directory
    /// the host doesn't have or dumps the file on the remote box where the
    /// user will never find it. Instead we ask the CLI for the payload on
    /// **stdout** (`sessions export -`, jsonl) and write those bytes here.
    /// Same code path for local and remote — nothing to branch on.
    private func beginExport(sessionId: String?, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        // `jsonl` has no system-declared UTType. Minting a dynamic one
        // stops the panel rewriting the name to `.json`, which the old
        // `[.json]` list did to every export.
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performExport(to: url, sessionId: sessionId)
    }

    /// Pipes the export out of the CLI and writes it to `url` on this Mac.
    /// Detached because a remote export is an SSH round-trip streaming the
    /// whole payload — running it inline would block the main actor for its
    /// full duration.
    func performExport(to url: URL, sessionId: String?) {
        // `-` is the CLI's "write jsonl to stdout" sentinel.
        var args = ["sessions", "export", "-"]
        if let sessionId { args += ["--session-id", sessionId] }
        Task.detached { [sessionExportRunner, context, args, url, self] in
            let result = sessionExportRunner(context, args)
            let outcome = Self.writeExport(result: result, to: url)
            await MainActor.run {
                self.exportMessage = outcome.message
                guard outcome.succeeded else { return }
                let banner = outcome.message
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    // Only clear our own banner — a newer export may
                    // have replaced it while we slept.
                    if self?.exportMessage == banner { self?.exportMessage = nil }
                }
            }
        }
    }

    /// Turns a CLI result into a written file + a user-facing banner.
    /// `nonisolated` so `performExport`'s detached task can do the disk
    /// write off the main actor.
    nonisolated private static func writeExport(
        result: (stdout: Data, stderr: String, exitCode: Int32),
        to url: URL
    ) -> (succeeded: Bool, message: String) {
        guard result.exitCode == 0 else {
            let detail = Self.errorSummary(from: result.stderr)
            return (false, detail.isEmpty
                ? "Export failed (exit \(result.exitCode))."
                : "Export failed: \(detail)")
        }
        do {
            try result.stdout.write(to: url, options: .atomic)
        } catch {
            return (false, "Export failed writing \(url.lastPathComponent): \(error.localizedDescription)")
        }
        // Naming the size confirms the file isn't the empty one a silently
        // broken pipe would leave behind.
        let size = Int64(result.stdout.count).formatted(.byteCount(style: .file))
        return (true, "Exported \(size) to \(url.path)")
    }

    /// The one useful line out of a CLI failure. Hermes is Python, so a
    /// crash arrives as a traceback whose *last* line is the actual error —
    /// the first 160 characters are just "Traceback (most recent call
    /// last):" and stack frames, which tell the user nothing.
    nonisolated private static func errorSummary(from stderr: String) -> String {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "" }
        return String(last.prefix(200))
    }

    // MARK: - Stats

    /// `dbSize` is pre-computed off-main by the watcher-driven `load()` so the
    /// `state.db` stat() — a synchronous SSH round-trip on remote — never runs
    /// on the main actor on the hot path (gh#102). The nil default keeps the
    /// one-shot `confirmDelete()` path doing the stat inline (user-initiated).
    private func computeStats(dbSize: String? = nil) {
        let totalMessages = sessions.reduce(0) { $0 + $1.messageCount }

        var platformCounts: [String: Int] = [:]
        for s in sessions {
            platformCounts[s.source, default: 0] += 1
        }
        let sorted = platformCounts.sorted { $0.value > $1.value }.map { (platform: $0.key, count: $0.value) }

        let fileSize: String
        if let dbSize {
            fileSize = dbSize
        } else if let stat = context.makeTransport().stat(context.paths.stateDB) {
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
