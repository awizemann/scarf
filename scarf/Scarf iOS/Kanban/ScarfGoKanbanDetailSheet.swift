import SwiftUI
import ScarfCore
import ScarfDesign

/// Read-only Kanban task detail sheet for iOS. Mirrors the Mac
/// inspector's 3-tab layout (Comments | Events | Runs) but routes
/// through a `NavigationStack` for iOS-native chrome and dismisses
/// to the parent kanban view, not to the board.
///
/// No mutations in v2.7.5 — write actions land on iOS in a later
/// release via a bottom action bar with explicit verb buttons (no
/// drag-drop).
struct ScarfGoKanbanDetailSheet: View {
    let taskId: String
    let context: ServerContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    @State private var detail: HermesKanbanTaskDetail?
    @State private var runs: [HermesKanbanRun] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedTab: DetailTab = .comments
    @State private var selectedDiagnostic: HermesKanbanDiagnostic?

    enum DetailTab: String, CaseIterable, Identifiable {
        case comments = "Comments"
        case events = "Events"
        case runs = "Runs"
        var id: String { rawValue }
    }

    /// v0.13 capability gate. Defensive default `false` when no
    /// capabilities store is present (preview / smoke harness) so the
    /// sheet renders the v2.7.5 layout unchanged.
    private var diagnosticsAvailable: Bool {
        capabilitiesStore?.capabilities.hasKanbanDiagnostics ?? false
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(detail?.task.title ?? "Task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task(id: taskId) { await load() }
        .sheet(item: $selectedDiagnostic) { diag in
            DiagnosticDetailSheet(diagnostic: diag)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && detail == nil {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView {
                Label("Couldn't load task", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    Task { await load() }
                }
            }
        } else if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard(detail.task)
                    hallucinationBadge(detail.task)
                    autoBlockedBanner(detail.task)
                    if let body = detail.task.body, !body.isEmpty {
                        if let attributed = try? AttributedString(markdown: body) {
                            Text(attributed)
                                .font(.body)
                        } else {
                            Text(body)
                                .font(.body)
                        }
                    }
                    if diagnosticsAvailable, !detail.task.diagnostics.isEmpty {
                        diagnosticsBlock(detail.task.diagnostics, label: "Diagnostics")
                    }
                    Picker("Section", selection: $selectedTab) {
                        ForEach(DetailTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    switch selectedTab {
                    case .comments: commentsSection(detail.comments)
                    case .events:   eventsSection(detail.events)
                    case .runs:     runsSection
                    }
                }
                .padding()
            }
        }
    }

    private func headerCard(_ task: HermesKanbanTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Wrap chips in FlowLayout so the new v0.13 `retries` chip
            // doesn't push the row over the iPhone-portrait width budget.
            FlowLayout(spacing: 6) {
                ScarfBadge(verbatim: task.status.lowercased(), kind: badgeKind(for: task.status))
                if let assignee = task.assignee, !assignee.isEmpty {
                    ScarfBadge(verbatim: assignee, kind: .neutral)
                }
                if let workspace = task.workspaceKind {
                    ScarfBadge(verbatim: workspace, kind: .neutral)
                }
                if let tenant = task.tenant, !tenant.isEmpty {
                    ScarfBadge(verbatim: tenant, kind: .brand)
                }
                if diagnosticsAvailable, let maxRetries = task.maxRetries {
                    ScarfBadge("retries: \(maxRetries)", kind: .neutral)
                        .accessibilityLabel("Max retries \(maxRetries)")
                }
            }
            if let priority = task.priority {
                Text("Priority \(priority)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// v0.13 hallucination gate. Worker-created cards land in the
    /// `pending` state until a human verifies — Mac surfaces a Verify /
    /// Reject button pair; iOS in v2.8.0 stays read-only and points
    /// the user to the Mac app via the badge copy.
    @ViewBuilder
    private func hallucinationBadge(_ task: HermesKanbanTask) -> some View {
        if diagnosticsAvailable,
           KanbanHallucinationGate.from(task.hallucinationGateStatus) == .pending {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.diamond.fill")
                    .foregroundStyle(ScarfColor.warning)
                Text("Worker-created — verify on Mac")
                    .font(.subheadline)
                    .foregroundStyle(ScarfColor.warning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                ScarfColor.warning.opacity(0.10),
                in: RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .strokeBorder(ScarfColor.warning.opacity(0.4), lineWidth: 1)
            )
            .accessibilityHint("Open this task on the Mac app to verify or reject the worker's claim.")
        }
    }

    /// v0.13 auto-blocked banner. Surfaces `auto_blocked_reason` verbatim
    /// when Hermes auto-blocks a task (retry cap hit, repeated tool
    /// errors, etc.). Server-supplied copy — render verbatim.
    @ViewBuilder
    private func autoBlockedBanner(_ task: HermesKanbanTask) -> some View {
        if diagnosticsAvailable,
           KanbanStatus.from(task.status) == .blocked,
           let reason = task.autoBlockedReason, !reason.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(ScarfColor.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-blocked")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ScarfColor.danger)
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ScarfColor.danger.opacity(0.08),
                in: RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
            )
        }
    }

    /// Tap-target diagnostic chip list. iOS substitute for the Mac
    /// inspector's `.help()` tooltip — chips are tappable, tap presents
    /// `DiagnosticDetailSheet` with the full message + timestamp.
    @ViewBuilder
    private func diagnosticsBlock(_ diags: [HermesKanbanDiagnostic], label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(diags) { diag in
                    Button {
                        selectedDiagnostic = diag
                    } label: {
                        ScarfBadge(verbatim: diag.kind, kind: diagnosticBadgeKind(diag))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(diag.message ?? diag.kind)
                    .accessibilityHint("Tap to see the full diagnostic message and timestamp.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Maps the typed `KanbanDiagnosticKind.severity` enum into the
    /// `ScarfBadgeKind` palette. Mirrors the Mac inspector's
    /// `diagnosticBadge` helper so the two surfaces tint identically.
    private func diagnosticBadgeKind(_ diag: HermesKanbanDiagnostic) -> ScarfBadgeKind {
        switch KanbanDiagnosticKind.from(diag.kind).severity {
        case .danger:  return .danger
        case .warning: return .warning
        case .neutral: return .neutral
        }
    }

    private func commentsSection(_ comments: [HermesKanbanComment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if comments.isEmpty {
                Text("No comments yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(comment.author)
                                .font(.subheadline)
                                .bold()
                            Text(comment.createdAt)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(comment.body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(ScarfColor.backgroundSecondary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous))
                }
            }
        }
    }

    private func eventsSection(_ events: [HermesKanbanEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if events.isEmpty {
                Text("No events yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(events) { event in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind)
                                .font(.subheadline)
                                .bold()
                            Text(event.createdAt)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if runs.isEmpty {
                Text("No runs yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            ScarfBadge(verbatim: run.outcome ?? run.status, kind: outcomeKind(run.outcome ?? run.status))
                            if let profile = run.profile {
                                Text(profile)
                                    .font(.subheadline)
                            }
                            Spacer()
                            Text(run.startedAt)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let summary = run.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let err = run.error, !err.isEmpty {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if diagnosticsAvailable, !run.diagnostics.isEmpty {
                            diagnosticsBlock(run.diagnostics, label: "Run diagnostics")
                                .padding(.top, 4)
                        }
                    }
                    .padding(8)
                    .background(ScarfColor.backgroundSecondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous))
                }
            }
        }
    }

    private func badgeKind(for status: String) -> ScarfBadgeKind {
        switch KanbanStatus.from(status) {
        case .running, .ready: return .info
        case .done:            return .success
        case .blocked:         return .warning
        default:               return .neutral
        }
    }

    private func outcomeKind(_ outcome: String) -> ScarfBadgeKind {
        switch outcome.lowercased() {
        case "completed", "done":                              return .success
        case "blocked":                                        return .warning
        case "crashed", "timed_out", "spawn_failed", "failed": return .danger
        case "running":                                        return .info
        default:                                                return .neutral
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let svc = KanbanService(context: context)
        do {
            async let detailLoaded = svc.show(taskId: taskId)
            async let runsLoaded = svc.runs(taskId: taskId)
            self.detail = try await detailLoaded
            self.runs = (try? await runsLoaded) ?? []
            self.error = nil
        } catch let err as KanbanError {
            self.error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
