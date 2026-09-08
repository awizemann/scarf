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
    ///
    /// **Deliberately tolerant** (GW-F2): this answer only ever renders a
    /// picker selection, so a dropped round-trip costs one paint showing
    /// "no preset bound" and self-corrects on the next read — no bytes are
    /// decided by it. The sibling decision path (`bind`, which uses the
    /// answer to declare a write a no-op) uses the proof-carrying read
    /// instead.
    nonisolated func boundPresetID(for project: ProjectEntry) -> String? {
        ProjectManifestStore(context: context).read(for: project)?.modelPresetID
    }

    /// Set or clear a project's preset binding. Passing `nil`
    /// (or an empty string) removes the binding so the project falls
    /// back to the global default in `config.yaml`.
    nonisolated func bind(presetID: String?, to project: ProjectEntry) throws {
        let trimmed = presetID?.trimmingCharacters(in: .whitespaces)
        let nextValue = (trimmed?.isEmpty ?? true) ? nil : trimmed

        // Proof-carrying: an unreadable manifest answered as "no binding"
        // would turn a real no-op into a publish (or vice versa). Aborts
        // through the caller's existing `throws`.
        let existing = try readManifest(for: project)
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

    nonisolated private func readManifest(for project: ProjectEntry) throws -> ProjectTemplateManifest? {
        try ProjectManifestStore(context: context).readProven(for: project)
    }

    /// Persist the binding through the file's ONE guarded writer
    /// (`ProjectManifestStore`, GW-E2c). The old body read the manifest,
    /// re-encoded it through `ProjectTemplateManifest`, and on a failed read
    /// wrote a `0.0.0` sentinel over whatever was there — so a dropped
    /// round-trip while binding a model preset erased a template project's
    /// real manifest, and even the success path dropped every key Scarf
    /// doesn't model.
    nonisolated private func persist(presetID: String?, for project: ProjectEntry) throws {
        try ProjectManifestStore(context: context).setField(
            "modelPresetID",
            to: presetID.map { JSONValue.string($0) },
            for: project
        ) {
            // Bare-project sentinel manifest — same shape
            // `KanbanTenantResolver.persist` writes for first-mint. Reached
            // only when the file is PROVABLY absent.
            ProjectTemplateManifest(
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
    }
}
