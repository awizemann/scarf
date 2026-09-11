import Foundation
import os
import ScarfCore

/// Resolves and mints per-project Kanban tenant slugs.
///
/// Scarf namespaces a project's Kanban tasks with the optional `tenant TEXT`
/// column on `tasks`: each Scarf project gets a stable `scarf:<slug>` tenant
/// minted on first kanban interaction and persisted to
/// `<project>/.scarf/manifest.json`.
///
/// **Why not `project_id`.** This comment used to justify that by claiming
/// Hermes Kanban has no `project_id` column. That is false, and was false at
/// the target tag: the `tasks` DDL declares `project_id TEXT`
/// (`hermes_cli/kanban_db.py:866-869` @ `v2026.9.7`), `create_task` has full
/// project plumbing (`:1096-1176`), and `_TASK_DICT_FIELDS` emits the key on
/// every `--json` task (`hermes_cli/kanban_output.py:18-24`).
///
/// The column is nonetheless the wrong key for a SCARF project, for a reason
/// the DDL states in its own comment: it is an "Optional link to a
/// first-class Project (hermes_cli/projects_db)". `_resolve_project_link`
/// looks the id up in the CREATOR's per-profile `projects.db`
/// (`kanban_db.py:1110-1117`) and, when it does not resolve, **silently drops
/// the link and creates an ordinary scratch task** (`:1124-1127`). A Scarf
/// project is a folder with a `.scarf/manifest.json`, not a row in Hermes's
/// projects DB, so a Scarf-minted id would be discarded on every create — a
/// namespace that quietly evaporates is worse than none. Linking for real
/// would mean Scarf creating and owning rows in `projects.db`, which is a
/// different feature (and a write to a store Scarf does not own).
///
/// `tenant` has none of that: it is free text Hermes stores and filters on
/// verbatim, which is exactly what a surrogate key needs. The `project_id`
/// Hermes emits IS decoded (`HermesKanbanTask.projectId`) so a task linked to
/// a real Hermes project can be seen for what it is.
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
    ///
    /// **Throws rather than answering `nil` when the manifest is
    /// stat-confirmed but unreadable** (GW-F2, audit DI H1/H2). Every caller
    /// of this method is one branch away from a WRITE: `resolveOrMint` mints
    /// a fresh slug on `nil`, `setTenant` treats `nil` as "not a no-op" and
    /// publishes. A dropped SSH round-trip answered `nil` therefore minted a
    /// second tenant for a board that already had one and orphaned every
    /// task on it — the guarded write downstream could not tell, because by
    /// then the value it was handed looked like a legitimate first mint.
    nonisolated func tenant(for project: ProjectEntry) throws -> String? {
        try readManifest(for: project)?.kanbanTenant
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
        if try self.tenant(for: project) == trimmed { return }  // no-op; avoid churn
        try persist(tenant: trimmed, for: project)
        Self.logger.info("set kanban tenant '\(trimmed, privacy: .public)' for project '\(project.name, privacy: .public)' (fleet apply)")
    }

    /// Returns the existing tenant or mints a new one if absent. Writes
    /// the new tenant back to the project's manifest.json. Idempotent —
    /// calling twice on a fresh project returns the same value.
    nonisolated func resolveOrMint(for project: ProjectEntry) throws -> String {
        if let existing = try tenant(for: project), !existing.isEmpty {
            return existing
        }
        let candidate = Self.makeSlug(for: project.name)
        let unique = try uniquify(candidate, against: project)
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
    nonisolated private func uniquify(_ candidate: String, against project: ProjectEntry) throws -> String {
        let used = Set(try allMintedTenants(excluding: project))
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
    ///
    /// **Every failure here aborts the mint** (GW-F2). This set is the
    /// uniqueness proof for a slug we are about to publish: answering it
    /// from a registry we could not read, or skipping a sibling whose
    /// manifest would not load, produces a candidate that "isn't used" only
    /// because we failed to look — and the guarded write then happily
    /// publishes the collision. A registry that is provably ABSENT is a
    /// different thing (no projects yet) and legitimately yields no tenants.
    nonisolated private func allMintedTenants(excluding project: ProjectEntry) throws -> [String] {
        let registryPath = context.paths.projectsRegistry
        let transport = context.makeTransport()
        if GuardedJSONStore.probeExistence(registryPath, transport: transport) == .provenAbsent {
            return []
        }
        guard let data = context.readData(registryPath),
              let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: data)
        else {
            Self.logger.error(
                "kanban tenant mint aborted: projects.json at \(registryPath, privacy: .public) is present but couldn't be read — a slug minted without it could collide"
            )
            throw GuardedStoreError.refusedUnreadableOverwrite(
                path: registryPath, label: "projects.json"
            )
        }
        return try registry.projects.compactMap { other in
            guard other.id != project.id else { return nil }
            return try readManifest(for: other)?.kanbanTenant
        }
    }

    /// Proof-carrying: see `ProjectManifestStore.readProven`. Every read on
    /// this type feeds a mint decision, so none of them may infer "absent"
    /// from a failed read.
    nonisolated private func readManifest(for project: ProjectEntry) throws -> ProjectTemplateManifest? {
        try ProjectManifestStore(context: context).readProven(for: project)
    }

    /// Write the tenant back to `<project>/.scarf/manifest.json`. If
    /// the file doesn't exist yet (bare project), create a minimal
    /// manifest with just the kanbanTenant set. The remaining
    /// manifest fields use sentinel values that the
    /// `ProjectAgentContextService` reader tolerates: id stays at the
    /// project's slug-form, version stays "0.0.0", and contents claims
    /// nothing — none of which the reader requires for the Kanban
    /// tenant line.
    ///
    /// **Guarded (GW-E2c).** Goes through `ProjectManifestStore`, the file's
    /// one guarded writer, shared with `ProjectModelPresetBinding`. The old
    /// body wrote the sentinel below whenever `readManifest` returned nil —
    /// including when the read merely FAILED — so one dropped round-trip
    /// while minting a Kanban tenant replaced a template project's real
    /// manifest with a `0.0.0` stub. It also re-encoded through the model,
    /// dropping every key Scarf doesn't declare; the store mutates the JSON
    /// object graph instead, so those survive.
    nonisolated private func persist(tenant: String, for project: ProjectEntry) throws {
        try ProjectManifestStore(context: context).setField(
            "kanbanTenant",
            to: .string(tenant),
            for: project
        ) {
            ProjectTemplateManifest(
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
    }
}
