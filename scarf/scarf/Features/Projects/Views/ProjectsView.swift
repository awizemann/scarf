import SwiftUI

struct ProjectsView: View {
    @State private var viewModel = ProjectsViewModel()
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @State private var showingAddSheet = false

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

    @ViewBuilder
    private var dashboardArea: some View {
        if let dashboard = viewModel.dashboard {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    dashboardHeader(dashboard)
                    ForEach(dashboard.sections) { section in
                        DashboardSectionView(section: section)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - Section View

struct DashboardSectionView: View {
    let section: DashboardSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.headline)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: section.columnCount),
                spacing: 12
            ) {
                ForEach(section.widgets) { widget in
                    WidgetView(widget: widget)
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
