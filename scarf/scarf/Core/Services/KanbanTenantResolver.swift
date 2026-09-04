import Foundation
import os
import ScarfCore

/// Resolves and mints per-project Kanban tenant slugs.
///
/// Hermes Kanban has no `project_id` column — the closest namespace
/// primitive is the optional `tenant TEXT` column on `tasks`. Scarf
/// uses it as a surrogate project key: each Scarf project gets a
/// stable `scarf:<slug>` tenant minted on first kanban interaction
/// and persisted to `<project>/.scarf/manifest.json`.
///
/// **Invariants:**
/// - Once minted, the tenant is immutable across renames. Tasks
///   already on the board carry the original slug; renaming the
///   project would orphan them.
/// - The `scarf:` prefix prevents collisions with hand-typed
///   tenants from CLI users.
/// - Bare projects (no manifest) get a minimal `manifest.json`
///   with only `kanbanTenant` set on first mint.
struct KanbanTenantResolver: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "KanbanTenantResolver")

    /// Prefix that distinguishes Scarf-minted tenants from hand-typed
    /// ones. Public for callers that group "scarf-managed" projects in
    /// the global tenant filter.
    nonisolated static let prefix = "scarf:"

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Public

    /// Returns the existing tenant for a project, or `nil` if none has
    /// been minted yet. Read-only — never writes.
    nonisolated func tenant(for project: ProjectEntry) -> String? {
        readManifest(for: project)?.kanbanTenant
    }

    /// Set the project's Kanban tenant to an **explicit** slug, rather
    /// than deriving one from the name. Used by fleet apply-to-policy: a
    /// source project's board slug is copied verbatim onto a target host
    /// so the fleet shares one logical board name.
    ///
    /// Idempotent (a no-op when already set to `tenant`), and mints a
    /// sentinel manifest when the target is bare — same write path as
    /// `resolveOrMint`. The caller owns the **additive** decision: this
    /// will overwrite an existing tenant if asked, which orphans the
    /// target's existing board tasks, so apply-to-fleet only calls it for
    /// targets that have no tenant yet (see `FleetApplyPlan.disposition`).
    nonisolated func setTenant(_ tenant: String, for project: ProjectEntry) throws {
        let trimmed = tenant.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if self.tenant(for: project) == trimmed { return }  // no-op; avoid churn
        try persist(tenant: trimmed, for: project)
        Self.logger.info("set kanban tenant '\(trimmed, privacy: .public)' for project '\(project.name, privacy: .public)' (fleet apply)")
    }

    /// Returns the existing tenant or mints a new one if absent. Writes
    /// the new tenant back to the project's manifest.json. Idempotent —
    /// calling twice on a fresh project returns the same value.
    nonisolated func resolveOrMint(for project: ProjectEntry) throws -> String {
        if let existing = tenant(for: project), !existing.isEmpty {
            return existing
        }
        let candidate = Self.makeSlug(for: project.name)
        let unique = uniquify(candidate, against: project)
        try persist(tenant: unique, for: project)
        Self.logger.info("minted kanban tenant '\(unique, privacy: .public)' for project '\(project.name, privacy: .public)'")
        return unique
    }

    // MARK: - Slug generation (pure)

    /// Build a `scarf:<slug>` tenant from a project name. Lowercased,
    /// hyphenated, ≤48 chars after the prefix. Public for tests.
    nonisolated static func makeSlug(for name: String) -> String {
        let lower = name.lowercased()
        let mapped = lower.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber { return c }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = collapsed.isEmpty ? "project" : collapsed
        let bounded = String(trimmed.prefix(48))
        return prefix + bounded
    }

    // MARK: - Private

    /// Disambiguate against tenants already used by other projects on
    /// this host. Reads every project's manifest; `O(projects)` — fine
    /// for typical project counts (handful to dozens). Suffixes `-2`,
    /// `-3`, … until unique.
    nonisolated private func uniquify(_ candidate: String, against project: ProjectEntry) -> String {
        let used = Set(allMintedTenants(excluding: project))
        if !used.contains(candidate) { return candidate }
        var n = 2
        while n < 1000 {
            let next = candidate + "-\(n)"
            if !used.contains(next) { return next }
            n += 1
        }
        // Defensive — should never hit. Fall back to a UUID suffix.
        return candidate + "-" + UUID().uuidString.prefix(6).lowercased()
    }

    /// Collect every Scarf-minted tenant currently on disk, excluding
    /// the given project. Used to dedup new mints.
    nonisolated private func allMintedTenants(excluding project: ProjectEntry) -> [String] {
        let registryPath = context.paths.projectsRegistry
        guard let data = context.readData(registryPath),
              let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: data)
        else {
            return []
        }
        return registry.projects.compactMap { other in
            guard other.id != project.id else { return nil }
            return readManifest(for: other)?.kanbanTenant
        }
    }

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

    /// Write the tenant back to `<project>/.scarf/manifest.json`. If
    /// the file doesn't exist yet (bare project), create a minimal
    /// manifest with just the kanbanTenant set. The remaining
    /// manifest fields use sentinel values that the
    /// `ProjectAgentContextService` reader tolerates: id stays at the
    /// project's slug-form, version stays "0.0.0", and contents claims
    /// nothing — none of which the reader requires for the Kanban
    /// tenant line.
    nonisolated private func persist(tenant: String, for project: ProjectEntry) throws {
        let path = manifestPath(for: project)
        let transport = context.makeTransport()

        // Ensure .scarf/ exists.
        let scarfDir = project.scarfDir
        if !transport.fileExists(scarfDir) {
            try transport.createDirectory(scarfDir)
        }

        let updated: ProjectTemplateManifest
        if let existing = readManifest(for: project) {
            // Mutate the existing manifest in place. var fields permit
            // this; let fields are preserved.
            var copy = existing
            copy.kanbanTenant = tenant
            updated = copy
        } else {
            updated = ProjectTemplateManifest(
                schemaVersion: 3,
                id: ProjectManifestProjection.sentinelIDPrefix + project.id,
                name: project.name,
                version: ProjectManifestProjection.sentinelVersion,
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
                kanbanTenant: tenant
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try transport.writeFile(path, data: data)
    }

    nonisolated private func manifestPath(for project: ProjectEntry) -> String {
        project.scarfDir + "/manifest.json"
    }
}
