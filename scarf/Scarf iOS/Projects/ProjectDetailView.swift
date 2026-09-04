import SwiftUI
import ScarfCore
import ScarfDesign

/// Per-project detail view, presented when a row in `ProjectsListView`
/// is tapped. Mirrors the Mac three-tab layout (Dashboard | Site |
/// Sessions) using a segmented `Picker`. The Site segment is gated on
/// the dashboard containing a `webview` widget — empty dashboards or
/// dashboards without a site URL hide the segment to match Mac's
/// `visibleTabs` logic in `ProjectsView.swift`.
///
/// "New Chat" toolbar button calls `ScarfGoCoordinator.startChatInProject`
/// which sets `pendingProjectChat` and routes to the Chat tab.
/// `ChatController` consumes `pendingProjectChat` on next appear and
/// dispatches `resetAndStartInProject(_:)` — same wiring the existing
/// in-Chat picker sheet uses.
struct ProjectDetailView: View {
    let project: ProjectEntry
    let config: IOSServerConfig

    @Environment(\.scarfGoCoordinator) private var coordinator
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A2"
    )!

    @State private var dashboard: ProjectDashboard?
    @State private var dashboardError: String?
    @State private var isLoading: Bool = true
    @State private var selectedTab: DetailTab = .dashboard
    /// Last-seen mtime on `<project>/.scarf/dashboard.json`. The
    /// foreground poll task compares this against a fresh stat to
    /// decide whether to re-parse — cheap when the file is unchanged,
    /// and the poll only runs while the view is visible.
    /// `"<mtime-seconds>:<size>"` of the dashboard file the view is
    /// currently showing, or `nil` when it wasn't there. Mtime ALONE was
    /// not enough: SFTP reports whole seconds, every Scarf write is an
    /// atomic replace, and two replaces inside one second are the shape
    /// this app actually produces — so a same-second rewrite was
    /// invisible. Pairing size with it is the same signature the Mac
    /// watcher uses (PERF L3).
    @State private var lastDashboardSignature: String?
    /// Resolved name of the project's bound model preset, or nil when
    /// the project inherits the global default. Read-only on iOS in
    /// v1 — Mac CRUD writes the binding; iOS just surfaces the name.
    @State private var modelPresetName: String?

    enum DetailTab: Hashable {
        case dashboard, site, sessions, kanban
    }

    private var serverContext: ServerContext {
        config.toServerContext(id: Self.sharedContextID)
    }

    /// First webview widget across all sections, if any. Nil → Site
    /// segment hidden. Mirrors Mac `siteWidget`.
    private var siteWidget: DashboardWidget? {
        dashboard?
            .sections
            .flatMap(\.widgets)
            .first { $0.type == "webview" }
    }

    private var visibleTabs: [DetailTab] {
        var tabs: [DetailTab] = [.dashboard]
        if siteWidget != nil { tabs.append(.site) }
        tabs.append(.sessions)
        if capabilitiesStore?.capabilities.hasKanban ?? false {
            tabs.append(.kanban)
        }
        return tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            if let modelPresetName,
               capabilitiesStore?.capabilities.hasACPSetSessionModel ?? false {
                modelBadge(modelPresetName)
            }
            tabPicker
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Divider()
            tabContent
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator?.startChatInProject(path: project.path)
                } label: {
                    Label("New Chat", systemImage: "message.badge.filled.fill")
                }
                .accessibilityLabel("Start new chat in \(project.name)")
                .accessibilityHint("Opens the Chat tab and begins a session scoped to this project")
            }
        }
        .task(id: project.id) { await loadDashboard() }
        .task(id: project.id) { await pollDashboardMtime() }
        .task(id: project.id) { await loadModelPresetName() }
        .refreshable { await loadDashboard() }
        .onChange(of: visibleTabs) { _, newTabs in
            // If the user was on Site and a refresh removed the
            // webview widget, fall back to Dashboard so the segmented
            // picker doesn't end up out-of-sync with its segments.
            if !newTabs.contains(selectedTab) {
                selectedTab = .dashboard
            }
        }
    }

    // MARK: - Tab picker

    @ViewBuilder
    private var tabPicker: some View {
        Picker("Section", selection: $selectedTab) {
            ForEach(visibleTabs, id: \.self) { tab in
                Text(label(for: tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    private func label(for tab: DetailTab) -> String {
        switch tab {
        case .dashboard: return "Dashboard"
        case .site: return "Site"
        case .sessions: return "Sessions"
        case .kanban: return "Kanban"
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .dashboard:
            dashboardTab
        case .site:
            if let widget = siteWidget {
                ProjectSiteView(widget: widget)
            } else {
                emptyDashboard
            }
        case .sessions:
            ProjectSessionsView_iOS(project: project)
        case .kanban:
            ScarfGoKanbanView(project: project, context: serverContext)
        }
    }

    @ViewBuilder
    private var dashboardTab: some View {
        if isLoading && dashboard == nil {
            ProgressView("Loading dashboard…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let dash = dashboard {
            DashboardWidgetsView(dashboard: dash)
        } else {
            emptyDashboard
        }
    }

    private var emptyDashboard: some View {
        ContentUnavailableView {
            Label("No Dashboard", systemImage: "rectangle.dashed")
        } description: {
            Text(dashboardError ?? "This project doesn't have a dashboard at \(project.dashboardPath) yet.")
                .font(.caption)
        } actions: {
            Button("Try Again") {
                Task { await loadDashboard() }
            }
        }
    }

    // MARK: - Model badge

    /// Compact "Model: <preset name>" line surfaced above the tab
    /// picker. Read-only on iOS v1 — Mac owns the CRUD + binding.
    @ViewBuilder
    private func modelBadge(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.caption)
                .foregroundStyle(ScarfColor.info)
            Text("Model: \(name)")
                .font(.caption)
                .foregroundStyle(ScarfColor.info)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Resolve the project's bound model preset name, off-MainActor.
    /// Two reads: project manifest (to get the preset id) → preset
    /// store (to map id → name). Both are tiny JSON files and the
    /// task only runs on project change. Sets `modelPresetName` to
    /// nil when no binding exists or the bound preset has been
    /// deleted on the remote.
    private func loadModelPresetName() async {
        let ctx = serverContext
        let path = project.path
        let name: String? = await Task.detached(priority: .utility) {
            let reader = ProjectModelPresetReader(context: ctx)
            guard let idString = reader.presetID(forProjectPath: path),
                  let uuid = UUID(uuidString: idString)
            else { return nil }
            let service = ModelPresetService.shared(for: ctx)
            let preset = try? await service.get(id: uuid)
            return preset?.name
        }.value
        self.modelPresetName = name
    }

    // MARK: - Loading

    /// Load the project's dashboard via `ProjectDashboardService` on a
    /// background task — same `Task.detached` pattern the registry
    /// loader uses to keep the SFTP read off MainActor.
    private func loadDashboard() async {
        isLoading = true
        defer { isLoading = false }
        let ctx = serverContext
        let proj = project
        let result: (ProjectDashboard?, String?, String?) = await Task.detached {
            let service = ProjectDashboardService(context: ctx)
            if !service.dashboardExists(for: proj) {
                return (nil, "No dashboard found at \(proj.dashboardPath)", nil)
            }
            let signature = service.dashboardSignature(for: proj)
            if let loaded = service.loadDashboard(for: proj) {
                return (loaded, nil, signature)
            }
            return (nil, "Failed to parse dashboard JSON", signature)
        }.value
        dashboard = result.0
        dashboardError = result.1
        lastDashboardSignature = result.2
    }

    /// Poll the dashboard file's mtime every 4 seconds while the view
    /// is foregrounded; reload on any change. iOS doesn't have an
    /// inotify-style watcher over SFTP, but a per-view poll is cheap
    /// (one stat call per tick) and stops the moment the user
    /// navigates away — the `.task` modifier cancels the loop on view
    /// disappear automatically.
    private func pollDashboardMtime() async {
        let ctx = serverContext
        let proj = project
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { break }
            let fresh: String? = await Task.detached {
                ProjectDashboardService(context: ctx)
                    .dashboardSignature(for: proj)
            }.value
            // ANY difference reloads, not just a strictly LATER mtime: a
            // file whose mtime went backwards (a restored backup, a
            // clock skew, an `scp -p` from an older copy) is still a
            // different file, and the old strictly-greater compare left
            // the stale one on screen forever.
            //
            // A `nil` still does NOT reload, deliberately: over SFTP one
            // dropped round-trip reads as "absent", and turning that into
            // a reload would replace a perfectly good dashboard with a
            // "no dashboard found" error on a transport blip. A genuinely
            // deleted dashboard is caught the next time the view is
            // opened — the same trade this poll has always made.
            guard let fresh else { continue }
            if fresh != lastDashboardSignature {
                await loadDashboard()
            }
        }
    }
}
