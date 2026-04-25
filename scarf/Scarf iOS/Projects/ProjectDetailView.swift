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
    @State private var lastDashboardMtime: Date?

    enum DetailTab: Hashable {
        case dashboard, site, sessions
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
        return tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Divider()
            tabContent
        }
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

    // MARK: - Loading

    /// Load the project's dashboard via `ProjectDashboardService` on a
    /// background task — same `Task.detached` pattern the registry
    /// loader uses to keep the SFTP read off MainActor.
    private func loadDashboard() async {
        isLoading = true
        defer { isLoading = false }
        let ctx = serverContext
        let proj = project
        let result: (ProjectDashboard?, String?, Date?) = await Task.detached {
            let service = ProjectDashboardService(context: ctx)
            if !service.dashboardExists(for: proj) {
                return (nil, "No dashboard found at \(proj.dashboardPath)", nil)
            }
            let mtime = service.dashboardModificationDate(for: proj)
            if let loaded = service.loadDashboard(for: proj) {
                return (loaded, nil, mtime)
            }
            return (nil, "Failed to parse dashboard JSON", mtime)
        }.value
        dashboard = result.0
        dashboardError = result.1
        lastDashboardMtime = result.2
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
            let fresh: Date? = await Task.detached {
                ProjectDashboardService(context: ctx)
                    .dashboardModificationDate(for: proj)
            }.value
            // First tick after a missing-dashboard error: nil → nil is
            // a no-op; nil → Date triggers a reload (file just appeared).
            // Date → newer Date triggers a reload. Same Date is a no-op.
            switch (lastDashboardMtime, fresh) {
            case (nil, nil), (_, nil):
                continue
            case (nil, _):
                await loadDashboard()
            case (let prev?, let now?) where now > prev:
                await loadDashboard()
            default:
                continue
            }
        }
    }
}
