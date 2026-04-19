import Foundation

struct ProjectDashboardService: Sendable {

    let context: ServerContext
    let transport: any ServerTransport

    init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    // MARK: - Registry

    func loadRegistry() -> ProjectRegistry {
        guard let data = try? transport.readFile(context.paths.projectsRegistry) else {
            return ProjectRegistry(projects: [])
        }
        do {
            return try JSONDecoder().decode(ProjectRegistry.self, from: data)
        } catch {
            print("[Scarf] Failed to decode project registry: \(error.localizedDescription)")
            return ProjectRegistry(projects: [])
        }
    }

    func saveRegistry(_ registry: ProjectRegistry) {
        let dir = context.paths.scarfDir
        if !transport.fileExists(dir) {
            do {
                try transport.createDirectory(dir)
            } catch {
                print("[Scarf] Failed to create scarf directory: \(error.localizedDescription)")
                return
            }
        }
        guard let data = try? JSONEncoder().encode(registry) else { return }
        // Pretty-print for readability (agents may read this file)
        let writeData: Data
        if let pretty = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted, .sortedKeys]) {
            writeData = formatted
        } else {
            writeData = data
        }
        try? transport.writeFile(context.paths.projectsRegistry, data: writeData)
    }

    // MARK: - Dashboard

    func loadDashboard(for project: ProjectEntry) -> ProjectDashboard? {
        guard let data = try? transport.readFile(project.dashboardPath) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ProjectDashboard.self, from: data)
        } catch {
            print("[Scarf] Failed to decode dashboard for \(project.name): \(error.localizedDescription)")
            return nil
        }
    }

    func dashboardExists(for project: ProjectEntry) -> Bool {
        transport.fileExists(project.dashboardPath)
    }

    func dashboardModificationDate(for project: ProjectEntry) -> Date? {
        transport.stat(project.dashboardPath)?.mtime
    }
}
