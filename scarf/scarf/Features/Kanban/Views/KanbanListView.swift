import SwiftUI
import ScarfCore
import ScarfDesign

/// The v2.6 read-only list view, preserved as a presentation fallback
/// alongside the v2.7.5 drag-and-drop board. Reuses the existing
/// `KanbanViewModel` (status-filter polling) so the list stays
/// independent of the board's optimistic-merge state.
struct KanbanListView: View {
    @State private var viewModel: KanbanViewModel

    init(context: ServerContext) {
        _viewModel = State(initialValue: KanbanViewModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Kanban",
                subtitle: "Hermes v0.12+ task board (list view)"
            ) {
                HStack(spacing: ScarfSpace.s2) {
                    Picker("Status", selection: $viewModel.statusFilter) {
                        ForEach(KanbanViewModel.StatusFilter.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ScarfGhostButton())
                }
            }
            Divider()

            if let err = viewModel.lastError {
                errorBanner(err)
            }

            ScrollView {
                if viewModel.tasks.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    taskTable
                }
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .onChange(of: viewModel.statusFilter) { _, _ in
            Task { await viewModel.load() }
        }
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    private var taskTable: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.tasks) { task in
                taskRow(task)
                Divider()
            }
        }
        .padding(ScarfSpace.s3)
    }

    private func taskRow(_ task: HermesKanbanTask) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: ScarfSpace.s2) {
                    statusBadge(for: task.status)
                    Text(task.title)
                        .scarfStyle(.bodyEmph)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    metaChip(systemImage: "number", value: String(task.id.prefix(8)))
                    if let assignee = task.assignee, !assignee.isEmpty {
                        metaChip(systemImage: "person.fill", value: assignee)
                    }
                    if let workspace = task.workspaceKind {
                        metaChip(systemImage: "folder", value: workspace)
                    }
                    if let tenant = task.tenant, !tenant.isEmpty {
                        metaChip(systemImage: "tag", value: tenant)
                    }
                    if !task.skills.isEmpty {
                        metaChip(systemImage: "lightbulb", value: task.skills.joined(separator: ", "))
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let createdAt = task.createdAt {
                    Text(createdAt)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
                if let priority = task.priority {
                    Text("p\(priority)")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
        }
        .padding(.vertical, ScarfSpace.s2)
    }

    private func statusBadge(for status: String) -> some View {
        let kind: ScarfBadgeKind
        switch status.lowercased() {
        case "done":     kind = .success
        case "running":  kind = .info
        case "ready":    kind = .info
        case "blocked":  kind = .warning
        case "archived": kind = .neutral
        default:         kind = .neutral
        }
        return ScarfBadge(verbatim: status, kind: kind)
    }

    private func metaChip(systemImage: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(value)
                .font(ScarfFont.monoSmall)
        }
        .foregroundStyle(ScarfColor.foregroundMuted)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 36))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("No kanban tasks")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Text("Create one with `hermes kanban create \"task title\"`. Tasks dispatched by the gateway show up here automatically.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
            Text(message)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundPrimary)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.warning.opacity(0.12))
    }
}
