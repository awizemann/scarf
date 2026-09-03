import Observation
import os

@Observable
@MainActor
public final class ProjectsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ProjectsViewModel")
    public let context: ServerContext
    private let service: ProjectDashboardService

    public init(context: ServerContext = .local) {
        self.context = context
        self.service = ProjectDashboardService(context: context)
    }


    public var projects: [ProjectEntry] = []
    public var selectedProject: ProjectEntry?
    public var dashboard: ProjectDashboard?
    public var dashboardError: String?
    public var isLoading = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration = 0

    /// Synchronous registry load — used by tests and one-shot call sites that
    /// read `projects` immediately afterward. A synchronous load on a remote
    /// context does blocking scp/SSH, so do NOT call this from a repeated /
    /// hot path (e.g. the file-watcher `.onChange`) — use `reload()` there.
    public func load() {
        apply(registry: service.loadRegistry())
        if let selected = selectedProject { loadDashboard(for: selected) }
    }

    /// Off-main registry (+ selected dashboard) refresh for hot paths like the
    /// file-watcher `.onChange`. Reads through the transport on a detached
    /// task, then commits to observable state back on the main actor — so a
    /// watcher tick never blocks the UI thread on a remote context (gh#102).
    public func reload() async {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let ctx = context
        let task = Task { [weak self] in
            // Recency by generation token, not `isCancelled`: a newer reload
            // bumps `reloadGeneration`, so an older read — even one that
            // crosses the dashboard suspension below — drops its commit rather
            // than clobbering fresher data. (`isCancelled` alone can't order
            // the `dashboard` write, which sits behind a second await.) The
            // synchronous `load()` this replaced couldn't interleave at all.
            let registry = await Task.detached { ProjectDashboardService(context: ctx).loadRegistry() }.value
            guard let self, generation == self.reloadGeneration else { return }
            self.apply(registry: registry)
            if let selected = self.selectedProject {
                await self.reloadDashboard(for: selected, generation: generation)
            }
        }
        reloadTask = task
        await task.value
    }

    private func apply(registry: ProjectRegistry) {
        projects = registry.projects
        if let selected = selectedProject, !projects.contains(where: { $0.name == selected.name }) {
            selectedProject = nil
            dashboard = nil
        }
    }

    public func selectProject(_ project: ProjectEntry) {
        selectedProject = project
        loadDashboard(for: project)
    }

    public func addProject(name: String, path: String) {
        var registry = service.loadRegistry()
        guard !registry.projects.contains(where: { $0.name == name }) else { return }
        let entry = ProjectEntry(name: name, path: path)
        registry.projects.append(entry)
        // saveRegistry throws now. The VM doesn't currently have a
        // surface for user-visible errors (there's no alert/toast in
        // the Projects view), so log at error level to the unified
        // log and keep the in-memory state consistent with whatever
        // landed on disk. If the write fails, the added entry won't
        // persist across launches — the user sees it appear + work
        // this session, then it's gone at relaunch. Not ideal, but
        // matches today's UX and flagged for a proper alert later.
        do {
            try service.saveRegistry(registry)
        } catch {
            logger.error("addProject couldn't persist registry: \(error.localizedDescription, privacy: .public)")
        }
        projects = registry.projects
        selectProject(entry)
    }

    public func removeProject(_ project: ProjectEntry) {
        var registry = service.loadRegistry()
        registry.projects.removeAll { $0.name == project.name }
        do {
            // Deliberate removal: removing the user's last project must
            // still be able to leave the registry empty.
            try service.saveRegistry(registry, allowEmpty: true)
        } catch {
            logger.error("removeProject couldn't persist registry: \(error.localizedDescription, privacy: .public)")
        }
        projects = registry.projects
        if selectedProject?.name == project.name {
            selectedProject = nil
            dashboard = nil
        }
    }

    // MARK: - v2.3 registry verbs (folder / archive / rename)

    /// Move a project into a folder. `nil` folder returns the project
    /// to the top level. No-op when the target already matches.
    public func moveProject(_ project: ProjectEntry, toFolder folder: String?) {
        mutateEntry(project) { $0.folder = folder }
    }

    /// Rename a project. `name` is the registry's unique key + the
    /// Identifiable id; rejects renames that would collide with an
    /// existing project's name. Returns true on success.
    @discardableResult
    public func renameProject(_ project: ProjectEntry, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != project.name else { return true }
        var registry = service.loadRegistry()
        guard !registry.projects.contains(where: { $0.name == trimmed }) else { return false }
        guard let index = registry.projects.firstIndex(where: { $0.name == project.name }) else { return false }
        let old = registry.projects[index]
        // `uuid` is CARRIED OVER, never re-derived. It is the project's stable
        // identity — the key of `<path>/.scarf/project.json`, the fleet
        // grouping key, and the `[proj:<uuid>]` cron tag. Dropping it here (as
        // this did) left the registry row id-less, so the next `ProjectStore`
        // pass minted a FRESH random UUID: the renamed project silently
        // detached from its own record, its cron jobs, and its fleet siblings.
        // A rename changes the label; it must never change the identifier.
        registry.projects[index] = ProjectEntry(
            name: trimmed,
            path: old.path,
            folder: old.folder,
            archived: old.archived,
            uuid: old.uuid
        )
        do {
            try service.saveRegistry(registry)
        } catch {
            logger.error("renameProject couldn't persist registry: \(error.localizedDescription, privacy: .public)")
            return false
        }
        projects = registry.projects
        if selectedProject?.name == project.name {
            selectedProject = registry.projects[index]
        }
        return true
    }

    /// Soft-archive a project. Stays on disk + in the registry; the
    /// sidebar just hides it unless `showArchived` is on.
    public func archiveProject(_ project: ProjectEntry) {
        mutateEntry(project) { $0.archived = true }
        if selectedProject?.name == project.name {
            selectedProject = nil
            dashboard = nil
        }
    }

    /// Restore an archived project to the default view.
    public func unarchiveProject(_ project: ProjectEntry) {
        mutateEntry(project) { $0.archived = false }
    }

    /// Distinct folder labels across the current project set, sorted
    /// alphabetically. Drives the sidebar's DisclosureGroups + the
    /// Move-to-Folder sheet's existing-folder list.
    public var folders: [String] {
        let set = Set(projects.compactMap(\.folder).filter { !$0.isEmpty })
        return set.sorted()
    }

    // MARK: - Helpers

    private func mutateEntry(_ project: ProjectEntry, _ mutation: (inout ProjectEntry) -> Void) {
        var registry = service.loadRegistry()
        guard let index = registry.projects.firstIndex(where: { $0.name == project.name }) else { return }
        var entry = registry.projects[index]
        mutation(&entry)
        registry.projects[index] = entry
        do {
            try service.saveRegistry(registry)
        } catch {
            logger.error("mutateEntry couldn't persist registry for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        projects = registry.projects
        if selectedProject?.name == project.name {
            selectedProject = entry
        }
    }

    public func refreshDashboard() {
        guard let project = selectedProject else { return }
        loadDashboard(for: project)
    }

    public var dashboardPaths: [String] {
        projects.map(\.dashboardPath)
    }

    /// Per-project `.scarf/` directories — watched alongside `dashboardPaths`
    /// so that file-reading widgets (markdown_file, log_tail, image) refresh
    /// when their underlying files are added / removed / renamed inside the
    /// directory by a cron job. In-place file appends within an existing
    /// file are NOT detected here; the cron job should write atomically
    /// (write-then-rename) or `touch` dashboard.json after each run.
    public var projectScarfDirs: [String] {
        projects.map(\.scarfDir)
    }

    private func loadDashboard(for project: ProjectEntry) {
        dashboardError = nil
        if !service.dashboardExists(for: project) {
            dashboard = nil
            dashboardError = "No dashboard found at \(project.dashboardPath)"
            return
        }
        if let loaded = service.loadDashboard(for: project) {
            dashboard = loaded
        } else {
            dashboard = nil
            dashboardError = "Failed to parse dashboard JSON"
        }
    }

    /// Off-main variant of `loadDashboard(for:)` for `reload()`. Does the
    /// `dashboardExists` + `loadDashboard` transport reads on a detached task,
    /// then commits the result back on the main actor.
    private func reloadDashboard(for project: ProjectEntry, generation: Int) async {
        let ctx = context
        let outcome: (dashboard: ProjectDashboard?, error: String?) = await Task.detached {
            let svc = ProjectDashboardService(context: ctx)
            guard svc.dashboardExists(for: project) else {
                return (nil, "No dashboard found at \(project.dashboardPath)")
            }
            if let loaded = svc.loadDashboard(for: project) { return (loaded, nil) }
            return (nil, "Failed to parse dashboard JSON")
        }.value
        guard generation == reloadGeneration else { return }
        dashboardError = outcome.error
        dashboard = outcome.dashboard
    }
}
