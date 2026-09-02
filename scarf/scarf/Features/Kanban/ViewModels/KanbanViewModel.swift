import Foundation
import Observation
import ScarfCore
import os

/// Read-only view of `hermes kanban list --json`. Multi-profile
/// collaboration was reverted upstream while the design is reworked,
/// so v2.6 ships read-only on Mac and defers create/claim/dispatch UI
/// to v2.7+.
///
/// Polls every 5s while foregrounded so dispatcher progress is visible
/// without manual refresh; the polling task is suspended when the view
/// disappears so background windows don't keep hammering SSH.
@Observable
@MainActor
final class KanbanViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "KanbanViewModel")

    let context: ServerContext
    private let service: KanbanService

    /// Tenant scope carried in from the route's hand-off, mirroring the
    /// board's `tenantFilter`. `nil` = every tenant.
    let tenantFilter: String?
    /// Originating ACP chat session, mirroring the board's
    /// `sessionScopeId`. When set, the list is chat-scoped exactly like
    /// the board's "This chat" view (`--session <id>`; session ids are
    /// globally unique, so it stands alone without the tenant).
    let sessionScopeId: String?

    init(
        context: ServerContext = .local,
        tenantFilter: String? = nil,
        sessionScopeId: String? = nil
    ) {
        self.context = context
        self.service = KanbanService(context: context)
        self.tenantFilter = tenantFilter
        self.sessionScopeId = sessionScopeId
    }

    var tasks: [HermesKanbanTask] = []
    var isLoading = false
    var lastError: String?
    var statusFilter: StatusFilter = .all

    /// Subset Hermes accepts on `--status`. `.all` skips the flag.
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all
        case triage
        case todo
        case ready
        case running
        case blocked
        case done
        case archived

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            default:   return rawValue.capitalized
            }
        }

        /// `nil` for `.all` (the flag is omitted entirely).
        var kanbanStatus: KanbanStatus? {
            self == .all ? nil : KanbanStatus(rawValue: rawValue)
        }
    }

    private var pollTask: Task<Void, Never>?

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            var interval = KanbanPollBackoff.boardBase
            while !Task.isCancelled {
                await self?.load()
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

    /// The scope + status filter for the current list.
    ///
    /// **Scope parity with board mode.** The list used to hand-roll
    /// `["kanban", "list", "--json"]` through `HermesFileService`, so a
    /// per-project or chat-scoped route silently showed EVERY task on
    /// the host the moment the user flipped the segmented control from
    /// Board to List. Scope now rides through `KanbanService` /
    /// `KanbanListFilter`, the same path the board uses.
    private var currentFilter: KanbanListFilter {
        KanbanListFilter(
            status: statusFilter.kanbanStatus,
            tenant: tenantFilter,
            session: sessionScopeId,
            // `--status archived` alone is not enough: `list_tasks`
            // gates archived rows on `include_archived`.
            includeArchived: statusFilter == .archived
        )
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tasks = try await service.list(currentFilter)
            lastError = nil
        } catch let err as KanbanError {
            logger.warning("kanban list failed: \(err.errorDescription ?? "", privacy: .public)")
            lastError = err.errorDescription
            tasks = []
        } catch {
            logger.warning("kanban list failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            tasks = []
        }
    }
}
