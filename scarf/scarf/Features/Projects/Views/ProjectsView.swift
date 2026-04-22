import SwiftUI
import ScarfCore
import UniformTypeIdentifiers

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
    @State private var installerViewModel: TemplateInstallerViewModel
    @State private var uninstallerViewModel: TemplateUninstallerViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(\.serverContext) private var serverContext
    @State private var showingAddSheet = false
    @State private var showingInstallSheet = false
    @State private var exportSheetProject: ProjectEntry?
    @State private var showingInstallURLPrompt = false
    @State private var installURLInput = ""
    @State private var showingUninstallSheet = false
    @State private var configEditorProject: ProjectEntry?
    /// Project queued for the "remove from list" confirmation dialog.
    /// Non-nil while the dialog is up; the `confirmationDialog` binding
    /// flips based on presence. We store the full entry (not just a
    /// flag) so the dialog's action closure knows which project to
    /// drop from the registry.
    @State private var pendingRemoveFromList: ProjectEntry?

    private let uninstaller: ProjectTemplateUninstaller

    init(context: ServerContext) {
        _viewModel = State(initialValue: ProjectsViewModel(context: context))
        _installerViewModel = State(initialValue: TemplateInstallerViewModel(context: context))
        _uninstallerViewModel = State(initialValue: TemplateUninstallerViewModel(context: context))
        self.uninstaller = ProjectTemplateUninstaller(context: context)
    }

    /// True when the given project has a cached manifest (i.e. was
    /// installed from a schemaful template). Cheap — just a file
    /// existence check via the transport.
    private func isConfigurable(_ project: ProjectEntry) -> Bool {
        let path = ProjectConfigService.manifestCachePath(for: project)
        return serverContext.makeTransport().fileExists(path)
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
        .toolbar { templatesToolbar }
        .task {
            viewModel.load()
            if let name = coordinator.selectedProjectName,
               let project = viewModel.projects.first(where: { $0.name == name }) {
                viewModel.selectProject(project)
            }
            fileWatcher.updateProjectWatches(viewModel.dashboardPaths)
            // Cold-launch deep link or Finder double-click: the router may
            // have a URL staged before this view installed the onChange
            // observer below. Without this first-appearance check,
            // SwiftUI's .onChange would never fire (it only reacts to
            // *changes* after installation) and the URL would sit on the
            // singleton forever.
            if let pending = TemplateURLRouter.shared.pendingInstallURL {
                dispatchPendingInstall(pending)
            }
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            viewModel.load()
            fileWatcher.updateProjectWatches(viewModel.dashboardPaths)
        }
        .onChange(of: TemplateURLRouter.shared.pendingInstallURL) { _, new in
            // A URL landed *while the app was already running*.
            if let new {
                dispatchPendingInstall(new)
            }
        }
        .sheet(isPresented: $showingInstallSheet) {
            TemplateInstallSheet(viewModel: installerViewModel) { entry in
                viewModel.load()
                coordinator.selectedProjectName = entry.name
                if let project = viewModel.projects.first(where: { $0.name == entry.name }) {
                    viewModel.selectProject(project)
                }
                fileWatcher.updateProjectWatches(viewModel.dashboardPaths)
            }
        }
        .sheet(item: $exportSheetProject) { project in
            TemplateExportSheet(
                viewModel: TemplateExporterViewModel(context: serverContext, project: project)
            )
        }
        .sheet(isPresented: $showingInstallURLPrompt) {
            installURLSheet
        }
        .sheet(isPresented: $showingUninstallSheet) {
            TemplateUninstallSheet(viewModel: uninstallerViewModel) { removed in
                // Refresh the registry and clear selection if we just
                // removed the project the user was viewing.
                if viewModel.selectedProject?.path == removed.path {
                    viewModel.selectedProject = nil
                }
                if coordinator.selectedProjectName == removed.name {
                    coordinator.selectedProjectName = nil
                }
                viewModel.load()
                fileWatcher.updateProjectWatches(viewModel.dashboardPaths)
            }
        }
        .sheet(item: $configEditorProject) { project in
            ConfigEditorSheet(
                context: serverContext,
                project: project
            )
        }
        // Confirmation dialog for the sidebar's "Remove from List" action.
        // The action is registry-only (doesn't touch disk), but the name
        // historically confused users into thinking it was a full delete.
        // A confirmation with explicit wording clarifies scope before the
        // click is destructive-looking but actually harmless.
        .confirmationDialog(
            removeFromListDialogTitle,
            isPresented: Binding(
                get: { pendingRemoveFromList != nil },
                set: { if !$0 { pendingRemoveFromList = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoveFromList
        ) { project in
            Button("Remove from List") {
                viewModel.removeProject(project)
                if coordinator.selectedProjectName == project.name {
                    coordinator.selectedProjectName = nil
                }
                pendingRemoveFromList = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoveFromList = nil
            }
        } message: { project in
            Text(
                "\(project.name) will be removed from Scarf's project list. " +
                "Nothing on disk is touched — the folder, cron job, skills, and memory block all stay. " +
                "To actually remove installed files, use \"Uninstall Template…\" instead."
            )
        }
    }

    /// Title string for the remove-from-list confirmation dialog. Kept
    /// as a computed property so the dialog and any future reuse share
    /// the exact same copy.
    private var removeFromListDialogTitle: LocalizedStringKey {
        "Remove from Scarf's project list?"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var templatesToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Install from File…", systemImage: "tray.and.arrow.down") {
                    openInstallFilePicker()
                }
                Button("Install from URL…", systemImage: "link") {
                    installURLInput = ""
                    showingInstallURLPrompt = true
                }
                Divider()
                if let selected = viewModel.selectedProject {
                    Button("Export \"\(selected.name)\" as Template…", systemImage: "tray.and.arrow.up") {
                        exportSheetProject = selected
                    }
                } else {
                    Button("Export as Template…", systemImage: "tray.and.arrow.up") {}
                        .disabled(true)
                }
            } label: {
                Label("Templates", systemImage: "shippingbox")
            }
        }
    }

    private var installURLSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Template from URL")
                .font(.headline)
            Text("Paste an https URL pointing at a .scarftemplate file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://example.com/my.scarftemplate", text: $installURLInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showingInstallURLPrompt = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Install") {
                    if let url = URL(string: installURLInput), url.scheme?.lowercased() == "https" {
                        installerViewModel.openRemoteURL(url)
                        showingInstallURLPrompt = false
                        showingInstallSheet = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(URL(string: installURLInput)?.scheme?.lowercased() != "https")
            }
        }
        .padding()
        .frame(minWidth: 480)
    }

    /// Route a pending install URL to the right VM entry point. `file://`
    /// URLs come from Finder double-clicks + the "Install from File…" flow
    /// when routed via the router; `https://` URLs come from `scarf://`
    /// deep links and the "Install from URL…" prompt.
    private func dispatchPendingInstall(_ url: URL) {
        if url.isFileURL {
            installerViewModel.openLocalFile(url.path)
        } else {
            installerViewModel.openRemoteURL(url)
        }
        TemplateURLRouter.shared.consume()
        showingInstallSheet = true
    }

    private func openInstallFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Accept both the declared Scarf template UTI and plain zip — the
        // custom UTI wins for files with the .scarftemplate extension, and
        // the zip fallback means an author distributing under .zip (e.g.
        // before the UTI is registered on the receiving Mac) still works.
        var types: [UTType] = [.zip]
        if let templateType = UTType("com.scarf.template") {
            types.insert(templateType, at: 0)
        }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.prompt = String(localized: "Install Template")
        if panel.runModal() == .OK, let url = panel.url {
            installerViewModel.openLocalFile(url.path)
            showingInstallSheet = true
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
                .contextMenu {
                    if isConfigurable(project) {
                        Button("Configuration…", systemImage: "slider.horizontal.3") {
                            configEditorProject = project
                        }
                    }
                    if uninstaller.isTemplateInstalled(project: project) {
                        // "Uninstall Template…" only appears for projects
                        // installed from a `.scarftemplate`. Trailing
                        // ellipsis signals a confirmation sheet follows
                        // (macOS HIG convention); the sheet itself lists
                        // every file/cron/skill that will be removed.
                        Button("Uninstall Template (remove installed files)…", systemImage: "trash") {
                            uninstallerViewModel.begin(project: project)
                            showingUninstallSheet = true
                        }
                        Divider()
                    }
                    // "Remove from List" used to be "Remove from Scarf",
                    // which users read as a full delete. Clarified label +
                    // ellipsis + confirmation dialog all spell out that
                    // this is registry-only; nothing on disk is touched.
                    Button("Remove from List (keep files)…", systemImage: "minus.circle") {
                        pendingRemoveFromList = project
                    }
                }
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
                    // Route through the same confirmation dialog as the
                    // context-menu "Remove from List" entry. The minus
                    // icon is a drive-by click target right next to "+" —
                    // confirming before mutating the registry stops the
                    // "I clicked by accident and my project's gone" case.
                    Button(action: { pendingRemoveFromList = selected }) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(selected.name) from Scarf's project list (files are kept on disk)")
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
                if isConfigurable(project) {
                    Button {
                        configEditorProject = project
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit configuration")
                }
                if uninstaller.isTemplateInstalled(project: project) {
                    Button {
                        uninstallerViewModel.begin(project: project)
                        showingUninstallSheet = true
                    } label: {
                        Image(systemName: "shippingbox.and.arrow.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Uninstall template")
                }
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
