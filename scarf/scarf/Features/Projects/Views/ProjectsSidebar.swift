import SwiftUI

/// Sidebar view for the Projects feature. Renders the registry as:
/// - A search field at the top (⌘F focus).
/// - Top-level (folder-less) projects.
/// - Collapsible DisclosureGroups, one per folder.
/// - An "Archived" DisclosureGroup at the bottom, hidden unless the
///   Show Archived toggle is on.
///
/// Selection is bound to `viewModel.selectedProject` so the
/// dashboard area stays in sync with clicks anywhere in the hierarchy.
/// Context-menu actions delegate back to the parent view via closures
/// so the sheets / confirmation dialogs stay co-located with the rest
/// of ProjectsView's state.
struct ProjectsSidebar: View {
    @Bindable var viewModel: ProjectsViewModel

    // Predicates hoisted from the parent — avoid reaching down into
    // service objects from this view.
    let canConfigureProject: (ProjectEntry) -> Bool
    let isTemplateInstalled: (ProjectEntry) -> Bool

    // Context-menu + bottom-bar callbacks. Parent owns sheet state
    // (install, uninstall, rename, move-to-folder, remove-from-list
    // confirmation dialog) — this view just routes user intent.
    let onConfigure: (ProjectEntry) -> Void
    let onUninstallTemplate: (ProjectEntry) -> Void
    let onRemoveFromList: (ProjectEntry) -> Void
    let onRename: (ProjectEntry) -> Void
    let onMoveToFolder: (ProjectEntry) -> Void
    let onAddProject: () -> Void

    /// Per-view UI state — filter text, show-archived toggle, and
    /// which folders are expanded. Folder expansion defaults to all
    /// open so a new user sees everything; they can collapse what
    /// they don't want.
    @State private var filterText: String = ""
    @State private var showArchived: Bool = false
    @State private var expandedFolders: Set<String> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
            Divider()
            bottomBar
        }
        .onAppear {
            // Start with every folder expanded on first render. If
            // users collapse, that choice persists for the lifetime
            // of the view instance (window open).
            expandedFolders = Set(viewModel.folders)
        }
        .onChange(of: viewModel.folders) { _, newFolders in
            // When a new folder appears (user just moved a project
            // into one), start it expanded so the move is visibly
            // reflected.
            expandedFolders.formUnion(newFolders)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter projects", text: $filterText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.caption)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - List

    private var list: some View {
        List(selection: Binding(
            get: { viewModel.selectedProject },
            set: { if let p = $0 { viewModel.selectProject(p) } }
        )) {
            // Top-level projects first — matches the Finder-like
            // mental model where top-level items sit above folders.
            ForEach(topLevelVisible) { project in
                projectRow(project)
            }

            // Per-folder collapsible sections.
            ForEach(visibleFolders, id: \.self) { folder in
                let children = folderProjects(folder)
                if !children.isEmpty {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedFolders.contains(folder) },
                            set: { expanded in
                                if expanded {
                                    expandedFolders.insert(folder)
                                } else {
                                    expandedFolders.remove(folder)
                                }
                            }
                        )
                    ) {
                        ForEach(children) { project in
                            projectRow(project)
                        }
                    } label: {
                        Label(folder, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Archived section — only surfaces under the toggle.
            if showArchived, !archivedVisible.isEmpty {
                DisclosureGroup {
                    ForEach(archivedVisible) { project in
                        projectRow(project)
                            .opacity(0.7)
                    }
                } label: {
                    Label("Archived (\(archivedVisible.count))", systemImage: "archivebox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func projectRow(_ project: ProjectEntry) -> some View {
        HStack {
            Image(
                systemName: viewModel.dashboard != nil
                    && viewModel.selectedProject == project
                    ? "square.grid.2x2.fill"
                    : "square.grid.2x2"
            )
            .foregroundStyle(.secondary)
            Text(project.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .tag(project)
        .contextMenu {
            projectContextMenu(project)
        }
    }

    @ViewBuilder
    private func projectContextMenu(_ project: ProjectEntry) -> some View {
        if canConfigureProject(project) {
            Button("Configuration…", systemImage: "slider.horizontal.3") {
                onConfigure(project)
            }
            Divider()
        }
        Button("Rename…", systemImage: "pencil") { onRename(project) }
        Button("Move to Folder…", systemImage: "folder") { onMoveToFolder(project) }
        if project.archived {
            Button("Unarchive", systemImage: "tray.and.arrow.up") {
                viewModel.unarchiveProject(project)
            }
        } else {
            Button("Archive", systemImage: "archivebox") {
                viewModel.archiveProject(project)
            }
        }
        Divider()
        if isTemplateInstalled(project) {
            Button("Uninstall Template (remove installed files)…", systemImage: "trash") {
                onUninstallTemplate(project)
            }
            Divider()
        }
        Button("Remove from List (keep files)…", systemImage: "minus.circle") {
            onRemoveFromList(project)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Button(action: onAddProject) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a project")

            Toggle(isOn: $showArchived) {
                Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(showArchived ? "Hide archived projects" : "Show archived projects")

            Spacer()

            if let selected = viewModel.selectedProject {
                Button(action: { onRemoveFromList(selected) }) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("Remove \(selected.name) from Scarf's project list (files are kept on disk)")
            }
        }
        .padding(8)
    }

    // MARK: - Derived data

    /// Fuzzy-match on name + path + folder label. Case-insensitive,
    /// substring — not a true fuzzy search, but matches the project
    /// count scale (tens, not thousands). Upgradable to a Levenshtein
    /// scorer later without changing the call sites.
    private func matches(_ project: ProjectEntry) -> Bool {
        let needle = filterText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return true }
        if project.name.lowercased().contains(needle) { return true }
        if project.path.lowercased().contains(needle) { return true }
        if let folder = project.folder, folder.lowercased().contains(needle) { return true }
        return false
    }

    /// Visible top-level projects (no folder, not archived, passes
    /// the current filter). Sort is stable by name — the registry
    /// already preserves insertion order, but showing a sorted list
    /// of homogeneous top-level entries feels cleaner.
    private var topLevelVisible: [ProjectEntry] {
        viewModel.projects
            .filter { ($0.folder ?? "").isEmpty && !$0.archived && matches($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Folders that currently have at least one matching, non-
    /// archived project. Folders with only archived projects move
    /// into the Archived section's items; empty folders disappear.
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
}
