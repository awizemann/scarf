import SwiftUI

private enum DashboardTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case site = "Site"

    var displayName: LocalizedStringResource {
        switch self {
        case .dashboard: return "Dashboard"
        case .site: return "Site"
        }
    }
}

struct ProjectsView: View {
    @State private var viewModel: ProjectsViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @State private var showingAddSheet = false

    init(context: ServerContext) {
        _viewModel = State(initialValue: ProjectsViewModel(context: context))
    }

    @State private var selectedTab: DashboardTab = .dashboard

    var body: some View {
        HSplitView {
            projectList
                .frame(minWidth: 180, maxWidth: 220)
            dashboardArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Projects")
        .task {
            viewModel.load()
            if let name = coordinator.selectedProjectName,
               let project = viewModel.projects.first(where: { $0.name == name }) {
                viewModel.selectProject(project)
            }
            fileWatcher.updateProjectWatches(viewModel.dashboardPaths)
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            viewModel.load()
            fileWatcher.updateProjectWatches(viewModel.dashboardPaths)
        }
    }

    // MARK: - Project List

    private var projectList: some View {
        VStack(spacing: 0) {
            List(viewModel.projects, selection: Binding(
                get: { viewModel.selectedProject },
                set: { project in
                    if let project {
                        viewModel.selectProject(project)
                    }
                }
            )) { project in
                HStack {
                    Image(systemName: viewModel.dashboard != nil && viewModel.selectedProject == project
                          ? "square.grid.2x2.fill" : "square.grid.2x2")
                        .foregroundStyle(.secondary)
                    Text(project.name)
                }
                .tag(project)
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if let selected = viewModel.selectedProject {
                    Button(action: { viewModel.removeProject(selected) }) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddProjectSheet { name, path in
                viewModel.addProject(name: name, path: path)
                fileWatcher.updateProjectWatches(viewModel.dashboardPaths)
            }
        }
    }

    // MARK: - Dashboard Area

    /// First webview widget found across all sections, if any.
    private var siteWidget: DashboardWidget? {
        viewModel.dashboard?.sections
            .flatMap(\.widgets)
            .first { $0.type == "webview" }
    }

    @ViewBuilder
    private var dashboardArea: some View {
        if let dashboard = viewModel.dashboard {
            VStack(spacing: 0) {
                dashboardHeader(dashboard)
                    .padding(.horizontal)
                    .padding(.top)
                    .padding(.bottom, 8)
                if siteWidget != nil {
                    tabBar
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                switch selectedTab {
                case .dashboard:
                    widgetsTab(dashboard)
                case .site:
                    if let widget = siteWidget {
                        siteTab(widget)
                    } else {
                        widgetsTab(dashboard)
                    }
                }
            }
        } else if let error = viewModel.dashboardError {
            ContentUnavailableView {
                Label("No Dashboard", systemImage: "square.grid.2x2")
            } description: {
                Text(error)
            }
        } else if viewModel.projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "square.grid.2x2")
            } description: {
                Text("Add a project folder to get started. Create a .scarf/dashboard.json file in your project to define widgets.")
            } actions: {
                Button("Add Project") { showingAddSheet = true }
            }
        } else {
            ContentUnavailableView {
                Label("Select a Project", systemImage: "square.grid.2x2")
            } description: {
                Text("Choose a project from the sidebar to view its dashboard.")
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab == .dashboard ? "square.grid.2x2" : "globe")
                            .font(.caption)
                        Text(tab.displayName)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func widgetsTab(_ dashboard: ProjectDashboard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(dashboard.sections) { section in
                    DashboardSectionView(section: section)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func siteTab(_ widget: DashboardWidget) -> some View {
        WebviewWidgetView(widget: widget, fullCanvas: true)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dashboardHeader(_ dashboard: ProjectDashboard) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboard.title)
                    .font(.title2.bold())
                if let desc = dashboard.description {
                    Text(desc)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let updated = dashboard.updatedAt {
                Text("Updated: \(updated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: { viewModel.refreshDashboard() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            if let project = viewModel.selectedProject {
                Button(action: { openInFinder(project.path) }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func openInFinder(_ path: String) {
        // Project paths come from the registry on the active server. For
        // remote, the path is on that machine's filesystem and can't be
        // shown in this Mac's Finder — no-op via the helper.
        viewModel.context.openInLocalEditor(path)
    }
}

// MARK: - Section View

struct DashboardSectionView: View {
    let section: DashboardSection

    /// Filter out webview widgets — those are rendered in the Site tab instead.
    private var displayWidgets: [DashboardWidget] {
        section.widgets.filter { $0.type != "webview" }
    }

    var body: some View {
        if !displayWidgets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(section.title)
                    .font(.headline)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: section.columnCount),
                    spacing: 12
                ) {
                    ForEach(displayWidgets) { widget in
                        WidgetView(widget: widget)
                    }
                }
            }
        }
    }
}

// MARK: - Widget Dispatcher

struct WidgetView: View {
    let widget: DashboardWidget

    var body: some View {
        Group {
            switch widget.type {
            case "stat":
                StatWidgetView(widget: widget)
            case "progress":
                ProgressWidgetView(widget: widget)
            case "text":
                TextWidgetView(widget: widget)
            case "table":
                TableWidgetView(widget: widget)
            case "chart":
                ChartWidgetView(widget: widget)
            case "list":
                ListWidgetView(widget: widget)
            case "webview":
                WebviewWidgetView(widget: widget)
            default:
                VStack {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Unknown: \(widget.type)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .padding(12)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Add Project Sheet

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var projectPath = ""
    let onAdd: (String, String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Project")
                .font(.headline)
            TextField("Project Name", text: $projectName)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Project Path", text: $projectPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        projectPath = url.path
                        if projectName.isEmpty {
                            projectName = url.lastPathComponent
                        }
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    guard !projectName.isEmpty, !projectPath.isEmpty else { return }
                    onAdd(projectName, projectPath)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.isEmpty || projectPath.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
