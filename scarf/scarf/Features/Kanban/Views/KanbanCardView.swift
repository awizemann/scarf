import SwiftUI
import ScarfCore
import ScarfDesign
import CoreTransferable

/// Transferable wrapper for a kanban task id. We tunnel the payload
/// through `String` via `ProxyRepresentation` (no custom UTI needed)
/// because SwiftUI's drag-drop with custom-UTI `CodableRepresentation`
/// requires a registered exported type in Info.plist to round-trip
/// reliably; the proxy form skips that ceremony and consistently lands
/// drops in v15 / 26.
struct KanbanTaskRef: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { (ref: KanbanTaskRef) in ref.id },
            importing: { (id: String) in KanbanTaskRef(id: id) }
        )
    }
}

/// Single Kanban card. Variant chrome differs by status:
/// - **Running** gets a blue left-edge accent + live shimmer
/// - **Blocked** gets a warning left-edge accent + ⚠ glyph
/// - **Done** dims to 0.7 opacity (0.55 in dark mode)
/// - **Hallucination-gate pending** (v0.13+) dims to 0.6 + ⚠ glyph and
///   shows a one-line auto-blocked reason in the footer when present.
struct KanbanCardView: View {
    let task: HermesKanbanTask
    let onTap: () -> Void
    /// True when the connected Hermes is on v0.13+ — gates the
    /// hallucination dim/glyph, auto-block sub-line, and diagnostics
    /// dot on the card. Pre-v0.13 hosts see the v2.7.5 chrome unchanged.
    let supportsKanbanDiagnostics: Bool
    /// Optimistic-aware accessor. Pre-v0.13 always nil. Otherwise delegates
    /// to the board VM so a Verify click un-dims the card immediately.
    let effectiveHallucinationGate: (HermesKanbanTask) -> KanbanHallucinationGate?
    /// v0.15+ gate for the Promote / Schedule / Delete context actions.
    /// Pre-v0.15 hosts get no context menu beyond what older builds had.
    let supportsKanbanV015: Bool
    /// v0.16+ gate for the goal-mode badge. Pre-v0.16 hosts never see the
    /// "Goal" pill even if a future `goal_mode` field somehow appears.
    let supportsKanbanGoalMode: Bool
    /// Context-menu callbacks. The board wires these to the VM's
    /// `promote` / `schedule` / `purge` (delete-permanently after a
    /// confirm). Each shown conditionally by `task.status`.
    let onPromote: () -> Void
    let onSchedule: () -> Void
    let onDeletePermanently: () -> Void

    init(
        task: HermesKanbanTask,
        supportsKanbanDiagnostics: Bool = false,
        effectiveHallucinationGate: @escaping (HermesKanbanTask) -> KanbanHallucinationGate? = { _ in nil },
        supportsKanbanV015: Bool = false,
        supportsKanbanGoalMode: Bool = false,
        onPromote: @escaping () -> Void = {},
        onSchedule: @escaping () -> Void = {},
        onDeletePermanently: @escaping () -> Void = {},
        onTap: @escaping () -> Void
    ) {
        self.task = task
        self.supportsKanbanDiagnostics = supportsKanbanDiagnostics
        self.effectiveHallucinationGate = effectiveHallucinationGate
        self.supportsKanbanV015 = supportsKanbanV015
        self.supportsKanbanGoalMode = supportsKanbanGoalMode
        self.onPromote = onPromote
        self.onSchedule = onSchedule
        self.onDeletePermanently = onDeletePermanently
        self.onTap = onTap
    }

    @Environment(\.colorScheme) private var colorScheme

    /// Cached gate read — derived once per body eval rather than recomputed
    /// in each subview helper.
    private var hallucinationGate: KanbanHallucinationGate? {
        guard supportsKanbanDiagnostics else { return nil }
        return effectiveHallucinationGate(task)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                titleRow
                if hasMetaRow1 {
                    metaRow1
                }
                if !task.skills.isEmpty {
                    skillsRow
                }
                footerRow
            }
            .padding(ScarfSpace.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .fill(ScarfColor.backgroundPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .stroke(ScarfColor.border, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if let edgeColor {
                    Rectangle()
                        .fill(edgeColor)
                        .frame(width: 2)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                        )
                        .padding(.vertical, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .scarfShadow(.sm)
        // v0.13: hallucination-pending cards dim to 0.6 to signal "needs
        // verification before running" without making them unreadable.
        // Done cards stay at the established doneOpacity (0.7 / 0.55).
        .opacity(cardOpacity)
        .draggable(KanbanTaskRef(id: task.id)) {
            // Drag preview — the live card with a heavier shadow.
            self.dragPreview
        }
        .contextMenu { contextMenuItems }
    }

    /// v0.15 lifecycle actions, status-gated. Empty (no menu) on
    /// pre-v0.15 hosts so we don't surface verbs Hermes won't accept.
    @ViewBuilder
    private var contextMenuItems: some View {
        if supportsKanbanV015 {
            let status = KanbanStatus.from(task.status)
            // Promote — only meaningful before a task is dispatchable.
            if status == .todo || status == .triage || status == .blocked {
                Button {
                    onPromote()
                } label: {
                    Label("Promote", systemImage: "arrow.up.circle")
                }
            }
            // Schedule / Park — pull an eligible task out of the queue.
            if status == .todo || status == .ready {
                Button {
                    onSchedule()
                } label: {
                    Label("Schedule / Park", systemImage: "pause.circle")
                }
            }
            // Delete permanently — only on already-archived cards.
            if status == .archived {
                Button(role: .destructive) {
                    onDeletePermanently()
                } label: {
                    Label("Delete permanently", systemImage: "trash")
                }
            }
        }
    }

    private var cardOpacity: Double {
        if task.isDone { return doneOpacity }
        if hallucinationGate == .pending { return 0.6 }
        return 1.0
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            statusGlyph
            Text(task.title)
                .scarfStyle(.bodyEmph)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            // v0.13 hallucination glyph takes precedence over the
            // unassigned glyph — the hallucination state is the more
            // specific signal (a worker created this card; verify it).
            if hallucinationGate == .pending {
                Image(systemName: "questionmark.diamond.fill")
                    .foregroundStyle(ScarfColor.warning)
                    .font(.system(size: 11, weight: .semibold))
                    .help("Worker-created — verify before running")
            } else if needsAssignmentWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScarfColor.warning)
                    .font(.system(size: 11, weight: .semibold))
                    .help("Unassigned — Hermes's dispatcher silently skips tasks with no assignee, so this task will never run automatically. Open the task and add an assignee, or recreate it with one set.")
            }
        }
    }

    /// Cards in `todo` or `ready` with no `assignee` are about to land
    /// in a silent zombie state — Hermes's dispatcher's `--json`
    /// output literally lists them under `skipped_unassigned` and
    /// moves on. Surfacing this on the card itself (vs. only inside
    /// the inspector) is the only way the user has a chance to notice
    /// before they sit there confused.
    private var needsAssignmentWarning: Bool {
        let column = KanbanStatus.from(task.status).boardColumn
        guard column == .upNext || column == .triage else { return false }
        return (task.assignee?.isEmpty ?? true)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch KanbanStatus.from(task.status) {
        case .blocked:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 2)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ScarfColor.success)
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 2)
        case .running:
            // No leading glyph — the left-edge accent + shimmer
            // already encodes the live state.
            EmptyView()
        default:
            EmptyView()
        }
    }

    /// v0.16: render the goal-mode pill only on v0.16+ hosts when the task
    /// is actually flagged as a goal loop. Pre-v0.16 hosts always have
    /// `task.goalMode == nil`, so this stays false.
    private var showsGoalBadge: Bool {
        supportsKanbanGoalMode && task.goalMode == true
    }

    private var hasMetaRow1: Bool {
        task.assignee?.isEmpty == false || task.workspaceKind != nil || showsGoalBadge
    }

    private var metaRow1: some View {
        HStack(spacing: ScarfSpace.s2) {
            if let assignee = task.assignee, !assignee.isEmpty {
                assigneeChip(assignee)
            } else {
                unassignedChip
            }
            if let workspace = task.workspaceKind {
                ScarfBadge(verbatim: workspace, kind: .neutral)
            }
            // v0.16 goal-mode pill — shows the turn budget when one is set.
            if showsGoalBadge {
                if let turns = task.goalMaxTurns {
                    ScarfBadge("Goal · \(turns)", kind: .info)
                } else {
                    ScarfBadge("Goal", kind: .info)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func assigneeChip(_ name: String) -> some View {
        HStack(spacing: 4) {
            Text(initials(of: name))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ScarfColor.accentActive)
                .frame(width: 16, height: 16)
                .background(ScarfColor.accentTint)
                .clipShape(Circle())
            Text(name)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
    }

    private var unassignedChip: some View {
        Text("Unassigned")
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundFaint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.sm, style: .continuous)
                    .stroke(
                        ScarfColor.borderStrong,
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )
            )
    }

    private var skillsRow: some View {
        HStack(spacing: 4) {
            // Keyed by VALUE, not by array index: with `id: \.offset`
            // SwiftUI treats "slot 0" as one identity, so when a task's
            // skills change the badge in that slot animates/reuses as if
            // the same chip had been renamed. Skill names are unique per
            // task (Hermes stores a set), so `\.self` is a stable id.
            ForEach(Array(task.skills.prefix(2)), id: \.self) { skill in
                ScarfBadge(verbatim: skill, kind: .brand)
            }
            if task.skills.count > 2 {
                ScarfBadge("+\(task.skills.count - 2)", kind: .neutral)
            }
            Spacer(minLength: 0)
        }
    }

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            // v0.13: server-supplied auto-blocked reason. Renders verbatim
            // (truncated to one line; full reason in the inspector).
            // Pre-v0.13 hosts always have task.autoBlockedReason == nil.
            if supportsKanbanDiagnostics,
               KanbanStatus.from(task.status) == .blocked,
               let reason = task.autoBlockedReason, !reason.isEmpty {
                Text(reason)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }
            HStack(spacing: ScarfSpace.s2) {
                Text(relativeTimeLabel)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Spacer(minLength: 0)
                // v0.13: diagnostics dot — small stethoscope glyph when
                // any cross-run distress signal is attached. Matches the
                // chip count in the inspector.
                if supportsKanbanDiagnostics, !task.diagnostics.isEmpty {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 9))
                        .foregroundStyle(ScarfColor.warning)
                        .help("\(task.diagnostics.count) diagnostic signal\(task.diagnostics.count == 1 ? "" : "s")")
                }
                if let priority = task.priority, priority >= 70 {
                    priorityIndicator(priority)
                }
            }
        }
    }

    private func priorityIndicator(_ priority: Int) -> some View {
        let color: Color = priority >= 90 ? ScarfColor.danger : ScarfColor.warning
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 8, height: 8)
            .help("Priority \(priority)")
    }

    private var dragPreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
                .scarfStyle(.bodyEmph)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
            if let assignee = task.assignee, !assignee.isEmpty {
                Text(assignee)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
        }
        .padding(.horizontal, ScarfSpace.s2)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundPrimary)
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .stroke(ScarfColor.accent, lineWidth: 1)
        )
        .scarfShadow(.lg)
    }

    // MARK: - Helpers

    private var edgeColor: Color? {
        switch KanbanStatus.from(task.status) {
        case .running:  return ScarfColor.info
        case .blocked:  return ScarfColor.warning
        default:        return nil
        }
    }

    private var doneOpacity: Double {
        colorScheme == .dark ? 0.55 : 0.7
    }

    /// Display string for the footer's relative time slot. The "since"
    /// reference depends on status — running tasks show how long
    /// they've been running; blocked show how long blocked, etc.
    private var relativeTimeLabel: String {
        switch KanbanStatus.from(task.status) {
        case .running:
            if let started = task.startedAt, let label = relativeShort(from: started) {
                return "running \(label)"
            }
            return "running"
        case .blocked:
            // Hermes doesn't expose blocked-since separately; fall
            // back to created_at as a coarse signal.
            if let created = task.createdAt, let label = relativeShort(from: created) {
                return "blocked \(label)"
            }
            return "blocked"
        case .done:
            if let completed = task.completedAt, let label = relativeShort(from: completed) {
                return "done \(label) ago"
            }
            return "done"
        default:
            if let created = task.createdAt, let label = relativeShort(from: created) {
                return "\(label) ago"
            }
            return ""
        }
    }

    // Two cached parsers (fractional + plain) so relativeShort never
    // allocates/mutates an ISO8601DateFormatter per card per render. (t-aud10)
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func relativeShort(from iso: String) -> String? {
        if let date = Self.isoFractional.date(from: iso) {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        if let date = Self.isoPlain.date(from: iso) {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return nil
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func initials(of name: String) -> String {
        let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}

private extension HermesKanbanTask {
    var isDone: Bool { KanbanStatus.from(status) == .done }
}
