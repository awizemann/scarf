import SwiftUI
import ScarfCore
import ScarfDesign

/// Read-only Kanban surface for iOS / iPadOS, scoped to one project's
/// tenant. Renders the 5 standard board columns as a horizontally-
/// paged `TabView` of single-column lists — HIG-friendly on iPhone
/// where a 5-column grid would force unreadable card widths.
///
/// Mutations + drag-drop are deferred to a later release per
/// CLAUDE.md's iOS catch-up policy. Tap a card to open a read-only
/// detail sheet that surfaces the same comments / events / runs the
/// Mac inspector shows. iPad gets the same view (no drag-drop yet) —
/// same UI for both form factors keeps the future mutation path
/// straightforward.
struct ScarfGoKanbanView: View {
    let project: ProjectEntry
    let context: ServerContext

    @State private var tasks: [HermesKanbanTask] = []
    @State private var stats: HermesKanbanStats = .empty
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedColumn: KanbanBoardColumn = .upNext
    @State private var inspectorTaskId: String?
    @State private var pollTask: Task<Void, Never>?

    private var resolvedTenant: String? {
        KanbanTenantReader(context: context).tenant(forProjectPath: project.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !stats.glanceString.isEmpty {
                Text(stats.glanceString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            columnPicker
                .padding(.horizontal)
                .padding(.bottom, 4)
            Divider()
            content
        }
        .background(ScarfColor.backgroundPrimary)
        .task(id: project.id) {
            await refresh()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .sheet(item: Binding(
            get: { inspectorTaskId.map { TaskIDBox(id: $0) } },
            set: { inspectorTaskId = $0?.id }
        )) { box in
            ScarfGoKanbanDetailSheet(
                taskId: box.id,
                context: context
            )
        }
    }

    private var columnPicker: some View {
        Picker("Column", selection: $selectedColumn) {
            ForEach(visibleColumns, id: \.self) { column in
                Text("\(column.displayName) (\(taskCount(in: column)))").tag(column)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            errorView(error)
        } else if isLoading && tasks.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            taskList
        }
    }

    private var taskList: some View {
        let rows = tasks(in: selectedColumn)
        return Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    emptyTitle(for: selectedColumn),
                    systemImage: "rectangle.split.3x1",
                    description: Text(emptyCopy(for: selectedColumn))
                )
            } else {
                List(rows) { task in
                    Button {
                        inspectorTaskId = task.id
                    } label: {
                        cardRow(task)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .refreshable {
                    await refresh()
                }
            }
        }
    }

    private func cardRow(_ task: HermesKanbanTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 8) {
                if let assignee = task.assignee, !assignee.isEmpty {
                    Label(assignee, systemImage: "person.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let workspace = task.workspaceKind {
                    ScarfBadge(verbatim: workspace, kind: .neutral)
                }
                if let priority = task.priority, priority >= 70 {
                    ScarfBadge("p\(priority)", kind: priority >= 90 ? .danger : .warning)
                }
                Spacer()
            }
            if !task.skills.isEmpty {
                Text(task.skills.prefix(2).joined(separator: ", ") + (task.skills.count > 2 ? " +\(task.skills.count - 2)" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load tasks", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await refresh() }
            }
        }
    }

    // MARK: - Loading

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        guard let tenant = resolvedTenant, !tenant.isEmpty else {
            tasks = []
            error = "No Kanban tenant has been minted for this project yet. Open the Kanban tab on the Mac app to mint one."
            return
        }
        let svc = KanbanService(context: context)
        let filter = KanbanListFilter(tenant: tenant)
        do {
            let polled = try await svc.list(filter)
            tasks = polled
            stats = (try? await svc.stats()) ?? .empty
            error = nil
        } catch let err as KanbanError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Column projection

    private var visibleColumns: [KanbanBoardColumn] {
        var cols: [KanbanBoardColumn] = []
        if !tasks(in: .triage).isEmpty { cols.append(.triage) }
        if !tasks(in: .scheduled).isEmpty { cols.append(.scheduled) }
        cols.append(contentsOf: [.upNext, .running])
        if !tasks(in: .review).isEmpty { cols.append(.review) }
        cols.append(contentsOf: [.blocked, .done])
        return cols
    }

    private func taskCount(in column: KanbanBoardColumn) -> Int {
        tasks(in: column).count
    }

    private func tasks(in column: KanbanBoardColumn) -> [HermesKanbanTask] {
        tasks.filter { KanbanStatus.from($0.status).boardColumn == column }
            .sorted { lhs, rhs in
                let lp = lhs.priority ?? 0
                let rp = rhs.priority ?? 0
                if lp != rp { return lp > rp }
                return (lhs.createdAt ?? "") > (rhs.createdAt ?? "")
            }
    }

    private func emptyTitle(for column: KanbanBoardColumn) -> String {
        switch column {
        case .triage:    return "Triage empty"
        case .scheduled: return "Nothing scheduled"
        case .upNext:    return "Queue empty"
        case .running:   return "No live workers"
        case .review:    return "Nothing in review"
        case .blocked:   return "Nothing blocked"
        case .done:      return "No completions yet"
        case .archived:  return "No archived tasks"
        }
    }

    private func emptyCopy(for column: KanbanBoardColumn) -> String {
        switch column {
        case .triage:    return "No tasks waiting on a specifier."
        case .scheduled: return "Parked tasks awaiting a trigger will show up here."
        case .upNext:    return "Drop a task on the Mac board, or create one with `hermes kanban create`."
        case .running:   return "No workers are running tasks for this project right now."
        case .review:    return "Completed work awaiting verification lands here."
        case .blocked:   return "Nothing is blocked. When a worker hits a block, it'll show up here."
        case .done:      return "Recent completions will land here."
        case .archived:  return "Archived tasks are hidden by default."
        }
    }
}

private struct TaskIDBox: Identifiable {
    let id: String
}
