import Foundation
import Observation

@Observable
public final class ProjectsViewModel {
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

    public func load() {
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

    public func selectProject(_ project: ProjectEntry) {
        selectedProject = project
        loadDashboard(for: project)
    }

    public func addProject(name: String, path: String) {
        var registry = service.loadRegistry()
        guard !registry.projects.contains(where: { $0.name == name }) else { return }
        let entry = ProjectEntry(name: name, path: path)
        registry.projects.append(entry)
        service.saveRegistry(registry)
        projects = registry.projects
        selectProject(entry)
    }

    public func removeProject(_ project: ProjectEntry) {
        var registry = service.loadRegistry()
        registry.projects.removeAll { $0.name == project.name }
        service.saveRegistry(registry)
        projects = registry.projects
        if selectedProject?.name == project.name {
            selectedProject = nil
            dashboard = nil
        }
    }

    public func refreshDashboard() {
        guard let project = selectedProject else { return }
        loadDashboard(for: project)
    }

    public var dashboardPaths: [String] {
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
