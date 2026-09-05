import Foundation
import os
import ScarfCore

/// Reads + writes a project's bound model preset UUID at
/// `<project>/.scarf/manifest.json`. Mac-target sibling to
/// `KanbanTenantResolver.persist` — same readManifest →
/// mutate-var-field → writeFile pattern.
///
/// Bare projects (no manifest yet) get a sentinel manifest written
/// with only `modelPresetID` set; `ProjectAgentContextService`
/// recognizes the sentinel and refuses to surface it as a "Template"
/// line. Same approach `KanbanTenantResolver` takes for minting a
/// fresh tenant.
///
/// **Invariants:**
/// - Identity is by UUID, never name — renames don't break bindings.
/// - Empty / nil preset id removes the binding (back to global default).
/// - Idempotent: writing the same preset id twice produces no diff.
struct ProjectModelPresetBinding: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectModelPresetBinding")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Public

    /// Returns the project's bound preset UUID string, or nil when no
    /// binding is set. Read-only — never writes.
    nonisolated func boundPresetID(for project: ProjectEntry) -> String? {
        readManifest(for: project)?.modelPresetID
    }

    /// Set or clear a project's preset binding. Passing `nil`
    /// (or an empty string) removes the binding so the project falls
    /// back to the global default in `config.yaml`.
    nonisolated func bind(presetID: String?, to project: ProjectEntry) throws {
        let trimmed = presetID?.trimmingCharacters(in: .whitespaces)
        let nextValue = (trimmed?.isEmpty ?? true) ? nil : trimmed

        let existing = readManifest(for: project)
        if existing?.modelPresetID == nextValue {
            // No-op write. Avoids file-watcher churn and noisy diffs.
            return
        }

        try persist(presetID: nextValue, for: project)
        Self.logger.info(
            "bound preset \(nextValue ?? "<nil>", privacy: .public) to project '\(project.name, privacy: .public)'"
        )
    }

    // MARK: - Private

    nonisolated private func readManifest(for project: ProjectEntry) -> ProjectTemplateManifest? {
        let path = manifestPath(for: project)
        let transport = context.makeTransport()
        guard transport.fileExists(path),
              let data = try? transport.readFile(path)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ProjectTemplateManifest.self, from: data)
    }

    nonisolated private func persist(presetID: String?, for project: ProjectEntry) throws {
        let path = manifestPath(for: project)
        let transport = context.makeTransport()

        // Ensure .scarf/ exists.
        let scarfDir = project.scarfDir
        if !transport.fileExists(scarfDir) {
            try transport.createDirectory(scarfDir)
        }

        let updated: ProjectTemplateManifest
        if let existing = readManifest(for: project) {
            var copy = existing
            copy.modelPresetID = presetID
            updated = copy
        } else {
            // Bare-project sentinel manifest — same shape
            // `KanbanTenantResolver.persist` writes for first-mint.
            updated = ProjectTemplateManifest(
                schemaVersion: 3,
                id: "scarf/\(project.id)",
                name: project.name,
                version: "0.0.0",
                minScarfVersion: nil,
                minHermesVersion: nil,
                author: nil,
                description: "",
                category: nil,
                tags: nil,
                icon: nil,
                screenshots: nil,
                contents: TemplateContents(
                    dashboard: false,
                    agentsMd: false,
                    instructions: nil,
                    skills: nil,
                    cron: nil,
                    memory: nil,
                    config: nil,
                    slashCommands: nil
                ),
                config: nil,
                kanbanTenant: nil,
                modelPresetID: presetID
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        // UNGUARDED-WRITE(R): manifest.json sentinel fallback on a failed read, and unknown keys dropped — E2 converts with KanbanTenantResolver.
        try transport.unguardedWriteFile(path, data: data)
    }

    nonisolated private func manifestPath(for project: ProjectEntry) -> String {
        project.scarfDir + "/manifest.json"
    }
}
