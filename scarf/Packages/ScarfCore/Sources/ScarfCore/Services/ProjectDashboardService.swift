import Foundation
import os

public struct ProjectDashboardService: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectDashboardService")

    public let context: ServerContext
    public let transport: any ServerTransport

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    // MARK: - Registry

    public func loadRegistry() -> ProjectRegistry {
        guard let data = try? transport.readFile(context.paths.projectsRegistry) else {
            return ProjectRegistry(projects: [])
        }
        do {
            return try JSONDecoder().decode(ProjectRegistry.self, from: data)
        } catch {
            Self.logger.error("Failed to decode project registry: \(error.localizedDescription, privacy: .public)")
            return ProjectRegistry(projects: [])
        }
    }

    /// Persist the project registry to `~/.hermes/scarf/projects.json`.
    ///
    /// **Throws** on every non-success path — the previous version of
    /// this method silently swallowed `createDirectory` and `writeFile`
    /// failures with `try?`, which meant the installer could return a
    /// valid-looking `ProjectEntry` while the registry on disk never
    /// received the new row (project would complete install, show a
    /// success screen, then be invisible in the sidebar). Callers that
    /// want fire-and-forget behaviour can still use `try?`, but the
    /// choice is now theirs.
    public func saveRegistry(_ registry: ProjectRegistry) throws {
        let dir = context.paths.scarfDir
        // `createDirectory` is mkdir -p across every transport (Local
        // uses withIntermediateDirectories, SSH/Citadel both ignore
        // "already exists"), so we don't need to fileExists-guard it.
        try transport.createDirectory(dir)
        let data = try JSONEncoder().encode(registry)
        // Pretty-print for readability (agents may read this file).
        let writeData: Data
        if let pretty = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted, .sortedKeys]) {
            writeData = formatted
        } else {
            writeData = data
        }
        try transport.writeFile(context.paths.projectsRegistry, data: writeData)
    }

    // MARK: - Dashboard

    public func loadDashboard(for project: ProjectEntry) -> ProjectDashboard? {
        guard let data = try? transport.readFile(project.dashboardPath) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ProjectDashboard.self, from: data)
        } catch {
            Self.logger.error("Failed to decode dashboard for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func dashboardExists(for project: ProjectEntry) -> Bool {
        transport.fileExists(project.dashboardPath)
    }

    public func dashboardModificationDate(for project: ProjectEntry) -> Date? {
        transport.stat(project.dashboardPath)?.mtime
    }
}
