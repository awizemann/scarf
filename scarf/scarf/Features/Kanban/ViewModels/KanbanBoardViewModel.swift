import Foundation
import Observation
import ScarfCore
import os

/// Drives the drag-and-drop Kanban board. Holds the column-grouped task
/// state, polls Hermes every 5s while foregrounded, and applies
/// optimistic updates around drag-drops so the UI feels instant.
///
/// **Optimistic merge.** When the user drops a card on a new column,
/// the VM records the in-flight task id + intended status, mutates the
/// local array immediately, and fires the corresponding CLI verb. Until
/// the next poll response confirms the new status, polled rows for
/// in-flight tasks are merged with the optimistic state — preventing a
/// stale poll from snapping the card back to its old column. On CLI
/// failure, the optimistic mutation is reverted and an error message
/// is surfaced.
@Observable
@MainActor
final class KanbanBoardViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "KanbanBoardViewModel")

    let context: ServerContext
    let service: KanbanService
    /// When non-nil, the board filters list/watch calls to this tenant
    /// and `New Task` pre-fills the tenant field. Used by per-project
    /// boards; global board leaves it nil.
    var tenantFilter: String?
    /// When non-nil, `New Task` pre-fills the workspace to
    /// `dir:<projectPath>` and locks it so project-scoped task
    /// creation always lands inside the project tree.
    let projectPath: String?

    init(
        context: ServerContext = .local,
        tenantFilter: String? = nil,
        projectPath: String? = nil,
        sessionScopeId: String? = nil
    ) {
        self.context = context
        self.service = KanbanService(context: context)
        self.tenantFilter = tenantFilter
        self.projectPath = projectPath
        self.sessionScopeId = sessionScopeId
    }

    // MARK: - State

    var tasks: [HermesKanbanTask] = []
    var stats: HermesKanbanStats = .empty
    var assignees: [HermesKanbanAssignee] = []
    var isLoading = false
    var lastError: String?
    var lastPollAt: Date?
    /// Active diagnostics keyed by task id, from ONE
    /// `hermes kanban diagnostics --json` per board load. Empty (and never
    /// fetched) unless `supportsDiagnostics` — the subcommand does not
    /// exist before v0.13 and Hermes routes an unknown kanban verb to the
    /// agent (charter C5).
    private(set) var diagnosticsByTask: [String: [HermesKanbanDiagnostic]] = [:]
    /// The connected host's capabilities, mirrored by the view from
    /// `HermesCapabilitiesStore`. Handed to `KanbanService.plan(for:caps:)`,
    /// which needs `hasKanbanReviewExits` (v0.20.1) to decide whether the
    /// Review column has its two exits — `review -> done` via
    /// `kanban complete` and `review -> upNext` via `kanban reopen-review`.
    ///
    /// The whole struct rather than another `supports…` Bool: the planner
    /// takes `HermesCapabilities`, a second gated arm would need a second
    /// mirror, and a mirror that can disagree with the store is the bug this
    /// avoids. `.empty` — every flag off — is the safe default, so a Preview
    /// or a host whose version probe has not landed keeps the pre-P56
    /// refusal rather than offering a drag the host declines.
    var capabilities: HermesCapabilities = .empty

    /// A drag onto **Running** the user has not confirmed yet — round-6
    /// decision 9.
    ///
    /// `hermes kanban dispatch` has NO per-task selector: the whole argv is
    /// `--dry-run` / `--max` / `--failure-limit` / `--json`
    /// (`hermes_cli/kanban_parser.py:346-353` @ `v2026.9.7`), so dropping
    /// ONE card on Running runs a BOARD-WIDE dispatcher pass that spawns
    /// workers for every assigned `ready` task in priority order — and may
    /// well start a different one first. The card moving under the cursor
    /// said "this task"; the verb means "all of them". Nothing runs until
    /// `confirmPendingDispatch()`.
    private(set) var pendingDispatch: PendingDispatch?

    /// The card a `.running` drop is waiting on, plus the inputs
    /// `attemptMove` will need when it is finally allowed to proceed.
    struct PendingDispatch: Equatable, Sendable {
        let taskId: String
        let taskTitle: String
        let source: KanbanBoardColumn
    }

    /// Set by the view from `HermesCapabilities.hasKanbanDiagnostics`.
    /// Defaults to `false` so a Preview / harness context never spawns the
    /// extra call. Turning it off drops any signals already on screen.
    var supportsDiagnostics: Bool = false {
        didSet {
            guard supportsDiagnostics != oldValue else { return }
            if !supportsDiagnostics {
                diagnosticsByTask = [:]
                lastDiagnosticsFetchAt = nil
            }
        }
    }
    private var lastDiagnosticsFetchAt: Date?
    /// Diagnostics are threshold-based signals measured in minutes and
    /// hours (`kanban_diagnostics.py` DEFAULT_CONFIG: 24h stale-blocked,
    /// 30min stranded-in-ready), so refetching them on every 5 s board
    /// tick would add a third process spawn per tick — on a possibly-remote
    /// host — for data that cannot have moved. Once per 30 s is ample.
    private static let diagnosticsMinInterval: TimeInterval = 30

    /// Filters above the board.
    var assigneeFilter: String?       // nil = all assignees
    var showArchived: Bool = false
    /// v0.15: server-side `--sort <key>` ordering. `nil` = Hermes default
    /// (priority). Setting it re-polls so the new order takes effect
    /// without waiting for the next 5s tick. Passed through verbatim
    /// into `currentFilter`.
    var sortKey: String? {
        didSet {
            guard sortKey != oldValue else { return }
            Task { await refresh() }
        }
    }

    /// When non-nil (seeded by the chat → Kanban hand-off), the board is
    /// chat-scoped: it filters server-side by this ACP session id via
    /// `hermes kanban list --session <id>`, so it shows exactly the tasks
    /// the originating chat produced. Precise — Hermes stamps the session
    /// id on every task created inside the agent loop (v0.15+). The board
    /// renders a scope pill when this is set (and a project tenant exists)
    /// so the user can widen to the full project view.
    let sessionScopeId: String?
    /// Whether the board is currently scoped to `sessionScopeId` (the
    /// "This chat" view). The scope pill flips this to show "All project
    /// tasks" (tenant-scoped). No-op when `sessionScopeId` is nil.
    var scopeToThisChat: Bool = true

    /// Optimistic in-flight status overrides keyed by task id (drag-drop
    /// column moves); the entry is dropped once the polled response
    /// confirms the new status.
    private var optimisticOverrides: [String: String] = [:]
    /// Tasks dropped into invalid columns produce a transient "denied"
    /// banner. Stored as an explicit error to support the Cmd-Z style
    /// undo we don't ship in v2.7.5 but want to leave room for.
    var transientNotice: String?

    // MARK: - Polling

    private var pollTask: Task<Void, Never>?

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            var interval = KanbanPollBackoff.boardBase
            while !Task.isCancelled {
                await self?.refresh()
                guard let self else { return }
                interval = KanbanPollBackoff.nextInterval(
                    current: interval, base: KanbanPollBackoff.boardBase,
                    succeeded: self.lastError == nil
                )
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Scope

    /// The list filter for the current scope. When the board is
    /// chat-scoped and the "This chat" toggle is on, filter precisely by
    /// the originating ACP session id (no tenant — `session_id` is
    /// globally unique, and this also catches tasks the agent created
    /// without tagging the project tenant). Otherwise fall back to the
    /// tenant-scoped filter (the "All project tasks" view and the plain
    /// global / per-project boards).
    private var currentFilter: KanbanListFilter {
        if let sessionScopeId, scopeToThisChat {
            return KanbanListFilter(
                assignee: assigneeFilter,
                session: sessionScopeId,
                includeArchived: showArchived,
                sort: sortKey
            )
        }
        return KanbanListFilter(
            assignee: assigneeFilter,
            tenant: tenantFilter,
            includeArchived: showArchived,
            sort: sortKey
        )
    }

    /// Flip the chat-scope toggle and re-poll immediately so the board
    /// reflects the new scope without waiting for the next 5s tick.
    func setScopeToThisChat(_ value: Bool) {
        guard scopeToThisChat != value else { return }
        scopeToThisChat = value
        Task { await refresh() }
    }

    // MARK: - Loading

    /// One-shot refresh. Polling drives the auto-refresh; this is
    /// exposed for explicit user-triggered reloads (e.g. the toolbar
    /// refresh button).
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let polled = try await service.list(currentFilter)
            mergePolledTasks(polled)
            lastPollAt = Date()
            lastError = nil

            // Stats refresh is best-effort — failure here doesn't
            // poison the board, just leaves the glance string stale.
            if let stats = try? await service.stats() {
                self.stats = stats
            }

            // One fleet-mode `kanban diagnostics --json` per board load —
            // the ONLY surface that emits diagnostics. Best-effort like
            // stats: a failure leaves the previous signals on screen
            // rather than blanking the board. The THROTTLE itself runs on the
            // main actor — `refreshDiagnosticsIfDue` is a method on this
            // `@MainActor` class; it is the `fetch` closure's body that is
            // actor-isolated and detached inside `KanbanService`
            // (`KanbanService.swift:25, 613`), which is what keeps C10. The
            // stamp is taken BEFORE the await, so a slow fetch cannot let a
            // second one in.
            await refreshDiagnosticsIfDue { [service] in try? await service.diagnostics() }
        } catch let err as KanbanError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Refresh the assignee picker. Cheap; called once on appear.
    func refreshAssignees() async {
        if let list = try? await service.assignees() {
            assignees = list
        }
    }

    // MARK: - Column projection

    /// Group tasks into the 5-column board layout. Triage column
    /// hides itself when empty; archived only appears when
    /// `showArchived` is on. Scope filtering (chat session vs. project
    /// tenant) happens server-side in `currentFilter`, so this just
    /// buckets + sorts the already-scoped rows.
    func tasks(in column: KanbanBoardColumn) -> [HermesKanbanTask] {
        let columnTasks = tasks.filter { effectiveColumn($0) == column }
        return sortColumn(columnTasks)
    }

    /// Visible columns for the current state. Triage, Scheduled, and
    /// Review hide when empty; archived hidden unless toggle is on.
    /// Scheduled sits before Up Next (pre-work); Review sits between
    /// Running and Blocked (post-work, pre-done).
    var visibleColumns: [KanbanBoardColumn] {
        var cols: [KanbanBoardColumn] = []
        if !tasks(in: .triage).isEmpty {
            cols.append(.triage)
        }
        if !tasks(in: .scheduled).isEmpty {
            cols.append(.scheduled)
        }
        cols.append(contentsOf: [.upNext, .running])
        if !tasks(in: .review).isEmpty {
            cols.append(.review)
        }
        cols.append(contentsOf: [.blocked, .done])
        if showArchived {
            cols.append(.archived)
        }
        return cols
    }

    // MARK: - Drag-drop

    /// Apply an optimistic move and fire the matching Hermes verbs.
    /// Returns immediately; the CLI calls run in the background.
    /// Inputs the drag layer must collect upstream:
    /// - `blockReason` when the destination is `.blocked`
    /// - `completeResult` when the destination is `.done`
    /// - `confirmed`: the caller has already shown the board-wide dispatch
    ///   confirmation for this drop. Only `confirmPendingDispatch()` passes
    ///   `true`; every UI entry point leaves it at `false` so a drop onto
    ///   Running always asks.
    func attemptMove(
        taskId: String,
        to destination: KanbanBoardColumn,
        blockReason: String? = nil,
        completeResult: String? = nil,
        confirmed: Bool = false
    ) {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return }
        let source = effectiveColumn(task)
        if source == destination { return }

        // The plan is computed FIRST, and it is pure — no CLI, no I/O, just
        // `KanbanService.plan`'s table (P60). Parking the confirmation ahead
        // of it asked the user to approve a board-wide dispatch for a
        // transition the planner then REFUSED: Done, Triage, Review without
        // `hasKanbanReviewExits`, and Archived all throw on the way to
        // Running, so the sheet appeared, the user said yes, and the move
        // failed afterwards with a banner.
        let plan: KanbanTransitionPlan
        do {
            plan = try KanbanService.plan(
                for: KanbanTransition(from: source, to: destination),
                caps: capabilities
            )
        } catch let err as KanbanError {
            // AX M3: a refused transition is a FAILURE, so it belongs in
            // `lastError` — the dedicated warning-styled banner — not in
            // `transientNotice`, whose blue info glyph reads as "here's a
            // tip" over "your card did not move".
            lastError = err.errorDescription
            return
        } catch {
            lastError = error.localizedDescription
            return
        }

        // Round-6 decision 9. `.dispatch` is board-wide (see
        // `PendingDispatch`), so any plan that contains it needs the
        // confirmation — which is the PLAN's property, not the destination's.
        // Keying on `destination == .running` was the same claim by proxy and
        // it was wrong in both directions at once: it asked on a refused
        // transition that never dispatches, and it is the plan that decides
        // (Blocked → Running is `[.unblock, .dispatch]`, and a future route
        // into Running without a dispatch step would not need asking).
        //
        // Parked BEFORE the optimistic mutation, so a cancelled drop leaves
        // the card exactly where the user picked it up rather than sitting in
        // Running until the next poll disagrees.
        if !confirmed, plan.steps.contains(.dispatch) {
            pendingDispatch = PendingDispatch(
                taskId: taskId, taskTitle: task.title, source: source)
            return
        }

        // Optimistic mutation — flip the local row's status to a
        // value within the destination column's range. We pick a
        // representative status per column.
        optimisticOverrides[taskId] = optimisticStatus(for: destination)

        let svc = service
        Task {
            do {
                for step in plan.steps {
                    try await applyStep(step, taskId: taskId, blockReason: blockReason, completeResult: completeResult, service: svc)
                }
                // Refresh once on success so the polled state catches up
                // without waiting for the 5s tick.
                await refresh()
            } catch let err as KanbanError {
                clearStatusOverride(for: taskId)
                lastError = err.errorDescription
                logger.warning("kanban move failed: \(err.errorDescription ?? "", privacy: .public)")
            } catch {
                clearStatusOverride(for: taskId)
                lastError = error.localizedDescription
            }
        }
    }

    /// Run the parked drop (round-6 decision 9). The ONLY caller that passes
    /// `confirmed: true`.
    func confirmPendingDispatch() {
        guard let pending = pendingDispatch else { return }
        pendingDispatch = nil
        attemptMove(taskId: pending.taskId, to: .running, confirmed: true)
    }

    /// Drop the parked move. Nothing was mutated, optimistically or
    /// otherwise, so there is nothing to roll back.
    func cancelPendingDispatch() {
        pendingDispatch = nil
    }

    /// Archive via context menu (not drag).
    func archive(taskId: String) {
        Task {
            do {
                try await service.archive(taskIds: [taskId])
                await refresh()
            } catch let err as KanbanError {
                lastError = err.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - v0.15 lifecycle actions (context menu)

    /// Promote a `todo`/`triage`/`blocked` task to `ready` so the
    /// dispatcher can pick it up — `hermes kanban promote`. Optimistically
    /// flip the card into Up Next; the poll confirms `ready` (which maps
    /// to the Up Next column).
    func promote(_ taskId: String) {
        optimisticOverrides[taskId] = optimisticStatus(for: .upNext)
        Task {
            do {
                try await service.promote(taskIds: [taskId], reason: nil, force: false, dryRun: false)
                await refresh()
            } catch let err as KanbanError {
                clearStatusOverride(for: taskId)
                lastError = err.errorDescription
            } catch {
                clearStatusOverride(for: taskId)
                lastError = error.localizedDescription
            }
        }
    }

    /// Park a `todo`/`ready` task in `scheduled` — `hermes kanban
    /// schedule`. Optimistically flip into the Scheduled column.
    func schedule(_ taskId: String) {
        optimisticOverrides[taskId] = optimisticStatus(for: .scheduled)
        Task {
            do {
                try await service.schedule(taskIds: [taskId], reason: nil)
                await refresh()
            } catch let err as KanbanError {
                clearStatusOverride(for: taskId)
                lastError = err.errorDescription
            } catch {
                clearStatusOverride(for: taskId)
                lastError = error.localizedDescription
            }
        }
    }

    /// Permanently delete an already-archived task — `hermes kanban
    /// archive --rm`. Destructive; no optimistic override since the card
    /// simply vanishes on the next poll.
    func purge(_ taskId: String) {
        Task {
            do {
                try await service.purge(taskIds: [taskId])
                await refresh()
            } catch let err as KanbanError {
                lastError = err.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Reassign a task to a different profile (or clear the assignee
    /// when `profile` is nil/empty). Fires a dispatcher pass after a
    /// successful assignment so the task transitions promptly when
    /// the gateway dispatcher's own cycle is slow. Best-effort:
    /// failures surface in `lastError`. Used by the inspector's
    /// inline assignee picker.
    func reassignTask(taskId: String, to profile: String?) {
        Task {
            do {
                let normalized = (profile?.isEmpty ?? true) ? nil : profile
                try await service.assign(taskId: taskId, profile: normalized)
                if normalized != nil {
                    // Best-effort nudge.
                    _ = try? await service.dispatch(maxTasks: nil, dryRun: false)
                }
                await refresh()
            } catch let err as KanbanError {
                lastError = err.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Append a comment from the inspector pane.
    func comment(taskId: String, text: String) {
        Task {
            do {
                try await service.comment(taskId: taskId, text: text, author: nil)
                await refresh()
            } catch let err as KanbanError {
                lastError = err.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Create a new task — wired up to the New Task sheet.
    /// Fires a dispatcher pass immediately after successful creation
    /// so an assigned task transitions from `ready` → `running`
    /// promptly without waiting for whatever cadence the gateway's
    /// internal dispatcher loop runs at.
    func createTask(_ request: KanbanCreateRequest) async throws -> HermesKanbanTask {
        let task = try await service.create(request)
        if let assignee = task.assignee, !assignee.isEmpty {
            // Best-effort: failure here is non-fatal — the task still
            // exists, the user just won't see it transition to running
            // until the next gateway dispatcher tick.
            _ = try? await service.dispatch(maxTasks: nil, dryRun: false)
        }
        // A manually-created task isn't stamped with an ACP session_id
        // (only the agent loop sets HERMES_SESSION_ID), so it won't appear
        // under the "This chat" session filter. Tell the user where it went
        // rather than letting it silently vanish on the next poll.
        if sessionScopeId != nil, scopeToThisChat {
            let wide = tenantFilter != nil ? "All project tasks" : "All tasks"
            transientNotice = "Task created. It isn't chat-scoped — switch to \"\(wide)\" to see it."
        }
        await refresh()
        return task
    }

    // MARK: - Private helpers

    private func mergePolledTasks(_ polled: [HermesKanbanTask]) {
        // Filter polled rows to the requested tenant if one is set —
        // belt-and-suspenders against Hermes versions that ignore
        // an empty `--tenant ""` argument.
        //
        // BUT skip this when the board is session-scoped ("This chat"):
        // `currentFilter` then queries `--session <id>` with NO tenant,
        // and the whole point is to surface every task the chat produced
        // — including ones the agent created without tagging the project
        // tenant. Applying the tenant filter here would drop exactly those
        // and defeat session scoping.
        let isSessionScoped = (sessionScopeId != nil && scopeToThisChat)
        let filtered: [HermesKanbanTask]
        if let tenant = tenantFilter, !tenant.isEmpty, !isSessionScoped {
            filtered = polled.filter { $0.tenant == tenant }
        } else {
            filtered = polled
        }
        // Drop optimistic overrides for tasks Hermes confirmed — and for
        // tasks that left the polled set entirely (archived, deleted, or
        // filtered out).
        for (id, optStatus) in optimisticOverrides {
            guard let row = filtered.first(where: { $0.id == id }) else {
                optimisticOverrides.removeValue(forKey: id)
                continue
            }
            if columnFromStatus(optStatus) == columnFromStatus(row.status) {
                optimisticOverrides.removeValue(forKey: id)
            }
        }
        tasks = filtered
    }

    private func clearStatusOverride(for taskId: String) {
        optimisticOverrides.removeValue(forKey: taskId)
    }

    /// The throttled diagnostics fetch.
    ///
    /// The stamp advances on FAILURE too. It used to be set only inside the
    /// success branch, so a host where `kanban diagnostics --json` fails (a
    /// wedged ssh, a broken tenant) never satisfied the throttle again and
    /// respawned the command on every 5 s board tick — the exact spawn storm
    /// charter C10 exists to prevent. The previous signals still stay on
    /// screen on failure; only the retry cadence is capped.
    ///
    /// `fetch` is a parameter rather than a direct `service.diagnostics()`
    /// call so the throttle is testable without a live host: the invariant
    /// being pinned is "at most one attempt per interval, success or not".
    func refreshDiagnosticsIfDue(
        _ fetch: () async -> [String: [HermesKanbanDiagnostic]]?
    ) async {
        guard supportsDiagnostics, shouldRefetchDiagnostics else { return }
        lastDiagnosticsFetchAt = Date()
        if let diags = await fetch() {
            diagnosticsByTask = diags
        }
    }

    private var shouldRefetchDiagnostics: Bool {
        guard let last = lastDiagnosticsFetchAt else { return true }
        return Date().timeIntervalSince(last) >= Self.diagnosticsMinInterval
    }

    /// Active diagnostics for one task — `[]` when the board is healthy,
    /// when Hermes predates the `diagnostics` subcommand, or before the
    /// first successful fetch.
    func diagnostics(for task: HermesKanbanTask) -> [HermesKanbanDiagnostic] {
        diagnosticsByTask[task.id] ?? []
    }

    /// Return the effective board column for a task — the optimistic
    /// override wins if one is in flight; otherwise the polled status.
    private func effectiveColumn(_ task: HermesKanbanTask) -> KanbanBoardColumn {
        if let overrideStatus = optimisticOverrides[task.id] {
            return columnFromStatus(overrideStatus)
        }
        return columnFromStatus(task.status)
    }

    private nonisolated func columnFromStatus(_ status: String) -> KanbanBoardColumn {
        KanbanStatus.from(status).boardColumn
    }

    private nonisolated func optimisticStatus(for column: KanbanBoardColumn) -> String {
        switch column {
        case .triage:    return "triage"
        case .scheduled: return "scheduled"
        case .upNext:    return "todo"
        case .running:   return "running"
        case .review:    return "review"
        case .blocked:   return "blocked"
        case .done:      return "done"
        case .archived:  return "archived"
        }
    }

    /// Within-column ordering. Hermes has no `position` field, so we
    /// derive ordering from `priority` (descending) then `created_at`
    /// (descending). This matches the dispatcher's actual run order
    /// — what shows up first is what runs next.
    private nonisolated func sortColumn(_ rows: [HermesKanbanTask]) -> [HermesKanbanTask] {
        rows.sorted { lhs, rhs in
            let lp = lhs.priority ?? 0
            let rp = rhs.priority ?? 0
            if lp != rp { return lp > rp }
            return (lhs.createdAt ?? "") > (rhs.createdAt ?? "")
        }
    }

    private func applyStep(
        _ step: KanbanTransitionStep,
        taskId: String,
        blockReason: String?,
        completeResult: String?,
        service: KanbanService
    ) async throws {
        switch step {
        case .dispatch:
            // The dispatcher silently skips tasks without an assignee.
            // Refusing here, with a user-actionable message, beats
            // letting Hermes lock the task into a 15-minute zombie
            // state until stale_lock reclaim kicks in.
            if let task = tasks.first(where: { $0.id == taskId }),
               (task.assignee?.isEmpty ?? true) {
                throw KanbanError.forbiddenTransition(
                    from: "Up Next",
                    to: "Running",
                    reason: "This task has no assignee. Hermes's dispatcher only spawns workers for assigned tasks. Open the task and assign a profile, or recreate it with an assignee."
                )
            }
            _ = try await service.dispatch(maxTasks: nil, dryRun: false)
        case .unblock:
            try await service.unblock(taskIds: [taskId])
        case .reopenReview:
            // `review -> ready|todo` (`reopen_review_task`,
            // `hermes_cli/kanban_db.py:3295-3328` @ `v2026.9.7`). No reason
            // is sent from a drag: `--reason` is recorded as a CHANGES
            // REQUESTED comment on the task (`_cmd_reopen_review`,
            // `hermes_cli/kanban.py:1000-1003`), and inventing one on the
            // user's behalf would put words in a review they did not write.
            // The inspector's Comment action is where a reason belongs.
            try await service.reopenReview(taskIds: [taskId], reason: nil)
        case .block(let reasonRequired):
            let reason = (blockReason?.isEmpty ?? true) ? nil : blockReason
            if reasonRequired && reason == nil {
                throw KanbanError.forbiddenTransition(
                    from: "—",
                    to: "Blocked",
                    reason: "A reason is required to mark a task blocked."
                )
            }
            try await service.block(taskId: taskId, reason: reason)
        case .complete(let resultRequired):
            let result = (completeResult?.isEmpty ?? true) ? nil : completeResult
            if resultRequired && result == nil {
                throw KanbanError.forbiddenTransition(
                    from: "—",
                    to: "Done",
                    reason: "A result summary is required to complete this task."
                )
            }
            try await service.complete(taskIds: [taskId], result: result, summary: nil, metadataJSON: nil)
        case .archive:
            try await service.archive(taskIds: [taskId])
        }
    }
}
