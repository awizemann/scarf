import SwiftUI
import ScarfCore
import ScarfDesign
import UniformTypeIdentifiers

struct ProjectsView: View {
    /// Owned by `AppCoordinator`'s per-window cache and SHARED with the
    /// main sidebar's projects well, which is now the only project
    /// navigation. This view no longer renders a list of its own.
    @Bindable var viewModel: ProjectsViewModel
    @State private var installerViewModel: TemplateInstallerViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(\.serverContext) private var serverContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    /// "Add existing folder" from the empty state. The sidebar well has
    /// its own copy of this affordance; this one exists so a user with
    /// zero projects has something to click in the middle of the window.
    @State private var showingAddSheet = false
    @State private var showingInstallSheet = false
    @State private var exportSheetProject: ProjectEntry?
    @State private var showingInstallURLPrompt = false
    @State private var installURLInput = ""
    @State private var showingCatalogSheet = false

    /// Project Doctor sheet, opened from the registry-damage banner —
    /// Phase 2 left that banner with nothing to act on.
    @State private var showingDoctorSheet = false

    init(viewModel: ProjectsViewModel, context: ServerContext) {
        self.viewModel = viewModel
        _installerViewModel = State(initialValue: TemplateInstallerViewModel(context: context))
    }


    var body: some View {
        // ScarfMon — counts each ProjectsView body evaluation. Pair with
        // `widget.<type>.load` to spot churn that re-fires file-reading
        // widgets unnecessarily.
        let _: Void = ScarfMon.event(.render, "mac.dashboard.body")
        return VStack(spacing: 0) {
            // The full notice lives here, above the cockpit, because it
            // needs the width to explain itself and to offer the backup
            // path + Project Doctor. The main sidebar's well shows a
            // compact warning that routes here.
            if let damage = viewModel.registryDamage {
                RegistryDamageBanner(
                    damage: damage,
                    isRemote: serverContext.isRemote,
                    onOpenDoctor: { showingDoctorSheet = true },
                    onDismiss: { viewModel.dismissRegistryDamage() }
                )
                Divider()
            }
            // No second sidebar any more — the main sidebar's projects
            // well IS the navigation, so the cockpit takes the whole
            // content area.
            dashboardArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Projects")
        .toolbar { templatesToolbar }
        .sheet(isPresented: $showingDoctorSheet, onDismiss: {
            // Repairs rewrite the registry; the list and the banner both
            // describe what was on disk before them.
            Task { await viewModel.reload() }
        }) {
            ProjectDoctorSheet()
        }
        .task {
            await viewModel.reload()
            // Phase-1: lazily migrate existing projects to the first-class
            // ScarfProject model — write each `.scarf/project.json` record
            // and back-fill the registry UUID. Additive, idempotent, and
            // non-fatal (errors are swallowed per-entry); runs off-main and
            // writes nothing once every project is already migrated.
            let migrationContext = serverContext
            Task.detached(priority: .utility) {
                _ = ProjectStore(context: migrationContext).derive()
            }
            if let name = coordinator.selectedProjectName,
               let project = viewModel.projects.first(where: { $0.name == name }) {
                viewModel.selectProject(project)
            }
            fileWatcher.updateProjectWatches(dashboardPaths: viewModel.dashboardPaths, scarfDirs: viewModel.projectScarfDirs)
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
            // Off-main refresh: `reload()` does the registry/dashboard
            // transport reads on a detached task so a watcher tick (which
            // fires per persisted message during an active stream) can't
            // stall the main thread on a remote context (gh#102 pattern).
            Task {
                await viewModel.reload()
                fileWatcher.updateProjectWatches(dashboardPaths: viewModel.dashboardPaths, scarfDirs: viewModel.projectScarfDirs)
            }
        }
        .onChange(of: TemplateURLRouter.shared.pendingInstallURL) { _, new in
            // A URL landed *while the app was already running*.
            if let new {
                dispatchPendingInstall(new)
            }
        }
        .sheet(isPresented: $showingInstallSheet) {
            TemplateInstallSheet(viewModel: installerViewModel) { entry in
                // `reload()`, not `load()`: the synchronous form does the
                // registry read (and, on the damage path, a `.bak` stat)
                // ON THE MAIN ACTOR — blocking SSH behind a sheet
                // dismissal on a remote context (charter C10). Everything
                // downstream of the read moves into the Task with it.
                Task {
                    await viewModel.reload()
                    coordinator.selectedProjectName = entry.name
                    if let project = viewModel.projects.first(where: { $0.name == entry.name }) {
                        viewModel.selectProject(project)
                    }
                    fileWatcher.updateProjectWatches(dashboardPaths: viewModel.dashboardPaths, scarfDirs: viewModel.projectScarfDirs)
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddProjectSheet(context: serverContext) { name, path in
                // Running the mutation on the next main-actor turn keeps
                // its failure alert (hosted by the sidebar well) out of
                // this sheet's dismissal transaction.
                Task { @MainActor in
                    await viewModel.addProject(name: name, path: path)
                    fileWatcher.updateProjectWatches(
                        dashboardPaths: viewModel.dashboardPaths,
                        scarfDirs: viewModel.projectScarfDirs
                    )
                }
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
        .sheet(isPresented: $showingCatalogSheet) {
            CatalogView { url in
                // Hand the catalog's HTTPS URL to the existing install
                // flow — no new entry-point logic, just a different
                // way to surface the URL. The install sheet's
                // `awaitingParentDirectory` stage takes over from here.
                installerViewModel.openRemoteURL(url, source: .hub)
                showingCatalogSheet = false
                showingInstallSheet = true
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var templatesToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                // "New Project from Scratch…" moved to the sidebar's
                // projects well, next to the list it adds to. This menu
                // is now purely about templates.
                Button("Browse Catalog…", systemImage: "books.vertical") {
                    showingCatalogSheet = true
                }
                .accessibilityIdentifier("templates.browseCatalog")
                Divider()
                Button("Install from File…", systemImage: "tray.and.arrow.down") {
                    openInstallFilePicker()
                }
                .accessibilityIdentifier("templates.installFromFile")
                Button("Install from URL…", systemImage: "link") {
                    installURLInput = ""
                    showingInstallURLPrompt = true
                }
                .accessibilityIdentifier("templates.installFromURL")
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
            // `.accessibilityElement(children: .ignore)` collapses
            // the inner Label's automatic accessibility tree so our
            // explicit identifier sticks. Without it, SwiftUI uses
            // the systemImage name (`chevron.down` in macOS toolbar
            // contexts) as the menu button's accessibility identifier
            // and our `.accessibilityIdentifier` is silently
            // overridden — verified via XCUITest tree dump.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Templates")
            .accessibilityIdentifier("templates.toolbar.menu")
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
                .accessibilityIdentifier("templates.installURL.field")
                .accessibilityLabel("Template URL")
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
                .accessibilityIdentifier("templates.installURL.confirm")
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

    // MARK: - Detail Area

    /// The project detail pane is the cockpit — the single per-project
    /// "mission control" that aggregates every facet as panels (Dashboard
    /// widgets, Sessions, Board, Site, Context, Cron, Memory, Secrets,
    /// Templates, Slash, Mini-apps, Fleet). It renders for EVERY selected
    /// project, not only ones with a `.scarf/dashboard.json` — the legacy
    /// dashboard is now the cockpit's Dashboard panel, so old projects keep
    /// working while gaining the first-class facets (incl. Fleet).
    @ViewBuilder
    private var dashboardArea: some View {
        if let project = viewModel.selectedProject {
            ProjectCockpitView(project: project)
        } else if viewModel.projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "square.grid.2x2")
            } description: {
                Text("Add a project folder to get started.")
            } actions: {
                Button("Add Project") { showingAddSheet = true }
            }
        } else {
            ContentUnavailableView {
                Label("Select a Project", systemImage: "square.grid.2x2")
            } description: {
                Text("Choose a project from the sidebar to view its cockpit.")
            }
        }
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
            case "cron_status":
                CronStatusWidgetView(widget: widget)
            case "log_tail":
                LogTailWidgetView(widget: widget)
            case "markdown_file":
                MarkdownFileWidgetView(widget: widget)
            case "image":
                ImageWidgetView(widget: widget)
            case "status_grid":
                StatusGridWidgetView(widget: widget)
            case "kanban_summary":
                KanbanSummaryWidgetView(widget: widget)
            default:
                WidgetErrorCard(
                    title: widget.title,
                    reason: "Unknown widget type: \"\(widget.type)\"",
                    hint: "This Scarf build doesn't render this widget type. Update Scarf or change the widget type in dashboard.json. Known types are listed in tools/widget-schema.json."
                )
            }
        }
    }
}

// MARK: - Add Project Sheet

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var projectPath = ""
    /// Inline verification result for remote contexts (issue #54).
    /// Renders alongside the path field as a green check / red x so
    /// users learn whether a remote path is valid BEFORE they hit Add
    /// and the agent's tool calls fail at runtime.
    @State private var remoteVerification: RemoteVerification = .idle
    /// Active server context. On remote contexts the local Browse
    /// button is hidden (NSOpenPanel browses the Mac filesystem,
    /// useless when the project lives on a remote host) and replaced
    /// with a Verify button driven by the SSH transport's `stat`.
    let context: ServerContext
    let onAdd: (String, String) -> Void

    private enum RemoteVerification: Equatable {
        case idle
        case verifying
        case ok(String)        // green: "Directory exists (1.2k items)" etc.
        case warn(String)      // red: missing / not a dir / unreadable
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Project")
                .font(.headline)
            TextField("Project Name", text: $projectName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Project Name")
            VStack(alignment: .leading, spacing: 6) {
                pathInputRow
                if context.isRemote {
                    Text("Path on \(context.displayName) — must already exist on the server. Tool calls run with this directory as their working directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    verificationBadge
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
        .frame(width: 440)
    }

    @ViewBuilder
    private var pathInputRow: some View {
        HStack {
            TextField("Project Path", text: $projectPath)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Project Path")
                .onChange(of: projectPath) { _, _ in
                    // Stale verification once the path edits — reset to
                    // idle so users don't see a green check for a path
                    // they've since changed.
                    if remoteVerification != .idle {
                        remoteVerification = .idle
                    }
                }
            if context.isRemote {
                Button("Verify") {
                    Task { await verifyRemotePath() }
                }
                .disabled(projectPath.isEmpty || remoteVerification == .verifying)
            } else {
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
        }
    }

    @ViewBuilder
    private var verificationBadge: some View {
        switch remoteVerification {
        case .idle:
            EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking on \(context.displayName)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ok(let detail):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ScarfColor.success)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        case .warn(let detail):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScarfColor.warning)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
    }

    /// Verify the entered path on the remote via the existing SSH
    /// transport. Uses `stat` (not just `fileExists`) so we can reject
    /// files-that-aren't-dirs without a separate round trip.
    private func verifyRemotePath() async {
        let path = projectPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, context.isRemote else { return }
        remoteVerification = .verifying

        let snapshot = context
        let result: RemoteVerification = await Task.detached {
            let transport = snapshot.makeTransport()
            guard transport.fileExists(path) else {
                return .warn("Path doesn't exist on \(snapshot.displayName).")
            }
            guard let stat = transport.stat(path) else {
                // Stat failed even though `test -e` passed — typically
                // a permission issue on the parent dir. Surface as a
                // warning so the user knows the path is reachable but
                // not introspectable.
                return .warn("Found, but couldn't stat — check parent directory permissions.")
            }
            if stat.isDirectory {
                return .ok("Directory exists on \(snapshot.displayName).")
            } else {
                return .warn("Path is a file, not a directory. Project paths must be directories.")
            }
        }.value
        remoteVerification = result
    }
}
