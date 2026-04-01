import Foundation

struct ProjectDashboardService: Sendable {

    // MARK: - Registry

    func loadRegistry() -> ProjectRegistry {
        guard let data = FileManager.default.contents(atPath: HermesPaths.projectsRegistry) else {
            return ProjectRegistry(projects: [])
        }
        return (try? JSONDecoder().decode(ProjectRegistry.self, from: data))
            ?? ProjectRegistry(projects: [])
    }

    func saveRegistry(_ registry: ProjectRegistry) {
        let dir = HermesPaths.scarfDir
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(registry) else { return }
        // Pretty-print for readability (agents may read this file)
        if let pretty = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: HermesPaths.projectsRegistry, contents: formatted)
        } else {
            FileManager.default.createFile(atPath: HermesPaths.projectsRegistry, contents: data)
        }
    }

    // MARK: - Dashboard

    func loadDashboard(for project: ProjectEntry) -> ProjectDashboard? {
        guard let data = FileManager.default.contents(atPath: project.dashboardPath) else {
            return nil
        }
        return try? JSONDecoder().decode(ProjectDashboard.self, from: data)
    }

    func dashboardExists(for project: ProjectEntry) -> Bool {
        FileManager.default.fileExists(atPath: project.dashboardPath)
    }

    func dashboardModificationDate(for project: ProjectEntry) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: project.dashboardPath) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}
