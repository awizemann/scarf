import Foundation
import os

@Observable
final class ProjectsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ProjectsViewModel")
    let context: ServerContext
    private let service: ProjectDashboardService

    init(context: ServerContext = .local) {
        self.context = context
        self.service = ProjectDashboardService(context: context)
    }


    var projects: [ProjectEntry] = []
    var selectedProject: ProjectEntry?
    var dashboard: ProjectDashboard?
    var dashboardError: String?
    var isLoading = false

    func load() {
        let registry = service.loadRegistry()
        projects = registry.projects
        if let selected = selectedProject, !projects.contains(where: { $0.name == selected.name }) {
            selectedProject = nil
            dashboard = nil
        }
        if let selected = selectedProject {
            loadDashboard(for: selected)
        }
    }

    func selectProject(_ project: ProjectEntry) {
        selectedProject = project
        loadDashboard(for: project)
    }

    func addProject(name: String, path: String) {
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

    func removeProject(_ project: ProjectEntry) {
        var registry = service.loadRegistry()
        registry.projects.removeAll { $0.name == project.name }
        do {
            try service.saveRegistry(registry)
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
    func moveProject(_ project: ProjectEntry, toFolder folder: String?) {
        mutateEntry(project) { $0.folder = folder }
    }

    /// Rename a project. `name` is the registry's unique key + the
    /// Identifiable id; we reject renames that would collide with
    /// another project's name. Returns true on success.
    @discardableResult
    func renameProject(_ project: ProjectEntry, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != project.name else { return true }
        var registry = service.loadRegistry()
        // Reject collisions — a second project already owns that name.
        guard !registry.projects.contains(where: { $0.name == trimmed }) else { return false }
        guard let index = registry.projects.firstIndex(where: { $0.name == project.name }) else { return false }
        let old = registry.projects[index]
        registry.projects[index] = ProjectEntry(
            name: trimmed,
            path: old.path,
            folder: old.folder,
            archived: old.archived
        )
        do {
            try service.saveRegistry(registry)
        } catch {
            logger.error("renameProject couldn't persist registry: \(error.localizedDescription, privacy: .public)")
            return false
        }
        projects = registry.projects
        // Preserve selection across the rename — the selected project
        // still exists, it just has a new id.
        if selectedProject?.name == project.name {
            selectedProject = registry.projects[index]
        }
        return true
    }

    /// Soft-archive a project. It stays on disk and in the registry;
    /// the sidebar just hides it unless `showArchived` is on.
    func archiveProject(_ project: ProjectEntry) {
        mutateEntry(project) { $0.archived = true }
        // If the archived project was selected, clear selection so
        // the dashboard doesn't linger on a hidden project.
        if selectedProject?.name == project.name {
            selectedProject = nil
            dashboard = nil
        }
    }

    /// Restore an archived project to the default view.
    func unarchiveProject(_ project: ProjectEntry) {
        mutateEntry(project) { $0.archived = false }
    }

    /// Distinct folder labels across the current project set, sorted
    /// alphabetically. Drives the sidebar's DisclosureGroups (commit
    /// 2) and the Move-to-Folder sheet's existing-folder list. An
    /// "empty" folder (folder with zero projects) can't exist under
    /// this model — folders are implicit in the data — which is
    /// intentional: v2.3 doesn't need first-class empty folders.
    var folders: [String] {
        let set = Set(projects.compactMap(\.folder).filter { !$0.isEmpty })
        return set.sorted()
    }

    // MARK: - Helpers

    /// Fetch the registry, apply `mutation` to the matched entry,
    /// persist, update in-memory state. Centralises the save +
    /// re-publish dance shared by `moveProject`, `archiveProject`,
    /// and `unarchiveProject`. Callers that need different matching
    /// semantics (rename, remove) handle their own registry mutation.
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

    func refreshDashboard() {
        guard let project = selectedProject else { return }
        loadDashboard(for: project)
    }

    var dashboardPaths: [String] {
        projects.map(\.dashboardPath)
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
}
