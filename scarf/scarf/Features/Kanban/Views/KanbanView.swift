import SwiftUI
import ScarfCore
import ScarfDesign

/// Top-level Mac Kanban surface — toggles between the v2.7.5 board view
/// (drag-and-drop, full read/write) and the legacy v2.6 read-only list.
/// Kept as a single AppCoordinator route so users can switch between
/// presentations without leaving the route, and so accessibility users
/// (or anyone with a narrow window) keep a usable list fallback.
///
/// Capability-gated upstream: `SidebarView` only lists this route when
/// `HermesCapabilities.hasKanban` is true.
struct KanbanView: View {
    let context: ServerContext
    @Environment(AppCoordinator.self) private var coordinator

    @AppStorage("kanban.viewMode") private var rawMode: String = ViewMode.board.rawValue

    /// Snapshot of the chat → Kanban hand-off, copied out of the
    /// coordinator on first render and held locally so resetting the
    /// coordinator slot doesn't tear down the in-flight `KanbanBoardView`.
    /// Nil means a plain sidebar/route navigation; the board renders
    /// without any pre-applied filter.
    @State private var consumedHandoff: KanbanHandoff?

    enum ViewMode: String {
        case board
        case list
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            ScarfDivider()
            switch ViewMode(rawValue: rawMode) ?? .board {
            case .board:
                KanbanBoardView(
                    context: context,
                    tenantFilter: consumedHandoff?.tenant,
                    projectPath: consumedHandoff?.projectPath,
                    projectName: consumedHandoff?.projectName,
                    sessionScopeId: consumedHandoff?.sessionId
                )
                // Re-build the board view when a fresh hand-off lands so
                // the new tenant + timestamp take effect even if the
                // route was already on Kanban. Keying by `id` is enough —
                // the AppCoordinator slot is a struct so equality maps
                // cleanly.
                .id(boardIdentity)
            case .list:
                KanbanListView(
                    context: context,
                    tenantFilter: consumedHandoff?.tenant,
                    sessionScopeId: consumedHandoff?.sessionId
                )
                // Same identity key as the board: a fresh hand-off has to
                // rebuild the list too, or the old scope's view model
                // (and its poll loop) keeps running under the new route.
                .id(boardIdentity)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .task(id: handoffIdentity) {
            // Drain pending hand-off if any. Using `.task(id:)` instead
            // of `.onAppear` so a coordinator update mid-session
            // (chat → kanban without leaving the route) re-triggers.
            if let pending = coordinator.pendingKanbanHandoff {
                consumedHandoff = pending
                coordinator.pendingKanbanHandoff = nil
            }
        }
    }

    /// Identity for the `.task(id:)` modifier — when the coordinator
    /// slot flips from nil → handoff or handoff-A → handoff-B, the
    /// drain task re-runs.
    private var handoffIdentity: String {
        guard let pending = coordinator.pendingKanbanHandoff else {
            return "none"
        }
        return [
            pending.tenant ?? "",
            pending.projectPath ?? "",
            pending.sessionId
        ].joined(separator: "|")
    }

    private var boardIdentity: String {
        guard let handoff = consumedHandoff else {
            return "global"
        }
        return [
            handoff.tenant ?? "",
            handoff.projectPath ?? "",
            handoff.sessionId
        ].joined(separator: "|")
    }

    private var modeBar: some View {
        HStack(spacing: ScarfSpace.s2) {
            Spacer()
            Picker("View", selection: $rawMode) {
                Text("Board").tag(ViewMode.board.rawValue)
                Text("List").tag(ViewMode.list.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
    }
}
