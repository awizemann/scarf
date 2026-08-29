import SwiftUI
import ScarfCore
import ScarfDesign
import UniformTypeIdentifiers

struct ProjectsView: View {
    @State private var viewModel: ProjectsViewModel
    @State private var installerViewModel: TemplateInstallerViewModel
    @State private var uninstallerViewModel: TemplateUninstallerViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(\.serverContext) private var serverContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var showingAddSheet = false
    @State private var showingNewProjectSheet = false
    @State private var showingInstallSheet = false
    @State private var exportSheetProject: ProjectEntry?
    @State private var showingInstallURLPrompt = false
    @State private var installURLInput = ""
    @State private var showingCatalogSheet = false
    @State private var showingUninstallSheet = false
    @State private var configEditorProject: ProjectEntry?
    /// Project queued for the "remove from list" confirmation dialog.
    /// Non-nil while the dialog is up; the `confirmationDialog` binding
    /// flips based on presence. We store the full entry (not just a
    /// flag) so the dialog's action closure knows which project to
    /// drop from the registry.
    @State private var pendingRemoveFromList: ProjectEntry?

    /// Project queued for the rename sheet (v2.3). Sheet state lives
    /// on the parent view so the sidebar stays a pure presentation
    /// layer; rename logic routes through `ProjectsViewModel.renameProject`.
    @State private var renameTarget: ProjectEntry?

    /// Project queued for the move-to-folder sheet (v2.3). Same
    /// pattern as renameTarget: parent owns sheet state, sidebar
    /// delegates up.
    @State private var moveTarget: ProjectEntry?

    /// Project queued for the model-preset binding sheet.
    /// Parent owns the sheet state; the sidebar context-menu
    /// item only routes the user intent up via `onSetModel`.
    @State private var modelPresetTarget: ProjectEntry?

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

    var body: some View {
        // ScarfMon — counts each ProjectsView body evaluation. Pair with
        // `widget.<type>.load` to spot churn that re-fires file-reading
        // widgets unnecessarily.
        let _: Void = ScarfMon.event(.render, "mac.dashboard.body")
        return HSplitView {
            projectList
                .frame(minWidth: 180, maxWidth: 220)
            dashboardArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Projects")
        .toolbar { templatesToolbar }
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
                viewModel.load()
                coordinator.selectedProjectName = entry.name
                if let project = viewModel.projects.first(where: { $0.name == entry.name }) {
                    viewModel.selectProject(project)
                }
                fileWatcher.updateProjectWatches(dashboardPaths: viewModel.dashboardPaths, scarfDirs: viewModel.projectScarfDirs)
            }
        }
        .sheet(isPresented: $showingNewProjectSheet) {
            NewProjectSheet(
                viewModel: NewProjectViewModel(context: serverContext)
            ) { entry in
                // Reload the registry so the new project shows in the
                // sidebar, then select it. The chat handoff is staged
                // by `NewProjectSheet.runCommit` (it sets
                // `coordinator.pendingProjectChat` + `pendingInitialPrompt`
                // and switches `selectedSection` to `.chat`), so when
                // the user comes back to Projects later, the project
                // is already there.
                viewModel.load()
                coordinator.selectedProjectName = entry.name
                if let project = viewModel.projects.first(where: { $0.name == entry.name }) {
                    viewModel.selectProject(project)
                }
                fileWatcher.updateProjectWatches(
                    dashboardPaths: viewModel.dashboardPaths,
                    scarfDirs: viewModel.projectScarfDirs
                )
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
                fileWatcher.updateProjectWatches(dashboardPaths: viewModel.dashboardPaths, scarfDirs: viewModel.projectScarfDirs)
            }
        }
        .sheet(item: $configEditorProject) { project in
            ConfigEditorSheet(
                context: serverContext,
                project: project
            )
        }
        .sheet(item: $modelPresetTarget) { project in
            ProjectModelPresetSheet(
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
                // Strip the project's secrets block from ~/.hermes/.env
                // BEFORE removing it from the registry — the env-mirror
                // resolves slug via the cached manifest, which still
                // exists at this point. Failure is non-fatal: a stale
                // block in .env is benign (just unreachable env vars).
                do {
                    try KeychainEnvMirror(context: serverContext).unmirror(project: project)
                } catch {
                    // Silent: the mirror's own logger has already
                    // recorded the failure.
                }
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
                Button("New Project from Scratch…", systemImage: "sparkles") {
                    showingNewProjectSheet = true
                }
                .accessibilityIdentifier("templates.newProject")
                Divider()
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

    // MARK: - Project List

    private var projectList: some View {
        // Sidebar is an extracted view; this view stays the owner of
        // sheet state (add / rename / move / uninstall / remove-from-
        // list confirmation) and routes intents down as closures.
        ProjectsSidebar(
            viewModel: viewModel,
            canConfigureProject: { isConfigurable($0) },
            isTemplateInstalled: { uninstaller.isTemplateInstalled(project: $0) },
            onConfigure: { configEditorProject = $0 },
            onUpgrade: { project in
                let hasKanban = capabilitiesStore?.capabilities.hasKanban ?? false
                Task { await coordinator.upgradeProject(project, context: serverContext, hasKanban: hasKanban) }
            },
            onUninstallTemplate: { project in
                uninstallerViewModel.begin(project: project)
                showingUninstallSheet = true
            },
            onRemoveFromList: { pendingRemoveFromList = $0 },
            onRename: { renameTarget = $0 },
            onMoveToFolder: { moveTarget = $0 },
            onAddProject: { showingAddSheet = true },
            // Gate the "Set Model…" context menu entry on the host
            // supporting the session/set_model RPC (v0.13+). Pre-v0.13
            // hosts hide the menu item so users don't bind a preset
            // that wouldn't apply at runtime.
            onSetModel: (capabilitiesStore?.capabilities.hasACPSetSessionModel ?? false)
                ? { modelPresetTarget = $0 }
                : nil
        )
        .sheet(isPresented: $showingAddSheet) {
            AddProjectSheet(context: serverContext) { name, path in
                viewModel.addProject(name: name, path: path)
                fileWatcher.updateProjectWatches(dashboardPaths: viewModel.dashboardPaths, scarfDirs: viewModel.projectScarfDirs)
            }
        }
        .sheet(item: $renameTarget) { target in
            RenameProjectSheet(
                project: target,
                existingNames: viewModel.projects
                    .filter { $0.name != target.name }
                    .map(\.name)
            ) { newName in
                viewModel.renameProject(target, to: newName)
            }
        }
        .sheet(item: $moveTarget) { target in
            MoveToFolderSheet(
                project: target,
                existingFolders: viewModel.folders
            ) { newFolder in
                viewModel.moveProject(target, toFolder: newFolder)
            }
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
