import SwiftUI
import ScarfCore
import ScarfDesign

/// Routing for "the user picked a project in the main sidebar".
///
/// Extracted from the view so the three things a click has to do — put
/// the app in the Projects area, remember the name across relaunch, and
/// tell the view model to select (which kicks its dashboard probe off
/// the main actor) — are asserted in one place by tests rather than
/// re-derived at each call site.
@MainActor
enum SidebarProjectNavigator {
    static func select(
        _ project: ProjectEntry,
        coordinator: AppCoordinator,
        viewModel: ProjectsViewModel
    ) {
        coordinator.selectedProjectName = project.name
        // `selectProject` clears the dashboard glyph and re-probes on a
        // detached task — no transport work happens on this actor here.
        viewModel.selectProject(project)
        coordinator.selectedSection = .projects
    }
}

/// The Projects section of the main sidebar: the registry rendered
/// inline inside a "well" (a recessed, bordered container) so it reads
/// as a place rather than one more nav row.
///
/// This REPLACES the old in-area second sidebar (`ProjectsSidebar`).
/// Everything that view uniquely owned lives here now — the filter
/// field, folder grouping, the archived section, the per-project
/// context menu and the add/remove affordances — because there is no
/// longer a second list to own them, and the cockpit gets the whole
/// content area.
///
/// Renders purely from `ProjectsViewModel.projects`, whose setter is
/// equality-guarded, so a watcher tick carrying a byte-identical
/// registry costs nothing here. Nothing in this view reads the
/// transport in a body.
struct SidebarProjectsWell: View {
    @Bindable var viewModel: ProjectsViewModel

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(\.serverContext) private var serverContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    /// Above this many projects the list gets its own filter field and a
    /// scroll clamp, so a large registry can't push Monitor/Bots/Interact
    /// off the bottom of the sidebar.
    private static let filterThreshold = 8
    private static let maxListHeight: CGFloat = 320

    @State private var filterText = ""
    @State private var showArchived = false
    @State private var expandedFolders: Set<String> = []

    // Sheet + dialog state. The well is the only host now: it is alive in
    // every section, so a rename started from the sidebar still completes
    // if the user is looking at Chat.
    @State private var showingNewProjectSheet = false
    @State private var showingAddSheet = false
    @State private var showingUninstallSheet = false
    @State private var renameTarget: ProjectEntry?
    @State private var moveTarget: ProjectEntry?
    @State private var configEditorProject: ProjectEntry?
    @State private var chatSettingsTarget: ProjectEntry?
    @State private var pendingRemoveFromList: ProjectEntry?
    @State private var lastMutationErrorTitle = ""
    @State private var uninstallerViewModel: TemplateUninstallerViewModel

    /// Answers the context menu's two file-existence questions from a
    /// cache probed off-main. Moved here with the context menu it serves
    /// — `ProjectsView` no longer refreshes one per watcher tick.
    @State private var menuProbes = ProjectMenuProbeCache()

    init(viewModel: ProjectsViewModel, context: ServerContext) {
        self.viewModel = viewModel
        _uninstallerViewModel = State(initialValue: TemplateUninstallerViewModel(context: context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if viewModel.registryDamage != nil {
                damageRow
            }
            if viewModel.projects.count > Self.filterThreshold {
                filterField
            }
            listBody
            newProjectButton
        }
        .padding(ScarfSpace.s1 + 2)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundTertiary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
        // Container, not a label: `.contain` keeps every row individually
        // reachable while giving VoiceOver one stop that names the well.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Projects"))
        .task {
            // One registry read for the life of the window. Deliberately
            // NOT wired to `fileWatcher.lastChangeDate`: ProjectsView
            // already reloads this same (shared) view model on a tick,
            // and a second subscriber would double every read on a
            // remote context during a chat stream.
            await viewModel.reload()
            expandedFolders = Set(viewModel.folders)
            menuProbes.refresh(projects: viewModel.projects, context: serverContext)
        }
        .onChange(of: viewModel.projects) { _, projects in
            // The registry actually changed (the setter is equality-
            // guarded, so this does not fire on a no-op tick). A new
            // folder starts expanded so a just-completed move is visible.
            expandedFolders.formUnion(viewModel.folders)
            menuProbes.refresh(projects: projects, context: serverContext)
        }
        .sheet(isPresented: $showingNewProjectSheet) { newProjectSheet }
        .sheet(isPresented: $showingAddSheet) { addProjectSheet }
        .sheet(isPresented: $showingUninstallSheet) { uninstallSheet }
        .sheet(item: $renameTarget) { renameSheet($0) }
        .sheet(item: $moveTarget) { moveSheet($0) }
        .sheet(item: $configEditorProject) { project in
            ConfigEditorSheet(context: serverContext, project: project)
        }
        .sheet(item: $chatSettingsTarget) { project in
            ProjectChatSettingsSheet(
                context: serverContext,
                project: project,
                capabilities: capabilitiesStore?.capabilities ?? .empty
            )
        }
        .confirmationDialog(
            removeFromListDialogTitle,
            isPresented: Binding(
                get: { pendingRemoveFromList != nil },
                set: { if !$0 { pendingRemoveFromList = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoveFromList
        ) { project in
            removeFromListActions(project)
        } message: { project in
            Text(
                "\(project.name) will be removed from Scarf's project list. " +
                "Nothing on disk is touched — the folder, cron job, skills, and memory block all stay. " +
                "To actually remove installed files, use \"Uninstall Template…\" instead."
            )
        }
        // The single mutation-failure alert for the whole app: every
        // registry mutation the user can start now starts here.
        .onChange(of: viewModel.mutationError) { _, new in
            if let new { lastMutationErrorTitle = new.title }
        }
        .alert(
            lastMutationErrorTitle,
            isPresented: Binding(
                get: { viewModel.mutationError != nil },
                set: { if !$0 { viewModel.dismissMutationError() } }
            ),
            presenting: viewModel.mutationError
        ) { _ in
            Button("OK", role: .cancel) { viewModel.dismissMutationError() }
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: ScarfSpace.s1) {
            Text("Projects")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer(minLength: 0)
            if !viewModel.projects.isEmpty {
                Text(verbatim: "\(viewModel.projects.count)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .accessibilityLabel(Text("\(viewModel.projects.count) projects"))
            }
            Menu {
                Button("New Project…", systemImage: "sparkles") { showingNewProjectSheet = true }
                Button("Add Existing Folder…", systemImage: "folder.badge.plus") { showingAddSheet = true }
                Divider()
                Toggle(isOn: $showArchived) { Text("Show Archived") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .accessibilityLabel(Text("Project list options"))
            .accessibilityIdentifier("sidebar.projects.options")
        }
        .padding(.horizontal, ScarfSpace.s1 + 2)
        .padding(.top, ScarfSpace.s1)
        .padding(.bottom, ScarfSpace.s1)
    }

    /// Compact stand-in for the full `RegistryDamageBanner`, which needs
    /// the content area's width to say anything useful. This row exists
    /// so the damage is visible from every section (it used to be
    /// reachable only once you were already inside Projects) and routes
    /// to the banner, which carries the explanation, the backup path and
    /// the Project Doctor.
    private var damageRow: some View {
        Button {
            coordinator.selectedSection = .projects
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScarfColor.warning)
                    .accessibilityHidden(true)
                Text("List damaged — review")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ScarfSpace.s1 + 2)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.sm, style: .continuous)
                    .fill(ScarfColor.warning.opacity(0.16))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Scarf couldn't fully read your projects list — open Projects for details and repairs")
        .accessibilityLabel(Text("Projects list damaged"))
        .accessibilityHint(Text("Opens the Projects area, where the full notice and Project Doctor are"))
        .accessibilityIdentifier("sidebar.projects.damage")
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .accessibilityHidden(true)
            TextField("Filter", text: $filterText)
                .textFieldStyle(.plain)
                .scarfStyle(.caption)
                .accessibilityLabel(Text("Filter projects"))
                .accessibilityIdentifier("sidebar.projects.filter")
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .scarfStyle(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Clear filter"))
            }
        }
        .padding(.horizontal, ScarfSpace.s1 + 2)
        .padding(.vertical, 3)
    }

    // MARK: - List

    @ViewBuilder
    private var listBody: some View {
        if viewModel.projects.isEmpty {
            Text("No projects yet.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .padding(.horizontal, ScarfSpace.s1 + 2)
                .padding(.vertical, ScarfSpace.s2)
        } else if noMatches {
            Text("No matches.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .padding(.horizontal, ScarfSpace.s1 + 2)
                .padding(.vertical, ScarfSpace.s2)
        } else if viewModel.projects.count > Self.filterThreshold {
            // Clamp + scroll rather than growing without bound: the
            // whole sidebar is one ScrollView, and a 200-project
            // registry would otherwise push Monitor/Bots/Interact off
            // the bottom entirely.
            //
            // The height is `min(estimated content, cap)` and not just
            // the cap: a ScrollView is greedy along its scroll axis, so
            // offering it a flat `maxHeight` would reserve the full
            // 320pt for a nine-project list and leave a slab of empty
            // well under it.
            ScrollView {
                rows
            }
            .frame(height: min(Self.maxListHeight, estimatedRowsHeight))
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(topLevelVisible) { projectRow($0) }

            ForEach(visibleFolders, id: \.self) { folder in
                folderGroup(folder)
            }

            if showArchived, !archivedVisible.isEmpty {
                archivedGroup
            }
        }
    }

    @ViewBuilder
    private func folderGroup(_ folder: String) -> some View {
        let children = folderProjects(folder)
        let expanded = expandedFolders.contains(folder)
        VStack(alignment: .leading, spacing: 1) {
            disclosureHeader(
                title: folder,
                systemImage: "folder",
                count: children.count,
                isExpanded: expanded
            ) {
                if expanded { expandedFolders.remove(folder) } else { expandedFolders.insert(folder) }
            }
            if expanded {
                ForEach(children) { project in
                    projectRow(project, indent: 12)
                }
            }
        }
    }

    @ViewBuilder
    private var archivedGroup: some View {
        // Archived rows are always shown expanded — the Show Archived
        // toggle in the header menu is already the disclosure.
        VStack(alignment: .leading, spacing: 1) {
            disclosureHeader(
                title: String(localized: "Archived"),
                systemImage: "archivebox",
                count: archivedVisible.count,
                isExpanded: true
            ) {
                showArchived = false
            }
            ForEach(archivedVisible) { project in
                projectRow(project, indent: 12).opacity(0.7)
            }
        }
    }

    private func disclosureHeader(
        title: String,
        systemImage: String,
        count: Int,
        isExpanded: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(verbatim: title)
                    .scarfStyle(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(verbatim: "\(count)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, ScarfSpace.s1 + 2)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title), \(count) projects"))
        .accessibilityValue(Text(isExpanded ? "expanded" : "collapsed"))
        .accessibilityHint(Text("Shows or hides the projects in this group"))
        .accessibilityIdentifier("sidebar.projects.group.\(title)")
    }

    private func projectRow(_ project: ProjectEntry, indent: CGFloat = 0) -> some View {
        let isActive = coordinator.selectedSection == .projects
            && viewModel.selectedProject == project
        return Button {
            SidebarProjectNavigator.select(project, coordinator: coordinator, viewModel: viewModel)
        } label: {
            HStack(spacing: 7) {
                Image(
                    systemName: isActive && viewModel.selectedHasDashboard
                        ? "square.grid.2x2.fill"
                        : "square.grid.2x2"
                )
                .font(.system(size: 11))
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
                Text(verbatim: project.name)
                    .scarfStyle(isActive ? .bodyEmph : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, ScarfSpace.s1 + 2 + indent)
            .padding(.trailing, ScarfSpace.s1 + 2)
            .padding(.vertical, 4)
            .foregroundStyle(isActive ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(isActive ? ScarfColor.accentTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: projectRowLabel(project)))
        // Selection is colour-only in the row, so it needs the trait.
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityIdentifier("sidebar.projects.row.\(project.name)")
        .contextMenu { contextMenu(project) }
    }

    /// Spoken row label: name first, then the state a user can't get
    /// from the name alone.
    private func projectRowLabel(_ project: ProjectEntry) -> String {
        var parts = [project.name]
        if let folder = project.folder, !folder.isEmpty {
            parts.append(String(localized: "in \(folder)"))
        }
        if project.archived {
            parts.append(String(localized: "archived"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - New Project

    private var newProjectButton: some View {
        Button {
            showingNewProjectSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text("New Project")
                    .scarfStyle(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ScarfColor.accent)
            .padding(.horizontal, ScarfSpace.s1 + 2)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Create a new project with the setup wizard")
        .accessibilityIdentifier("sidebar.projects.newProject")
        .padding(.top, 2)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(_ project: ProjectEntry) -> some View {
        Button("Upgrade Project…", systemImage: "sparkles") {
            let hasKanban = capabilitiesStore?.capabilities.hasKanban ?? false
            Task { await coordinator.upgradeProject(project, context: serverContext, hasKanban: hasKanban) }
        }
        .accessibilityIdentifier("projects.contextMenu.upgrade")
        Divider()
        if menuProbes.isConfigurable(project) {
            Button("Configuration…", systemImage: "slider.horizontal.3") {
                configEditorProject = project
            }
            Divider()
        }
        // Same gate the old second sidebar used: at least ONE of the RPCs
        // the sheet configures has to exist on the host, or nobody gets an
        // option that wouldn't apply at runtime.
        if let caps = capabilitiesStore?.capabilities,
           caps.hasACPSetSessionModel || caps.hasSessionEditAutoApproval {
            Button("Chat Settings…", systemImage: "bubble.left.and.text.bubble.right") {
                chatSettingsTarget = project
            }
            .accessibilityIdentifier("projects.contextMenu.chatSettings")
            Divider()
        }
        Button("Rename…", systemImage: "pencil") { renameTarget = project }
        Button("Move to Folder…", systemImage: "folder") { moveTarget = project }
        if project.archived {
            Button("Unarchive", systemImage: "tray.and.arrow.up") {
                Task { await viewModel.unarchiveProject(project) }
            }
        } else {
            Button("Archive", systemImage: "archivebox") {
                Task { await viewModel.archiveProject(project) }
            }
        }
        Divider()
        if menuProbes.hasInstalledTemplate(project) {
            Button("Uninstall Template (remove installed files)…", systemImage: "trash") {
                uninstallerViewModel.begin(project: project)
                showingUninstallSheet = true
            }
            .accessibilityIdentifier("projects.contextMenu.uninstallTemplate")
            Divider()
        }
        Button("Remove from List (keep files)…", systemImage: "minus.circle") {
            pendingRemoveFromList = project
        }
    }

    private var removeFromListDialogTitle: LocalizedStringKey {
        "Remove from Scarf's project list?"
    }

    @ViewBuilder
    private func removeFromListActions(_ project: ProjectEntry) -> some View {
        Button("Remove from List") {
            pendingRemoveFromList = nil
            // Deferred so the registry write — and any failure alert it
            // raises — happens after this dialog has finished dismissing.
            Task { @MainActor in
                // The removal has to succeed BEFORE the irreversible side
                // work: stripping the secrets block and clearing the
                // selection for a project still in the registry leaves a
                // worse state than not trying at all.
                guard await viewModel.removeProject(project) else { return }
                // OFF THE MAIN ACTOR: unmirroring reads and rewrites the
                // project's `.env` through the transport, which on a
                // remote context is blocking SSH (charter C10). Still
                // awaited — ordering below depends on it.
                let ctx = serverContext
                await Task.detached(priority: .userInitiated) {
                    try? KeychainEnvMirror(context: ctx).unmirror(project: project)
                }.value
                if coordinator.selectedProjectName == project.name {
                    coordinator.selectedProjectName = nil
                }
            }
        }
        Button("Cancel", role: .cancel) { pendingRemoveFromList = nil }
    }

    // MARK: - Sheets

    private var newProjectSheet: some View {
        NewProjectSheet(viewModel: NewProjectViewModel(context: serverContext)) { entry in
            // The chat handoff is staged by `NewProjectSheet.runCommit`;
            // this just makes sure the project is in the list (and
            // selected) for when the user comes back. Off-main because
            // `reload()` reads the registry through the transport.
            Task {
                await viewModel.reload()
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
    }

    private var addProjectSheet: some View {
        AddProjectSheet(context: serverContext) { name, path in
            Task { @MainActor in
                await viewModel.addProject(name: name, path: path)
                fileWatcher.updateProjectWatches(
                    dashboardPaths: viewModel.dashboardPaths,
                    scarfDirs: viewModel.projectScarfDirs
                )
            }
        }
    }

    private var uninstallSheet: some View {
        TemplateUninstallSheet(viewModel: uninstallerViewModel) { removed in
            if viewModel.selectedProject?.path == removed.path {
                viewModel.selectedProject = nil
            }
            if coordinator.selectedProjectName == removed.name {
                coordinator.selectedProjectName = nil
            }
            Task {
                await viewModel.reload()
                fileWatcher.updateProjectWatches(
                    dashboardPaths: viewModel.dashboardPaths,
                    scarfDirs: viewModel.projectScarfDirs
                )
                // An uninstall removes the template lock file the probe
                // cache answers from.
                menuProbes.invalidate()
                menuProbes.refresh(projects: viewModel.projects, context: serverContext)
            }
        }
    }

    private func renameSheet(_ target: ProjectEntry) -> some View {
        RenameProjectSheet(
            project: target,
            existingNames: viewModel.projects.filter { $0.name != target.name }.map(\.name)
        ) { newName in
            Task { @MainActor in await viewModel.renameProject(target, to: newName) }
        }
    }

    private func moveSheet(_ target: ProjectEntry) -> some View {
        MoveToFolderSheet(project: target, existingFolders: viewModel.folders) { newFolder in
            Task { @MainActor in await viewModel.moveProject(target, toFolder: newFolder) }
        }
    }

    // MARK: - Derived data

    /// Case-insensitive substring match on name + path + folder. Same
    /// behaviour the removed second sidebar had; the registry is tens of
    /// entries, not thousands.
    private func matches(_ project: ProjectEntry) -> Bool {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if project.name.lowercased().contains(needle) { return true }
        if project.path.lowercased().contains(needle) { return true }
        if let folder = project.folder, folder.lowercased().contains(needle) { return true }
        return false
    }

    private var topLevelVisible: [ProjectEntry] {
        viewModel.projects
            .filter { ($0.folder ?? "").isEmpty && !$0.archived && matches($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var visibleFolders: [String] {
        viewModel.folders.filter { !folderProjects($0).isEmpty }
    }

    private func folderProjects(_ folder: String) -> [ProjectEntry] {
        viewModel.projects
            .filter { $0.folder == folder && !$0.archived && matches($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var archivedVisible: [ProjectEntry] {
        viewModel.projects
            .filter { $0.archived && matches($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The registry has projects but the current filter hides all of
    /// them — a distinct state from "no projects", and one the old
    /// `List`-based sidebar rendered as a confusing blank.
    /// Rough height of what `rows` is about to draw, used only to stop
    /// the scroll clamp from over-reserving. Deliberately an estimate:
    /// a real measurement would need a GeometryReader feedback loop for
    /// something whose only job is to pick between "as tall as it needs"
    /// and "capped".
    private var estimatedRowsHeight: CGFloat {
        let rowHeight: CGFloat = 24
        var count = topLevelVisible.count
        for folder in visibleFolders {
            count += 1 // the folder's own disclosure header
            if expandedFolders.contains(folder) { count += folderProjects(folder).count }
        }
        if showArchived, !archivedVisible.isEmpty { count += archivedVisible.count + 1 }
        return CGFloat(count) * rowHeight
    }

    private var noMatches: Bool {
        topLevelVisible.isEmpty
            && visibleFolders.isEmpty
            && !(showArchived && !archivedVisible.isEmpty)
    }
}
