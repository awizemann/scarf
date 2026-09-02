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

    /// Optimistic in-flight overrides keyed by task id; cleared when the
    /// polled response confirms the new state.
    /// - Status side: drag-drop column moves.
    /// - Hallucination-gate side (v0.13): Verify clicks flip `pending` →
    ///   `verified` locally so the banner disappears immediately.
    /// The override entry is dropped from the dictionary entirely once
    /// both sides are nil (no override needed).
    private struct OptimisticOverride {
        var status: String?
        var hallucinationGate: KanbanHallucinationGate?

        var isEmpty: Bool {
            status == nil && hallucinationGate == nil
        }
    }
    private var optimisticOverrides: [String: OptimisticOverride] = [:]
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
    func attemptMove(
        taskId: String,
        to destination: KanbanBoardColumn,
        blockReason: String? = nil,
        completeResult: String? = nil
    ) {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return }
        let source = effectiveColumn(task)
        if source == destination { return }

        let plan: KanbanTransitionPlan
        do {
            plan = try KanbanService.plan(
                for: KanbanTransition(from: source, to: destination)
            )
        } catch let err as KanbanError {
            transientNotice = err.errorDescription
            return
        } catch {
            transientNotice = error.localizedDescription
            return
        }

        // Optimistic mutation — flip the local row's status to a
        // value within the destination column's range. We pick a
        // representative status per column.
        let optimisticStatusValue = optimisticStatus(for: destination)
        var override = optimisticOverrides[taskId] ?? OptimisticOverride()
        override.status = optimisticStatusValue
        optimisticOverrides[taskId] = override

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
        var override = optimisticOverrides[taskId] ?? OptimisticOverride()
        override.status = optimisticStatus(for: .upNext)
        optimisticOverrides[taskId] = override
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
        var override = optimisticOverrides[taskId] ?? OptimisticOverride()
        override.status = optimisticStatus(for: .scheduled)
        optimisticOverrides[taskId] = override
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

    // MARK: - Hallucination gate (v0.13)

    // NOTE: there is no "Verify" action — Hermes has no `kanban verify`
    // verb (re-verified against v0.16). The gate's only user-driven
    // action is Reject (below), which archives the card with an audit
    // comment. The polling loop still reads back a `verified` gate state
    // if Hermes flips it server-side.

    /// User rejected the worker-created card as a hallucinated reference.
    /// Routes through `comment` + `archive` per `KanbanService.rejectHallucinated`
    /// so there's an audit trail for why the card disappeared.
    func rejectHallucination(taskId: String) {
        Task {
            do {
                try await service.rejectHallucinated(taskId: taskId)
                await refresh()
            } catch let err as KanbanError {
                lastError = err.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
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
        let presentIds = Set(filtered.map(\.id))
        // Drop optimistic overrides for tasks Hermes confirmed. Two
        // independent sides — clear them separately so a Verify click
        // still in-flight survives a status-side poll confirmation, and
        // vice versa.
        for (id, override) in optimisticOverrides {
            guard let row = filtered.first(where: { $0.id == id }) else {
                if !presentIds.contains(id) {
                    // Task no longer in the polled set (archived, deleted,
                    // or filtered out). Drop the override entirely.
                    optimisticOverrides.removeValue(forKey: id)
                }
                continue
            }
            // Status side — optimistic move confirmed.
            if let optStatus = override.status,
               columnFromStatus(optStatus) == columnFromStatus(row.status) {
                optimisticOverrides[id]?.status = nil
            }
            // Hallucination-gate side — optimistic verify/reject confirmed.
            if let optGate = override.hallucinationGate,
               KanbanHallucinationGate.from(row.hallucinationGateStatus) == optGate {
                optimisticOverrides[id]?.hallucinationGate = nil
            }
            if optimisticOverrides[id]?.isEmpty ?? true {
                optimisticOverrides.removeValue(forKey: id)
            }
        }
        tasks = filtered
    }

    /// Drop the status side of a task's override (preserving any
    /// in-flight hallucination-gate optimistic state).
    private func clearStatusOverride(for taskId: String) {
        guard var override = optimisticOverrides[taskId] else { return }
        override.status = nil
        if override.isEmpty {
            optimisticOverrides.removeValue(forKey: taskId)
        } else {
            optimisticOverrides[taskId] = override
        }
    }

    /// Effective hallucination gate for a task — the optimistic override
    /// wins if one is in flight; otherwise the polled value. View code
    /// reads through this so the banner / dim state matches the moment-
    /// after-click experience.
    func effectiveHallucinationGate(_ task: HermesKanbanTask) -> KanbanHallucinationGate? {
        if let override = optimisticOverrides[task.id]?.hallucinationGate {
            return override
        }
        return KanbanHallucinationGate.from(task.hallucinationGateStatus)
    }

    /// Return the effective board column for a task — the optimistic
    /// override wins if one is in flight; otherwise the polled status.
    private func effectiveColumn(_ task: HermesKanbanTask) -> KanbanBoardColumn {
        if let overrideStatus = optimisticOverrides[task.id]?.status {
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
