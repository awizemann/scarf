import Foundation
import ScarfCore

@Observable
final class DashboardViewModel {
    let context: ServerContext
    private let dataService: HermesDataService
    private let fileService: HermesFileService

    /// Single in-flight load handle. The `.onChange(fileWatcher.lastChangeDate)`
    /// observer in `DashboardView` plus `.task` on first appear can both
    /// fire concurrent loads — and on v0.13 hosts the FSEvents tick rate
    /// during gateway activity used to be high enough that 5+ loads
    /// stacked inside 200 ms (HermesFileWatcher's coalesce window now
    /// handles that, but defending here keeps the behaviour deterministic
    /// on any future watcher chattiness). When a load is in flight,
    /// subsequent triggers no-op; the in-flight load already has a
    /// recent-enough snapshot for the user.
    @ObservationIgnored
    private var inFlightLoad: Task<Void, Never>?

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
    /// Per-model token/cost breakdown (Hermes v0.20+). Empty on older
    /// hosts whose state.db lacks the `session_model_usage` table —
    /// the Dashboard section hides itself in that case.
    var modelUsage: [HermesDataService.ModelUsageStat] = []
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

    /// Projects with their own `<project>/.hermes/` directory shadowing
    /// the global Hermes home. Hermes' CLI uses the closest `.hermes/`
    /// when invoked from inside such a project, which silently routes
    /// `hermes auth add` / setup writes into the project-local copy
    /// instead of `~/.hermes/`. Surfaced as a yellow banner so users
    /// can consolidate before more state drifts.
    var hermesShadows: [ProjectHermesShadowDetector.Shadow] = []

    func load() async {
        // Coalesce overlapping triggers: the `.task` first-appear and the
        // `.onChange(fileWatcher.lastChangeDate)` observer can both fire
        // a load in the same tick. Without this guard a Hermes v0.13
        // host's WAL-write storm walked over the previous load
        // mid-snapshot (see `HermesFileWatcher.scheduleCoalescedTick`).
        // If a load is already running, await its completion and return
        // — the caller already has a fresh snapshot by the time `await`
        // returns.
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

    /// Start of the window the stat cards are labelled with ("Last 7
    /// days" in `DashboardView`). Change both together — the label is the
    /// contract, and shipping it over an unbounded aggregate is the bug
    /// this replaced.
    static func statsWindowStart(now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
    }

    private func loadImpl() async {
        isLoading = true
        // `refresh()` is a no-op for the streaming remote backend (every
        // query is already fresh) and — after gh#102 — a no-op for the
        // local backend too when the SQLite handle is already open.
        // SQLite read-only sees Hermes' WAL writes transparently, so
        // there's nothing to reopen each tick. The four data-service
        // queries below are batched through `dashboardSnapshot` so a
        // remote load is one SSH round-trip instead of four.
        let opened = await dataService.refresh()
        var collectedErrors: [String] = []
        /// A failed state.db read is surfaced on LOCAL contexts too,
        /// unlike the config/gateway/pgrep misses below: an empty
        /// Dashboard is the same pixels as a brand-new install, so
        /// swallowing this one leaves the user reading zeros as fact.
        var snapshotError: String?
        if opened {
            let snapshot = await dataService.dashboardSnapshot(
                sessionLimit: 5,
                previewLimit: 5,
                toolCallLimit: 8,
                statsSince: Self.statsWindowStart()
            )
            snapshotError = snapshot.queryError
            stats = snapshot.stats
            recentSessions = snapshot.recentSessions
            sessionPreviews = snapshot.sessionPreviews
            modelUsage = snapshot.modelUsage
            recentActivity = snapshot.recentToolCalls.flatMap { msg in
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
            // Keep the handle open across loads. Closing here forced the
            // next `refresh()` to reopen the 285 MB state.db (gh#102),
            // which on a host with a multi-hundred-MB uncheckpointed WAL
            // is exactly the cost we're trying to avoid running on every
            // FSEvent-coalesced tick. Backend `deinit` releases the
            // handle when the ViewModel is deallocated.
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
        let surfaced = (snapshotError.map { ["state.db — \($0)"] } ?? [])
            + (context.isRemote ? collectedErrors : [])
        lastReadError = surfaced.isEmpty ? nil : surfaced.joined(separator: "\n")

        // Probe for projects with shadow `.hermes/` directories. Read-only
        // — we just stat each registered project's path. Detached so the
        // SSH round-trips don't block the load completion.
        let ctx = context
        let detector = ProjectHermesShadowDetector(context: ctx)
        let projects = await Task.detached {
            ProjectDashboardService(context: ctx).loadRegistry().projects
        }.value
        hermesShadows = await detector.detect(in: projects)

        isLoading = false
    }
}
