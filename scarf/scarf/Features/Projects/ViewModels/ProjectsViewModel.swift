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
