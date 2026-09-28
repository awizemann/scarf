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

/// Posted after a successful `hermes sessions rename` from ANY surface
/// (Sessions tab, chat sidebar), so every other view of the same session
/// — most visibly the chat header's `SessionInfoBar` title — updates
/// immediately instead of waiting for its next reload. Broadcast, not
/// polling: same pattern as `SessionDeletedSignal`.
enum SessionRenamedSignal {
    nonisolated static let name = Notification.Name("Scarf.sessionRenamedElsewhere")
    nonisolated static let sessionIdKey = "sessionId"
    nonisolated static let titleKey = "title"
    nonisolated static let contextKey = "context"
}

/// `hermes sessions export --format {jsonl,md,qmd,html,trace}` (v0.18.1+,
/// gated on `HermesCapabilities.hasSessionsExportFormats`). Cases mirror the
/// CLI's own `--format` choices exactly, so `cliValue == rawValue`.
///
/// Stdout (`-`) support was verified against the live v0.20 CLI rather than
/// assumed from `--help` text, because the help text is misleading: the
/// qmd/md validation error ("stdout (-) is only supported with --format
/// jsonl") reads as if only jsonl supports it, but `trace` accepts `-` too
/// (confirmed via `hermes sessions export - --format trace --dry-run
/// --session-id <real-id>` — it proceeded straight to transcript lookup,
/// never hit the stdout-format guard). `html` and `md`/`qmd` do error and
/// require a real output path/directory.
enum SessionExportFormat: String, CaseIterable, Identifiable {
    case jsonl
    case markdown = "md"
    case quarto = "qmd"
    case html
    case trace

    var id: String { rawValue }

    /// Value passed to `--format`.
    nonisolated var cliValue: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .jsonl: return "JSONL"
        case .markdown: return "Markdown"
        case .quarto: return "Quarto"
        case .html: return "HTML"
        case .trace: return "Trace"
        }
    }

    /// `jsonl` and `trace` write to the CLI's `-` stdout sentinel — Scarf
    /// captures those bytes and writes them to the chosen Mac path itself
    /// (the existing local/remote-safe flow). `html`/`md`/`qmd` don't
    /// support stdout and must be given a real output path, which the CLI
    /// then writes to wherever `hermes` runs.
    nonisolated var usesStdout: Bool { self == .jsonl || self == .trace }

    /// md/qmd export a *directory* of files (CLI default:
    /// `<hermes home>/session-exports`), not a single file.
    nonisolated var isDirectoryOutput: Bool { self == .markdown || self == .quarto }

    /// Sensible single-file extension. Unused for `isDirectoryOutput`
    /// formats, which pick a destination folder instead.
    var fileExtension: String {
        switch self {
        case .jsonl: return "jsonl"
        case .markdown: return "md"
        case .quarto: return "qmd"
        case .html: return "html"
        // Trace emits Claude Code JSONL for the HF Agent Trace Viewer.
        case .trace: return "jsonl"
        }
    }
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
    var sessionDeleteRunner: @Sendable (ServerContext, String) -> Int32 = { ctx, sessionId in
        ctx.runHermes(SessionsViewModel.deleteArgv(sessionId: sessionId)).exitCode
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

    /// Test seam for "does this export's session hold compaction-archived
    /// turns" (see `archivedTurnsNote`). `nil` asks `HermesDataService`.
    @ObservationIgnored
    var archivedTurnsProbe: (@Sendable ([String]) async -> Bool)?

    private func hasArchivedTurns(_ sessionIds: [String]) async -> Bool {
        if let probe = archivedTurnsProbe { return await probe(sessionIds) }
        // `load()` leaves the service open; before any load its schema
        // flags are unset and this answers false without touching the host.
        return await dataService.hasArchivedTurns(sessionIds: sessionIds)
    }


    /// True while `load()` runs so the view can show a `.loadingOverlay`
    /// instead of a blank table on first open / refresh. (t-aud07)
    var isLoading = false
    /// Why the last load couldn't read `state.db`, or nil when it could.
    /// The list keeps its previous rows while this is set.
    private(set) var loadError: String?
    var sessions: [HermesSession] = [] { didSet { recomputeFilteredSessions() } }
    var sessionPreviews: [String: String] = [:]
    var selectedSession: HermesSession?
    var messages: [HermesMessage] = []
    var searchText = ""
    var searchResults: [HermesMessage] = []
    var isSearching = false
    /// Set when the search QUERY failed (as opposed to matching nothing),
    /// so the results pane can say so instead of "No matches".
    var searchError: String?

    /// Set when Hermes is mid-FTS-rebuild, so search can say its results
    /// are knowingly partial instead of quietly under-returning. Probed
    /// per search (the markers move, and vanish when the backfill lands).
    var searchIndexRebuilding = false
    var storeStats: SessionStoreStats?
    var subagentSessions: [HermesSession] = []

    var renameSessionId: String?
    var renameText = ""
    var showRenameSheet = false

    /// The title the session had when the rename sheet opened. Captured so
    /// the Bot Chat guard tests the title on DISK, not whatever the user has
    /// typed into the field so far.
    @ObservationIgnored private var renameOriginalTitle: String?

    /// Set when `confirmRename()` is about to detach a bot's conversation
    /// (see `BotChatSession.renameNeedsConfirmation`). The view presents the
    /// warning; `confirmRenameAcknowledgingBotChat()` is the "do it anyway".
    var showBotChatRenameWarning = false
    /// Why the last rename attempt failed, `nil` when it succeeded or
    /// no attempt has been made. Set from `SessionRenameFailure` and
    /// shown inside the rename sheet, which stays open on failure so
    /// the user can correct the title (or learn they can't — the
    /// canonical Bot Chat refuses renames server-side).
    var renameError: String?
    var showDeleteConfirmation = false
    var deleteSessionId: String?
    /// Every segment of the row being deleted, root first, when it is a
    /// rotated compression chain (`HermesSession.lineageIds`); empty for
    /// an ordinary session. `confirmDelete` deletes all of them (R14-3).
    var deleteLineageIds: [String] = []

    /// How many session rows the pending delete removes — the confirmation
    /// dialog names it when a chain has more than one.
    var deleteSegmentCount: Int { max(deleteLineageIds.count, 1) }
    /// Why the last delete attempt failed; `nil` when it succeeded or none
    /// has been made. Rendered as a banner in the page header — the
    /// confirmation dialog is already gone by the time the CLI answers,
    /// so there is nowhere else to put it.
    var deleteError: String?

    /// Result banner for the last export. Successes clear themselves;
    /// failures stay until the next attempt, because an export that
    /// reports nothing at all is the bug this replaced.
    var exportMessage: String?

    // MARK: - Export format picker (v0.18.1, hasSessionsExportFormats)

    /// Bound to the format-picker sheet's `Picker`. Reset to `.jsonl`
    /// whenever a new export flow starts so a stale pick from a previous
    /// session doesn't leak forward.
    var exportFormat: SessionExportFormat = .jsonl
    /// Bound to the format-picker sheet's "Redact secrets" `Toggle`.
    ///
    /// The DEFAULT is per-format, because Hermes's is: `--redact` is opt-IN
    /// for every streamed format, while a `trace` redacts unconditionally and
    /// `--no-redact` is the opt-OUT (`_export_trace`: "Redaction is ON by
    /// default (traces leave the machine with --upload)",
    /// `hermes_cli/sessions_cmd.py:382-383`, read at `:395` @ v2026.9.7).
    /// Leaving this `false` for a trace made Scarf's default trace export
    /// actively emit `--no-redact` on every v0.18.1+ host — less redaction
    /// than any prior Scarf release. Drive it through
    /// ``exportFormatChanged(from:to:)``, never by hand.
    var exportRedact = false
    /// The user's last explicit NON-trace redact choice, so switching away
    /// from `trace` restores what they had instead of forcing the toggle OFF.
    private var exportRedactBeforeTrace = false
    /// Drives the format-picker sheet. Only ever set `true` by
    /// `beginExportFlow` when the host is v0.18.1+; pre-0.18.1 hosts skip
    /// straight to the save panel exactly as before.
    var showExportOptionsSheet = false

    /// Session to export, captured when the picker sheet opens so
    /// `confirmExportOptions()` knows what to hand the CLI. `nil` means
    /// "export all".
    private var pendingExportSessionId: String?
    /// Filename/folder-name stem (no extension) suggested to the save/open
    /// panel once the format is chosen.
    private var pendingExportBaseName: String = "hermes-sessions"
    /// `true` while the open picker sheet belongs to an "Export All" flow.
    /// Read by `availableExportFormats` and surfaced as
    /// `exportAllExcludesTrace` — `trace` cannot serve that flow.
    private var pendingExportIsAllSessions = false
    /// Every segment of the session being exported, root first, when it is
    /// a rotated compression chain (`HermesSession.lineageIds`); empty for
    /// an ordinary session or "export all". The row and its detail show the
    /// whole lineage, so the export covers it too (see `exportArguments`
    /// and `performExport`).
    private var pendingExportLineageIds: [String] = []
    /// `HermesCapabilities.hasSessionsExportNoRedact`, captured when the
    /// flow starts (same environment-read-stays-in-SwiftUI split as
    /// `formatsAvailable`).
    private(set) var traceNoRedactAvailable = false
    /// `HermesCapabilities.hasSessionsExportArchivedTurns`, captured when
    /// the flow starts: whether this host's Markdown/HTML export includes
    /// compaction-archived turns (see `archivedTurnsNote`).
    var exportIncludesArchivedTurns = false

    // MARK: - Project attribution (v2.5)
    //
    // Session-to-project lookup populated from `~/.hermes/scarf/session_project_map.json`
    // + the project registry. Drives the "Project" filter Menu above the
    // list and the badge chip in each session row. Mirrors the same
    // services iOS uses on the Dashboard's Sessions tab — both platforms
    // read the same sidecar.

    /// session ID → project display name. Empty when no sessions on screen
    /// are project-attributed.
    private(set) var sessionProjectNames: [String: String] = [:] {
        didSet { recomputeFilteredSessions() }
    }
    /// Every project in the registry, used to populate the filter Menu.
    private(set) var allProjects: [ProjectEntry] = []
    /// Currently selected project filter.
    /// - `nil` (default): show all sessions.
    /// - `""` sentinel: show only unattributed sessions.
    /// - any other string: project name to match against `sessionProjectNames`.
    var projectFilter: String? { didSet { recomputeFilteredSessions() } }

    /// Sessions to actually render — `projectFilter` applied over `sessions`.
    ///
    /// MEMOIZED, not computed. As a computed property this ran a full O(n)
    /// filter over the 500-row window on EVERY SwiftUI body evaluation of
    /// every view that touched it — selection changes, hover, the search
    /// field, each watcher tick — for a result that only changes when
    /// `sessions`, `sessionProjectNames` or `projectFilter` does. Those three
    /// are the only inputs, and each recomputes this on `didSet`, so the
    /// cache cannot go stale without the compiler noticing a fourth input.
    private(set) var filteredSessions: [HermesSession] = []

    /// The three pills above the table. Lives on the view model rather than
    /// as view `@State` so the row slice and the counts it promises are
    /// derived ONCE per input change instead of once per body evaluation.
    enum QuickFilter: String, CaseIterable, Identifiable, Sendable {
        case all, today, starred
        var id: String { rawValue }
        /// `LocalizedStringResource`, not `String` — a `String` here bound
        /// `Text`'s verbatim overload at the pill and was never extractable.
        var label: LocalizedStringResource {
            switch self {
            case .all: return "All"
            case .today: return "Today"
            case .starred: return "Starred"
            }
        }
    }

    var quickFilter: QuickFilter = .all { didSet { recomputeFilteredSessions() } }

    /// `filteredSessions` with `quickFilter` applied — the rows actually
    /// rendered. Memoized for the same reason as `filteredSessions`: the view
    /// referenced it four times per body pass, each a fresh O(n) filter.
    private(set) var visibleSessions: [HermesSession] = []

    /// Row count per pill. Each case MUST agree with the corresponding
    /// `visibleSessions` slice — the pill promises a count and the table then
    /// has to deliver those rows — so both are computed here, together, from
    /// the same inputs. Three separate O(n) filters used to run per body pass.
    private(set) var quickFilterCounts: [QuickFilter: Int] = [:]

    nonisolated static func isToday(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.isDateInToday(date)
    }

    private func recomputeFilteredSessions() {
        if let filter = projectFilter {
            if filter.isEmpty {
                filteredSessions = sessions.filter { sessionProjectNames[$0.id] == nil }
            } else {
                filteredSessions = sessions.filter { sessionProjectNames[$0.id] == filter }
            }
        } else {
            filteredSessions = sessions
        }

        switch quickFilter {
        case .all:     visibleSessions = filteredSessions
        case .today:   visibleSessions = filteredSessions.filter { Self.isToday($0.startedAt) }
        case .starred: visibleSessions = filteredSessions.filter(\.pinned)
        }

        // Counts are over the WHOLE window, not the project slice — that is
        // the pre-existing semantics of the pill badges, kept deliberately.
        var todayCount = 0
        var starredCount = 0
        for session in sessions {
            if Self.isToday(session.startedAt) { todayCount += 1 }
            if session.pinned { starredCount += 1 }
        }
        quickFilterCounts = [.all: sessions.count, .today: todayCount, .starred: starredCount]
    }

    /// Project display name for a session, or nil for unattributed.
    func projectName(for session: HermesSession) -> String? {
        sessionProjectNames[session.id]
    }

    /// Single in-flight load handle — the coalescing guard
    /// `DashboardViewModel` uses. `SessionsView` drives `load()` from
    /// `.task` and from `.onChange(fileWatcher.lastChangeDate)`, which
    /// during an active stream fires far faster than a 500-row snapshot
    /// completes; without this, overlapping loads walked over `sessions`
    /// and `storeStats` in completion order rather than issue order.
    @ObservationIgnored
    private var inFlightLoad: Task<Void, Never>?

    func load() async {
        if let existing = inFlightLoad {
            await existing.value
            return
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            await self?.loadImpl()
        }
        inFlightLoad = task
        await task.value
        inFlightLoad = nil
    }

    private func loadImpl() async {
        isLoading = true
        defer { isLoading = false }
        // refresh() forces a fresh snapshot on remote contexts. The DB stays
        // open after load() so selectSession()/search() can query without
        // re-opening — cleanup() closes on disappear.
        let opened = await dataService.refresh()
        guard opened else {
            // Say so, and keep what is already on screen: an empty list
            // here rendered "No sessions match this filter" for a host
            // that could not be read at all.
            loadError = await dataService.reportableOpenError
            return
        }
        // v2.7: folded the two serial fetches into one batched round
        // trip via sessionListSnapshot. Pre-fix this paid the 420 ms
        // SSH RTT twice on every Sessions tab open (~840 ms minimum
        // for the two queries alone over remote).
        // `includeUnreadActivity: false` — this tab renders no unread
        // indicator, and the `last_active` expression that feeds
        // `HermesSession.isUnread` is a correlated MAX(messages.timestamp)
        // subquery per row. At 500 rows per watcher tick that is 500
        // subqueries bought for a value nothing on this screen reads. The
        // chat sidebar, which does badge unread, keeps it.
        let snapshot = await dataService.sessionListSnapshot(limit: 500, includeUnreadActivity: false)
        if let failure = snapshot.queryError {
            // A failed batch (an SSH drop on a watcher tick, a locked DB)
            // must not wipe a list that loaded a moment ago. Keep the last
            // good rows and raise the banner.
            loadError = failure
            return
        }
        loadError = nil
        sessions = snapshot.sessions
        sessionPreviews = snapshot.previews

        // Load attribution + registry off the main actor in one batch so
        // 500 rows don't trigger 500 SFTP reads. Failure is silent — the
        // absence of project labels is a cosmetic degradation, not a
        // data-loss problem (matches the iOS Dashboard pattern).
        let ctx = context
        // A thread of its own: every read here is a transport call (C10).
        let bundle: (names: [String: String], projects: [ProjectEntry], dbSize: String) = await OffPool.run {
            let attribution = SessionAttributionService(context: ctx)
            let registry = ProjectDashboardService(context: ctx).loadRegistry()
            // First row wins at a shared path; see `projectNames`.
            let names = SessionAttributionService.projectNames(
                mappings: attribution.load().mappings,
                projects: registry.projects
            )
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
        }
        // A rotated compression chain is listed under its tip id; carry the
        // root's project over so the row keeps its label and filter.
        sessionProjectNames = HermesSession.carryingLineageLabels(bundle.names, onto: sessions)
        allProjects = bundle.projects

        computeStats(dbSize: bundle.dbSize)
    }

    func previewFor(_ session: HermesSession) -> String {
        session.displayLabel(preview: sessionPreviews[session.id])
    }

    /// Lazy-load a message's `reasoning_content` for the detail sheet's
    /// REASONING disclosure. The bulk fetch uses `messageColumnsLight`,
    /// which NULLs that blob, so v0.16+ thinking-model rows (legacy
    /// `reasoning` column empty, everything in `reasoning_content`) opened
    /// to a blank disclosure here. Same seam the chat bubble already uses
    /// (`RichChatViewModel.reasoningContent(for:)`, t-aud21).
    func reasoningContent(for messageId: Int) async -> String? {
        await dataService.fetchReasoningContent(for: messageId)
    }

    /// Shown in the detail sheet when the open session came from a search
    /// hit the list doesn't include (see `selectSessionById`).
    var selectedSessionListingNote: String?

    func selectSession(_ session: HermesSession) async {
        selectedSessionListingNote = nil
        selectedSession = session
        // A rotated compression chain spans several session rows; show the
        // whole conversation, as Hermes does, not just the tip's segment.
        messages = await dataService.fetchMessages(
            sessionIds: session.allSessionIds,
            limit: HistoryPageSize.macSessionDetail
        )
        var subagents: [HermesSession] = []
        for segment in session.allSessionIds {
            subagents += await dataService.fetchSubagentSessions(parentId: segment)
        }
        subagentSessions = subagents
    }

    func selectSessionById(_ id: String) async {
        // `covers`: a search hit can land on any segment of a compression
        // chain, while the list shows the chain under its tip id.
        if let session = sessions.first(where: { $0.covers(id) }) {
            await selectSession(session)
            return
        }
        // Not in the loaded list: an archived session, a delegate
        // subagent, a hidden row, or a conversation older than the 500
        // rows loaded. Search finds all of them, so open the hit directly
        // rather than doing nothing (R14-1), and say why the list doesn't
        // show it.
        guard let lookup = await dataService.fetchSessionForDetail(id: id) else { return }
        await selectSession(lookup.session)
        selectedSessionListingNote = Self.listingNote(
            isArchived: lookup.isArchived, isListed: lookup.isListed, source: lookup.session.source)
    }

    /// Why a session opened from a search hit is not in the list; nil when
    /// the list would show it (it was just older than the rows loaded).
    ///
    /// `source` names the kanban/tool/oneshot sessions Hermes keeps out of
    /// every list (`HermesDataService.internalListingSources`), which are
    /// neither subagent runs nor hidden.
    nonisolated static func listingNote(isArchived: Bool, isListed: Bool, source: String? = nil) -> String? {
        if isArchived {
            return String(localized: "Archived — session lists don't show this session.")
        }
        if !isListed, let source, HermesDataService.internalListingSources.contains(source) {
            return String(localized: "Not in the session list — Hermes keeps kanban worker, tool integration and one-shot sessions out of its lists.")
        }
        if !isListed {
            return String(localized: "Not in the session list — this is a subagent run or a hidden session.")
        }
        return nil
    }

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        do {
            searchResults = try await dataService.searchMessagesChecked(query: query)
            searchError = nil
        } catch {
            searchResults = []
            searchError = error.localizedDescription
        }
        searchIndexRebuilding = await dataService.searchIndexStatus().isRebuilding
    }

    func cleanup() async {
        await dataService.close()
    }

    // MARK: - Session Actions

    func beginRename(_ session: HermesSession) {
        renameSessionId = session.id
        renameText = previewFor(session)
        renameOriginalTitle = session.title
        renameError = nil
        showBotChatRenameWarning = false
        showRenameSheet = true
    }

    /// Ask first when this would detach a bot's conversation history. Hermes
    /// refuses the rename server-side only for a HIDDEN "Bot Chat", and a
    /// Scarf-created one is never hidden — so without this the rename simply
    /// succeeds and orphans the transcript (go/no-go blocking condition 3).
    func confirmRename() {
        guard renameSessionId != nil else { return }
        if BotChatSession.renameNeedsConfirmation(currentTitle: renameOriginalTitle, newTitle: renameText),
           !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showBotChatRenameWarning = true
            return
        }
        performRename()
    }

    /// The user read the warning and chose to rename anyway.
    func confirmRenameAcknowledgingBotChat() {
        showBotChatRenameWarning = false
        performRename()
    }

    /// argv for `hermes sessions rename`. The `--` separator is REQUIRED:
    /// `title` is `nargs="+"` on Hermes's parser
    /// (`hermes_cli/subcommands/sessions.py:210-213` at v2026.9.7), so a
    /// title that begins with a dash ("-- draft", "-v2 notes") is consumed
    /// as an option and argparse exits 2 instead of renaming. Everything
    /// after `--` is positional. Title stays ONE argv element — Hermes
    /// re-joins the list with a single space (`sessions_cmd.py:681`), so
    /// splitting here would collapse the user's internal spacing.
    nonisolated static func renameArgv(sessionId: String, title: String) -> [String] {
        HermesSessionRenameCommand.argv(sessionId: sessionId, title: title)
    }

    /// `sessions delete --yes -- <id>`. P47: the flag comes FIRST and the
    /// separator after it — argparse reads everything past the first `--` as
    /// a positional, so `--yes` appended afterwards would exit 2.
    /// `session_id` is the subparser's only positional and `--yes` its only
    /// flag (`hermes_cli/subcommands/sessions.py:100-102` @ `v2026.9.7`),
    /// which is what makes `--` safe here.
    static func deleteArgv(sessionId: String) -> [String] {
        ["sessions", "delete", "--yes", "--", sessionId]
    }

    private func performRename() {
        guard let sessionId = renameSessionId else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear first: an empty title is a no-op, and leaving a previous
        // attempt's message on screen makes it read as a fresh failure.
        renameError = nil
        guard !title.isEmpty else { return }
        guard !isRenaming else { return }
        isRenaming = true
        let ctx = context
        inFlightRename = Task { [weak self] in
            // `hermes sessions rename` is a process spawn — an SSH exec
            // channel on a remote host — and ran inline on the MainActor,
            // freezing the sheet (and the whole window) for the round-trip.
            // Detached, matching `loadImpl()`'s attribution batch.
            let result = await OffPool.run {
                ctx.runHermes(SessionsViewModel.renameArgv(sessionId: sessionId, title: title))
            }
            guard let self else { return }
            self.isRenaming = false
            guard result.exitCode == 0 else {
                // Keep the sheet up so the message lands next to the field
                // that produced it. The canonical Bot Chat can never be
                // renamed, so this is also the only place the user is told
                // why (see `SessionRenameFailure`).
                self.renameError = SessionRenameFailure.message(for: result.output)
                return
            }
            NotificationCenter.default.post(
                name: SessionRenamedSignal.name,
                object: nil,
                userInfo: [
                    SessionRenamedSignal.sessionIdKey: sessionId,
                    SessionRenamedSignal.titleKey: title,
                    SessionRenamedSignal.contextKey: ctx,
                ]
            )
            if let idx = self.sessions.firstIndex(where: { $0.id == sessionId }) {
                let updated = self.sessions[idx].withTitle(title)
                self.sessions[idx] = updated
                if self.selectedSession?.id == sessionId {
                    self.selectedSession = updated
                }
            }
            self.sessionPreviews[sessionId] = title
            self.renameError = nil
            self.showRenameSheet = false
            self.renameSessionId = nil
            self.renameOriginalTitle = nil
        }
    }

    /// True while the rename CLI is running. The sheet's Rename button
    /// disables on it, so the busy state renders instead of the window
    /// hanging.
    private(set) var isRenaming = false

    /// True while the delete CLI is running.
    private(set) var isDeleting = false

    /// In-flight handle for `confirmDelete()` / `performRename()`. Exposed so
    /// a test can `await` the mutation it just triggered — the CLI call moved
    /// off the MainActor, so these are no longer complete when the call
    /// returns.
    @ObservationIgnored private(set) var inFlightDelete: Task<Void, Never>?
    @ObservationIgnored private(set) var inFlightRename: Task<Void, Never>?

    func beginDelete(_ session: HermesSession) {
        deleteSessionId = session.id
        deleteLineageIds = session.lineageIds.count > 1 ? session.lineageIds : []
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
        guard !isDeleting else { return }
        deleteError = nil
        isDeleting = true
        let runner = sessionDeleteRunner
        let ctx = context
        // A compression chain is one row but several session rows; delete
        // them all, tip first (`SessionChainDelete`, R14-3).
        let ids = SessionChainDelete.deletionOrder(lineage: deleteLineageIds, rowId: sessionId)
        inFlightDelete = Task { [weak self] in
            // Off the main actor: the delete CLI is a remote process spawn
            // (OffPool, P60 — a blocking wait, not cooperative-pool work).
            // The injected `sessionDeleteRunner` seam is preserved exactly —
            // tests still stub it, they just await instead of returning.
            let outcome = await OffPool.run { SessionChainDelete.run(ids) { runner(ctx, $0) } }
            guard let self else { return }
            self.isDeleting = false
            let deleted = Set(outcome.deleted)
            if !deleted.isEmpty {
                self.sessions.removeAll { deleted.contains($0.id) }
                if let selected = self.selectedSession?.id, deleted.contains(selected) {
                    self.selectedSession = nil
                    self.messages = []
                }
                self.computeStats()
                for id in outcome.deleted {
                    NotificationCenter.default.post(
                        name: SessionDeletedSignal.name,
                        object: nil,
                        userInfo: [
                            SessionDeletedSignal.sessionIdKey: id,
                            SessionDeletedSignal.contextKey: ctx,
                        ]
                    )
                }
            }
            if let failed = outcome.failed {
                // Pre-fix this branch was an implicit no-op: the dialog
                // dismissed, the row stayed, and nothing said why. The row
                // staying put IS the correct outcome for a failed delete —
                // it's the silence that made it read as a UI glitch.
                self.deleteError = outcome.deleted.isEmpty
                    ? "Couldn't delete that session on \(ctx.displayName) (hermes sessions delete exited \(failed.exitCode))."
                    : "Deleted \(outcome.deleted.count) of \(ids.count) linked segments on \(ctx.displayName); the rest couldn't be deleted (hermes sessions delete exited \(failed.exitCode))."
                if !outcome.deleted.isEmpty {
                    // The rest of the chain is still there, now listed
                    // under a new tip: reload so it shows.
                    Task { await self.load() }
                }
            }
            self.showDeleteConfirmation = false
            self.deleteSessionId = nil
            self.deleteLineageIds = []
        }
    }

    // MARK: - Export

    /// Formats offered in the export picker. On a remote context only the
    /// stdout-capable formats (`jsonl`, `trace`) are offered: the path
    /// formats (`html`/`md`/`qmd`) hand the save panel's Mac-local path to
    /// a CLI that executes on the far host over SSH, so the file would land
    /// on the remote box while the success banner claims a local path (the
    /// exact bug class `beginExport`'s doc comment describes for the stdout
    /// flow). Local contexts keep all five formats — except that an "Export
    /// All" flow drops `trace` on either kind of context, because the CLI
    /// cannot produce a multi-session trace on stdout at all (see
    /// `exportAllExcludesTrace`).
    var availableExportFormats: [SessionExportFormat] {
        var formats = context.isRemote
            ? SessionExportFormat.allCases.filter(\.usesStdout)
            : SessionExportFormat.allCases
        if pendingExportIsAllSessions {
            formats.removeAll { $0 == .trace }
        }
        return formats
    }

    /// Why `trace` is not offered for "Export All": with neither
    /// `--session-id` nor a filter, `_export_trace` takes its "the last thing
    /// I did" branch and resolves ONE session via
    /// `list_sessions_rich(limit=1, order_by_last_active=True)`
    /// (`hermes_cli/sessions_cmd.py:385-389` at v2026.9.7), so the export
    /// Scarf captured held a single session while the banner claimed the
    /// whole board. The CLI's own multi-session trace path writes a
    /// DIRECTORY of `<id>.trace.jsonl` files (`:425-436`, the `else` branch
    /// through its `except TraceRedactionError`; `:439` is already
    /// `def _export_markdown`) and so cannot
    /// stream to the one file the save panel picked either. Per-session
    /// "Export…" still offers `trace` — that path passes `--session-id`.
    var exportAllExcludesTrace: Bool { pendingExportIsAllSessions }

    /// - Parameter formatsAvailable: `HermesCapabilities.hasSessionsExportFormats`,
    ///   read by the view from `@Environment(\.hermesCapabilities)`. The
    ///   view model has no capability store of its own — same split as
    ///   `PlatformsView`/`GatewayBehaviorViewModel`, where the environment
    ///   read stays in SwiftUI and the flag crosses in as a plain `Bool`.
    func exportSession(
        _ session: HermesSession,
        formatsAvailable: Bool,
        traceNoRedactAvailable: Bool = false,
        archivedTurnsInMarkdown: Bool = false
    ) {
        exportIncludesArchivedTurns = archivedTurnsInMarkdown
        pendingExportLineageIds = session.lineageIds.count > 1 ? session.lineageIds : []
        beginExportFlow(
            sessionId: session.id,
            suggestedBaseName: session.id,
            formatsAvailable: formatsAvailable,
            traceNoRedactAvailable: traceNoRedactAvailable
        )
    }

    func exportAll(formatsAvailable: Bool, traceNoRedactAvailable: Bool = false) {
        pendingExportLineageIds = []
        beginExportFlow(
            sessionId: nil,
            suggestedBaseName: "hermes-sessions",
            formatsAvailable: formatsAvailable,
            traceNoRedactAvailable: traceNoRedactAvailable
        )
    }

    /// Pre-0.18.1 hosts: identical to the original behavior — straight to the
    /// save panel, jsonl only, no picker sheet. v0.20+: opens the
    /// format/redact picker sheet; `confirmExportOptions()` continues once
    /// the user picks.
    private func beginExportFlow(
        sessionId: String?,
        suggestedBaseName: String,
        formatsAvailable: Bool,
        traceNoRedactAvailable: Bool
    ) {
        self.traceNoRedactAvailable = traceNoRedactAvailable
        guard formatsAvailable else {
            pendingExportIsAllSessions = false
            exportFormat = .jsonl
            exportRedact = false
            beginExport(sessionId: sessionId, suggestedName: "\(suggestedBaseName).jsonl", format: .jsonl, redact: false)
            return
        }
        pendingExportSessionId = sessionId
        pendingExportIsAllSessions = sessionId == nil
        pendingExportBaseName = suggestedBaseName
        exportFormat = .jsonl
        // `.jsonl`'s default, which is Hermes's: no `--redact` unless asked.
        exportRedact = false
        exportRedactBeforeTrace = false
        showExportOptionsSheet = true
    }

    /// The format picker changed: carry the per-format redaction DEFAULT, and
    /// the user's own non-trace choice, across the switch.
    ///
    /// Capability-independent on purpose. `hasSessionsExportNoRedact` shares
    /// its v0.18.1 floor with `--format trace`, so on any host that offers a
    /// trace export the opt-out exists: ON produces the host's own default
    /// (no flag) and OFF emits `--no-redact`.
    func exportFormatChanged(from old: SessionExportFormat, to new: SessionExportFormat) {
        guard old != new else { return }
        if new == .trace {
            exportRedactBeforeTrace = exportRedact
            exportRedact = true
        } else if old == .trace {
            exportRedact = exportRedactBeforeTrace
        }
    }

    /// Called from the picker sheet's "Export" button. Routes to the
    /// stdout-capture flow (jsonl/trace) or the real-output-path flow
    /// (html/md/qmd) depending on the chosen format.
    func confirmExportOptions() {
        showExportOptionsSheet = false
        let sessionId = pendingExportSessionId
        let baseName = pendingExportBaseName
        // Belt and braces: the picker can only offer what
        // `availableExportFormats` lists, so a format outside it means the
        // selection went stale — fall back to the format every host and
        // every flow supports rather than issuing an argv that lies.
        let format = availableExportFormats.contains(exportFormat) ? exportFormat : .jsonl
        pendingExportSessionId = nil
        pendingExportIsAllSessions = false
        beginExport(
            sessionId: sessionId,
            suggestedName: "\(baseName).\(format.fileExtension)",
            format: format,
            redact: exportRedact
        )
    }

    func cancelExportOptions() {
        showExportOptionsSheet = false
        pendingExportSessionId = nil
        pendingExportIsAllSessions = false
    }

    /// The export always lands on **this Mac**, whichever host Hermes runs
    /// on — that's what someone driving a Mac GUI is asking for.
    ///
    /// For `jsonl`/`trace` (stdout-capable formats), passing the panel's
    /// path to the CLI can't do that: on a remote context `hermes` executes
    /// on the far host over SSH, so a path from `NSSavePanel` (a path on
    /// this Mac) either fails against a directory the host doesn't have or
    /// dumps the file on the remote box where the user will never find it.
    /// Instead we ask the CLI for the payload on **stdout** (`sessions
    /// export -`) and write those bytes here. Same code path for local and
    /// remote — nothing to branch on.
    ///
    /// `html`/`md`/`qmd` don't support stdout at all (confirmed against the
    /// live v0.20 CLI — see `SessionExportFormat`'s doc comment), so those
    /// hand the CLI the chosen path directly; the file lands on whichever
    /// host `hermes` runs on, same as any other path-taking CLI flag on a
    /// remote context.
    private func beginExport(sessionId: String?, suggestedName: String, format: SessionExportFormat, redact: Bool) {
        if format.isDirectoryOutput {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Export")
            panel.message = String(localized: "Choose a folder for the \(format.displayName) export.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            performPathExport(to: url, sessionId: sessionId, format: format, redact: redact,
                              lineageIds: pendingExportLineageIds)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        // Formats like `jsonl` have no system-declared UTType. Minting a
        // dynamic one stops the panel rewriting the name to something else,
        // which the old `[.json]` list did to every jsonl export.
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if format.usesStdout {
            performExport(to: url, sessionId: sessionId, format: format, redact: redact,
                          lineageIds: pendingExportLineageIds)
        } else {
            performPathExport(to: url, sessionId: sessionId, format: format, redact: redact,
                              lineageIds: pendingExportLineageIds)
        }
    }

    /// Builds the `hermes sessions export` argv. `format`/`redact` default
    /// to the pre-0.20 shape (`jsonl`, no `--redact`) so every existing
    /// call site — and the argv-shape tests pinning them — keeps producing
    /// exactly the same arguments it always has.
    /// - Parameter traceNoRedactAvailable: `hasSessionsExportNoRedact`. Only
    ///   consulted for `trace`.
    ///
    /// **`trace` inverts the redaction flag.** `--redact` is read only by
    /// `_cmd_export`'s `_redact` closure, which the trace path never calls
    /// (`hermes_cli/sessions_cmd.py:306-309,379-440`): a trace redacts
    /// unconditionally and `--no-redact` is the opt-OUT — `redact_trace = not
    /// getattr(args, "no_redact", False)` at `:395`, with the docstring saying
    /// so at `:382-383`. So "Redact
    /// secrets" keeps one meaning across formats by emitting nothing for an
    /// ON toggle and `--no-redact` for an OFF one — and only above that
    /// flag's **v0.18.1** floor (`hermes_cli/main.py:13567` @ v2026.7.7), the
    /// same tag that introduced `--format trace` itself. Below it there is no
    /// trace format to opt out of.
    ///
    /// **`logicalLineage`** adds `--lineage logical` for md/qmd, so a rotated
    /// compression chain exports as ONE document spanning every segment
    /// (`export_session_lineage`, hermes_state_portability.py:290-296, via
    /// `_export_markdown`'s `include_lineage`, hermes_cli/sessions_cmd.py
    /// :474-479 @ v2026.9.24). The flag is `choices=["single","logical"]`,
    /// "md/qmd only" (hermes_cli/subcommands/sessions.py:95-96 @ v2026.9.24),
    /// and has the same v0.18.1 floor as `--format` itself
    /// (hermes_cli/main.py:13595-13600 @ v2026.7.7), so it is never emitted
    /// for a format a host doesn't have. Ignored for every other format.
    nonisolated static func exportArguments(
        output: String,
        sessionId: String?,
        format: SessionExportFormat = .jsonl,
        redact: Bool = false,
        traceNoRedactAvailable: Bool = false,
        logicalLineage: Bool = false
    ) -> [String] {
        var args = ["sessions", "export", output]
        if format != .jsonl { args += ["--format", format.cliValue] }
        if format == .trace {
            if !redact && traceNoRedactAvailable { args += ["--no-redact"] }
        } else if redact {
            args += ["--redact"]
        }
        if let sessionId { args += ["--session-id", sessionId] }
        if logicalLineage && format.isDirectoryOutput { args += ["--lineage", "logical"] }
        return args
    }

    /// How a format exports a rotated compression chain.
    nonisolated enum LineageExport: Equatable {
        /// One CLI run per segment, root first, payloads concatenated
        /// (`jsonl`: one session object per line, the same shape Hermes's
        /// own multi-session JSONL export writes, sessions_cmd.py:355-357).
        /// Each segment carries its live rows only: Hermes's JSONL export
        /// leaves out in-place-archived turns by design (it is the import
        /// format), so Markdown is the complete-history export.
        case perSegment
        /// One run with `--lineage logical` (md/qmd).
        case logicalFlag
        /// The CLI can only export one segment for this format (`trace` and
        /// `html` take a single `--session-id` and have no lineage option),
        /// so the banner says so instead of claiming the whole conversation.
        case latestSegmentOnly
    }

    nonisolated static func lineageExport(for format: SessionExportFormat) -> LineageExport {
        switch format {
        case .jsonl: return .perSegment
        case .markdown, .quarto: return .logicalFlag
        case .trace, .html: return .latestSegmentOnly
        }
    }

    /// Runs one `jsonl` export per segment of a compression chain and joins
    /// the payloads in lineage order. Stops at the first segment that fails
    /// or returns something that is not a JSONL payload and hands back THAT
    /// result, so `writeExport` reports the failure and nothing partial is
    /// written (charter C5).
    nonisolated static func exportLineageJSONL(
        segmentIds: [String],
        redact: Bool,
        run: ([String]) -> (stdout: Data, stderr: String, exitCode: Int32)
    ) -> (stdout: Data, stderr: String, exitCode: Int32) {
        var combined = Data()
        var stderr = ""
        for id in segmentIds {
            let result = run(exportArguments(output: "-", sessionId: id, format: .jsonl, redact: redact))
            guard result.exitCode == 0, payloadIsValid(result.stdout, format: .jsonl) else { return result }
            combined.append(result.stdout)
            if let last = result.stdout.last, last != 0x0A { combined.append(0x0A) }
            if !result.stderr.isEmpty { stderr += result.stderr }
        }
        return (combined, stderr, 0)
    }

    /// Suffix for a success banner when the exported session has turns an
    /// in-place compaction archived (`HermesDataService.hasArchivedTurns`)
    /// and the chosen format leaves them out, or nil when it includes them.
    ///
    /// JSONL and Trace always export the live rows only. Markdown, Quarto
    /// and HTML include the archived turns from v0.21.5
    /// (`hasSessionsExportArchivedTurns`); before that every format left
    /// them out, so the note names no remedy there. Markdown is a picker
    /// choice locally; a remote host gets the command to run there, since
    /// Scarf offers only the stdout formats remotely (charter C6).
    nonisolated static func archivedTurnsNote(
        format: SessionExportFormat,
        sessionId: String,
        isChain: Bool = false,
        markdownAvailable: Bool,
        markdownIncludesArchived: Bool
    ) -> String? {
        let everyFormat = String(localized: " This conversation has earlier turns that compaction archived; this Hermes version leaves them out of every export format.")
        if format.isDirectoryOutput || format == .html {
            return markdownIncludesArchived ? nil : everyFormat
        }
        guard markdownIncludesArchived else { return everyFormat }
        if markdownAvailable {
            return String(localized: " This conversation has earlier turns that compaction archived; Hermes leaves them out of \(format.displayName) exports. Export as Markdown for the full history.")
        }
        // A chain needs `--lineage logical` for the earlier segments too
        // (hermes_cli/subcommands/sessions.py:95-96 @ v2026.9.24).
        let command = "hermes sessions export <folder> --format md --session-id \(sessionId)"
            + (isChain ? " --lineage logical" : "")
        return String(localized: " This conversation has earlier turns that compaction archived; Hermes leaves them out of \(format.displayName) exports. Run \(command) on the host for the full history.")
    }

    /// Suffix for a success banner when `latestSegmentOnly` applied.
    ///
    /// Points at Markdown where it is offered (local hosts): it is the
    /// format that exports the whole conversation — every segment AND the
    /// turns in-place compaction archived, since Hermes's JSONL export
    /// omits those (`shown` is true only for `SAVE_TRANSCRIPT_FORMATS` =
    /// md/html, hermes_cli/session_export.py:212; sessions_cmd.py:335 @
    /// v2026.9.24). Remote hosts only offer JSONL and Trace, so there JSONL
    /// is the way to get every segment.
    nonisolated static func latestSegmentNote(
        segmentCount: Int, format: SessionExportFormat, markdownAvailable: Bool
    ) -> String {
        markdownAvailable
            ? String(localized: " Only the latest of this conversation's \(segmentCount) compressed segments is in the \(format.displayName) export; choose Markdown to export all of it.")
            : String(localized: " Only the latest of this conversation's \(segmentCount) compressed segments is in the \(format.displayName) export; choose JSONL to export every segment.")
    }

    /// Pipes the export out of the CLI and writes it to `url` on this Mac.
    /// Off the main actor because a remote export is an SSH round-trip
    /// streaming the whole payload — running it inline would block the main
    /// actor for its full duration.
    ///
    /// `lineageIds` (root first) marks a rotated compression chain: `jsonl`
    /// exports every segment, `trace` the latest one with a banner saying
    /// so (see `LineageExport`).
    func performExport(
        to url: URL,
        sessionId: String?,
        format: SessionExportFormat = .jsonl,
        redact: Bool = false,
        lineageIds: [String] = []
    ) {
        // `-` is the CLI's "write to stdout" sentinel — only valid for
        // stdout-capable formats (jsonl/trace).
        let args = Self.exportArguments(
            output: "-", sessionId: sessionId, format: format, redact: redact,
            traceNoRedactAvailable: traceNoRedactAvailable
        )
        let chain = sessionId != nil && lineageIds.count > 1 ? lineageIds : []
        let mode = Self.lineageExport(for: format)
        let markdownAvailable = !context.isRemote
        let runner = sessionExportRunner
        let ctx = context
        Task { [self] in
            // The CLI run and the file write block for the whole transfer:
            // a thread of their own, not a cooperative-pool one (C10).
            var outcome = await OffPool.run {
                let result = !chain.isEmpty && mode == .perSegment
                    ? Self.exportLineageJSONL(segmentIds: chain, redact: redact) { runner(ctx, $0) }
                    : runner(ctx, args)
                return Self.writeExport(result: result, to: url, format: format)
            }
            let plainSuccess = outcome.message
            if outcome.succeeded, !chain.isEmpty, mode == .latestSegmentOnly {
                outcome.message += Self.latestSegmentNote(
                    segmentCount: chain.count, format: format, markdownAvailable: markdownAvailable)
            }
            // Trace of a chain exports only the tip, so only the tip counts.
            if outcome.succeeded, let sessionId,
               await self.hasArchivedTurns(
                   chain.isEmpty ? [sessionId] : (mode == .latestSegmentOnly ? [sessionId] : chain)),
               let note = Self.archivedTurnsNote(
                   format: format, sessionId: sessionId, isChain: !chain.isEmpty,
                   markdownAvailable: markdownAvailable,
                   markdownIncludesArchived: self.exportIncludesArchivedTurns) {
                outcome.message += note
            }
            self.exportMessage = outcome.message
            // A banner carrying a caveat stays until the next export.
            guard outcome.succeeded, outcome.message == plainSuccess else { return }
            let banner = outcome.message
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                // Only clear our own banner — a newer export may
                // have replaced it while we slept.
                if self?.exportMessage == banner { self?.exportMessage = nil }
            }
        }
    }

    /// Real-output-path flow for `html`/`md`/`qmd`: the CLI writes the file
    /// (or directory of files) itself, so there's no stdout payload to pipe
    /// back — we just run the command and report the exit code.
    ///
    /// `lineageIds` (root first) marks a rotated compression chain: md/qmd
    /// export all of it with `--lineage logical`; `html` exports the latest
    /// segment with a banner saying so.
    func performPathExport(
        to url: URL,
        sessionId: String?,
        format: SessionExportFormat,
        redact: Bool,
        lineageIds: [String] = []
    ) {
        let chain = sessionId != nil && lineageIds.count > 1 ? lineageIds : []
        let mode = Self.lineageExport(for: format)
        let args = Self.exportArguments(
            output: url.path, sessionId: sessionId, format: format, redact: redact,
            traceNoRedactAvailable: traceNoRedactAvailable,
            logicalLineage: !chain.isEmpty && mode == .logicalFlag
        )
        let note = !chain.isEmpty && mode == .latestSegmentOnly
            ? Self.latestSegmentNote(segmentCount: chain.count, format: format, markdownAvailable: !context.isRemote) : ""
        let runner = sessionExportRunner
        let ctx = context
        Task { [self] in
            // A CLI run for the whole export: a thread of its own (C10).
            let result = await OffPool.run { runner(ctx, args) }
            let outcome = Self.pathExportOutcome(result: result)
            if outcome.succeeded {
                var banner = "Exported to \(url.path)" + note
                // md/qmd with `--lineage logical` cover the whole chain.
                if let sessionId,
                   await self.hasArchivedTurns(chain.isEmpty || mode == .latestSegmentOnly ? [sessionId] : chain),
                   let archived = Self.archivedTurnsNote(
                       format: format, sessionId: sessionId,
                       markdownAvailable: !ctx.isRemote,
                       markdownIncludesArchived: self.exportIncludesArchivedTurns) {
                    banner += archived
                }
                self.exportMessage = banner
                // A banner carrying a caveat stays until the next export.
                guard banner == "Exported to \(url.path)" else { return }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    if self?.exportMessage == banner { self?.exportMessage = nil }
                }
            } else {
                self.exportMessage = outcome.detail.map { "Export failed: \($0)" }
                    ?? "Export failed (exit \(result.exitCode))."
            }
        }
    }

    /// Verdict for a real-`--output`-path export (`html`/`md`/`qmd`).
    ///
    /// `hermes sessions export` never signals a refusal through its exit code:
    /// `_cmd_export` and every renderer under it are `-> None` and simply
    /// `print()` the reason to **stdout** — `_not_found` prints
    /// `Session '<id>' not found.` and returns 1, but its three callers
    /// (hermes_cli/sessions_cmd.py:319, :392, :488 at v2026.9.7) discard that
    /// and fall out of the function, which Python exits 0. Every success path,
    /// by contrast, ends in an `Exported …` summary (`_write_output`, :83,
    /// carrying :344 / :352 / :357, plus :424, :434, :480, :508) — stable
    /// since v2026.6.19 (main.py:12279), so this does not change what a
    /// pre-target host renders (charter C1, C5).
    nonisolated static func pathExportOutcome(
        result: (stdout: Data, stderr: String, exitCode: Int32)
    ) -> HermesCLIOutcome {
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        return HermesCLIVerdict.judge(
            output: stdout + "\n" + result.stderr,
            exitCode: result.exitCode,
            successMarkers: HermesCLIMarkers.sessionsExportSuccess,
            failureMarkers: HermesCLIMarkers.sessionsExportFailure,
            // `_write_output` prints the summary with a bare `print`
            // (sessions_cmd.py:83), i.e. at column 0.
            successAnchored: true
        )
    }

    /// Whether a stdout payload is plausibly the format we asked for.
    ///
    /// The `-` (stdout) path has no `Exported …` summary to judge by:
    /// `_write_output` (sessions_cmd.py:78-80) writes the payload and returns
    /// without printing one. What it CAN receive instead is a refusal, because
    /// those go to stdout too — so `Session 'abc' not found.` was written
    /// verbatim into the user's `.jsonl` file and reported as a successful
    /// export. Both stdout formats are JSON Lines
    /// (`_render_jsonl`, :355-357; `build_trace_jsonl` for `trace`, :417), so
    /// requiring the first non-empty line to parse as a JSON object rejects
    /// every refusal sentence while accepting any real payload.
    nonisolated static func payloadIsValid(_ data: Data, format: SessionExportFormat) -> Bool {
        guard format.usesStdout else { return true }
        // Only the FIRST LINE is decoded and checked. A refusal is the ENTIRE
        // stdout (the handler prints one line and returns), so the first line
        // settles it — while a real export can be hundreds of MB, and decoding
        // all of it to a String just to validate it would double the payload in
        // memory. Slicing at a newline BYTE also can't cut a UTF-8 codepoint.
        let window = data.prefix(64 * 1024)
        let isBlank: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
        let body = window.drop(while: isBlank)
        // An all-whitespace export is a real outcome (no sessions matched the
        // filters), not a refusal — rejecting it would be the regression.
        guard !body.isEmpty else { return true }
        let firstLine = body.firstIndex(of: 0x0A).map { body[..<$0] } ?? body
        let trimmed = Data(firstLine)
        // Both stdout formats are JSON Lines: `_render_jsonl`
        // (sessions_cmd.py:355-357) and `build_trace_jsonl` for `trace`
        // (:417). `JSONSerialization` without `.fragmentsAllowed` accepts only
        // an object or an array, so `Session 'abc' not found.` — and every
        // other refusal sentence — is rejected.
        return (try? JSONSerialization.jsonObject(with: trimmed)) != nil
    }

    /// Turns a CLI result into a written file + a user-facing banner.
    /// `nonisolated` so `performExport`'s detached task can do the disk
    /// write off the main actor.
    nonisolated static func writeExport(
        result: (stdout: Data, stderr: String, exitCode: Int32),
        to url: URL,
        format: SessionExportFormat = .jsonl
    ) -> (succeeded: Bool, message: String) {
        guard result.exitCode == 0 else {
            let detail = Self.errorSummary(from: result.stderr)
            return (false, detail.isEmpty
                ? "Export failed (exit \(result.exitCode))."
                : "Export failed: \(detail)")
        }
        // Never write a refusal into the user's file (charter C5).
        guard Self.payloadIsValid(result.stdout, format: format) else {
            let refusal = HermesCLIVerdict.judge(
                output: String(data: result.stdout, encoding: .utf8) ?? "",
                exitCode: 0,
                successMarkers: [],
                failureMarkers: HermesCLIMarkers.sessionsExportFailure
            )
            return (false, refusal.detail.map { "Export failed: \($0)" }
                ?? "Export failed: the CLI produced no \(format.displayName) payload.")
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
    /// on the main actor (gh#102).
    ///
    /// The nil default no longer stats inline. `confirmDelete()` was the one
    /// caller that passed nil, and "user-initiated" did not make a blocking
    /// SSH stat acceptable: it landed on the main actor immediately after a
    /// delete, i.e. exactly when the window had to repaint. It reuses the last
    /// size `load()` measured instead — which is also the more honest number,
    /// since deleting rows does not shrink a SQLite file until a VACUUM.
    private func computeStats(dbSize: String? = nil) {
        let totalMessages = sessions.reduce(0) { $0 + $1.messageCount }

        var platformCounts: [String: Int] = [:]
        for s in sessions {
            platformCounts[s.source, default: 0] += 1
        }
        let sorted = platformCounts.sorted { $0.value > $1.value }.map { (platform: $0.key, count: $0.value) }

        let fileSize: String
        if let dbSize {
            lastKnownDBSize = dbSize
            fileSize = dbSize
        } else {
            fileSize = lastKnownDBSize ?? "unknown"
        }

        storeStats = SessionStoreStats(
            totalSessions: sessions.count,
            totalMessages: totalMessages,
            databaseSize: fileSize,
            platformCounts: sorted
        )
    }

    /// Last `state.db` size measured off-main by `load()`. Reused by the
    /// stat-less `computeStats()` path.
    @ObservationIgnored private var lastKnownDBSize: String?

}
