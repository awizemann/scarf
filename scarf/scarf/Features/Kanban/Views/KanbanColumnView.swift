import SwiftUI
import ScarfCore
import ScarfDesign

/// One column of the Kanban board. Owns its drop target, header chrome,
/// scroll viewport, and per-column empty state. Cards are rendered via
/// `KanbanCardView`.
struct KanbanColumnView: View {
    let column: KanbanBoardColumn
    let tasks: [HermesKanbanTask]
    /// Live indicator for the Running column — true when polling has
    /// ticked within the last 6 seconds.
    let isLive: Bool
    /// "ready: N →" pill on the To Do column.
    let readyPillCount: Int
    let onTaskTap: (HermesKanbanTask) -> Void
    let onCreate: () -> Void
    let onDrop: (KanbanTaskRef) -> Void
    let canCreate: Bool
    /// True when the connected Hermes is on v0.13+. Forwarded to each
    /// `KanbanCardView`, which drops its diagnostics list (and with it the
    /// severity dot) to empty when this is false.
    let supportsKanbanDiagnostics: Bool
    /// Optimistic-aware accessor forwarded to cards. Default is
    /// "no override" so Previews and harness contexts still render
    /// without wiring up a board VM.
    let diagnostics: (HermesKanbanTask) -> [HermesKanbanDiagnostic]
    /// v0.15+ gate forwarded to each card's context menu.
    let supportsKanbanV015: Bool
    /// v0.21.1+ gate forwarded to each card's `last_failure_error`
    /// sub-line, a field that only enters `kanban list --json` at v2026.9.7.
    let supportsKanbanCompletionContract: Bool
    /// v0.15 context-menu callbacks, keyed by the acted-on task.
    let onPromote: (HermesKanbanTask) -> Void
    let onSchedule: (HermesKanbanTask) -> Void
    let onDeletePermanently: (HermesKanbanTask) -> Void

    init(
        column: KanbanBoardColumn,
        tasks: [HermesKanbanTask],
        isLive: Bool,
        readyPillCount: Int,
        onTaskTap: @escaping (HermesKanbanTask) -> Void,
        onCreate: @escaping () -> Void,
        onDrop: @escaping (KanbanTaskRef) -> Void,
        canCreate: Bool,
        supportsKanbanDiagnostics: Bool = false,
        diagnostics: @escaping (HermesKanbanTask) -> [HermesKanbanDiagnostic] = { _ in [] },
        supportsKanbanV015: Bool = false,
        supportsKanbanCompletionContract: Bool = false,
        onPromote: @escaping (HermesKanbanTask) -> Void = { _ in },
        onSchedule: @escaping (HermesKanbanTask) -> Void = { _ in },
        onDeletePermanently: @escaping (HermesKanbanTask) -> Void = { _ in }
    ) {
        self.column = column
        self.tasks = tasks
        self.isLive = isLive
        self.readyPillCount = readyPillCount
        self.onTaskTap = onTaskTap
        self.onCreate = onCreate
        self.onDrop = onDrop
        self.canCreate = canCreate
        self.supportsKanbanDiagnostics = supportsKanbanDiagnostics
        self.diagnostics = diagnostics
        self.supportsKanbanV015 = supportsKanbanV015
        self.supportsKanbanCompletionContract = supportsKanbanCompletionContract
        self.onPromote = onPromote
        self.onSchedule = onSchedule
        self.onDeletePermanently = onDeletePermanently
    }

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, ScarfSpace.s3)
                .padding(.vertical, ScarfSpace.s2)
                .background(ScarfColor.backgroundSecondary.opacity(0.001))
                .background(.ultraThinMaterial)
            Divider()
                .opacity(0.5)
            ScrollView {
                LazyVStack(spacing: ScarfSpace.s2) {
                    if tasks.isEmpty {
                        emptyState
                            .padding(.top, ScarfSpace.s4)
                    } else {
                        ForEach(tasks) { task in
                            KanbanCardView(
                                task: task,
                                supportsKanbanDiagnostics: supportsKanbanDiagnostics,
                                diagnostics: diagnostics(task),
                                supportsKanbanV015: supportsKanbanV015,
                                supportsKanbanCompletionContract: supportsKanbanCompletionContract,
                                onPromote: { onPromote(task) },
                                onSchedule: { onSchedule(task) },
                                onDeletePermanently: { onDeletePermanently(task) }
                            ) {
                                onTaskTap(task)
                            }
                        }
                    }
                }
                .padding(ScarfSpace.s3)
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                .fill(ScarfColor.backgroundSecondary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                .stroke(borderColor, lineWidth: isTargeted ? 2 : 1)
        )
        .animation(.easeInOut(duration: 0.12), value: isTargeted)
        // UI gate: which column a card sits in is the assertion a move
        // journey makes, and containment is the only way to express it.
        //
        // `children: .contain` is load-bearing, for the same reason it is
        // on ContentView's section root. A bare `.accessibilityIdentifier`
        // REWRITES the identifier of everything beneath it, so the column
        // id landed on the header, the badge and each empty-state text as
        // well — and `firstMatch` then resolved to whichever of those the
        // tree happened to order first, an element with no descendants, so
        // "is this card inside this column" was always false. As a
        // container this is ONE element carrying the id, with the cards
        // beneath it still individually addressable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.column.\(column.rawValue)")
        .dropDestination(for: KanbanTaskRef.self) { items, _ in
            if let ref = items.first {
                onDrop(ref)
                return true
            }
            return false
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: ScarfSpace.s2) {
            Text(column.displayName.uppercased())
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            ScarfBadge(verbatim: String(tasks.count), kind: .neutral)
            if column == .upNext, readyPillCount > 0 {
                Text("ready: \(readyPillCount) →")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.info)
            }
            if column == .running, isLive {
                liveIndicator
            }
            Spacer(minLength: 0)
            if canCreate {
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(ScarfGhostButton())
                .help("New task in \(column.displayName)")
            }
        }
    }

    private var liveIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ScarfColor.success)
                .frame(width: 6, height: 6)
            Text("live")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
    }

    private var borderColor: Color {
        isTargeted ? ScarfColor.accent : ScarfColor.border
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Text(emptyCopy)
            .scarfStyle(.footnote)
            .foregroundStyle(ScarfColor.foregroundFaint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, ScarfSpace.s4)
    }

    private var emptyCopy: String {
        switch column {
        case .triage:    return "Nothing waiting on you."
        case .scheduled: return "No parked tasks."
        case .upNext:    return "Empty queue. Drop a task here."
        case .running:   return "No live workers."
        case .review:    return "Nothing awaiting review."
        case .blocked:   return "Nothing blocked."
        case .done:      return "Recent completions appear here."
        case .archived:  return "No archived tasks."
        }
    }
}
