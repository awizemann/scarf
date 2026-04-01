import Foundation

@Observable
final class ProjectsViewModel {
    private let service = ProjectDashboardService()

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
        service.saveRegistry(registry)
        projects = registry.projects
        selectProject(entry)
    }

    func removeProject(_ project: ProjectEntry) {
        var registry = service.loadRegistry()
        registry.projects.removeAll { $0.name == project.name }
        service.saveRegistry(registry)
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
