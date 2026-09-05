import Foundation
import ScarfCore
import os

/// The one guarded writer of `<project>/.scarf/manifest.json`.
///
/// **Why this type exists (GW-E2c).** That file had TWO writers —
/// `KanbanTenantResolver.persist` and `ProjectModelPresetBinding.persist` —
/// with copy-pasted bodies and the identical pair of holes:
///
/// 1. **A failed read minted a SENTINEL over the real manifest.** Both did
///    `fileExists` + `try? readFile` + `try? decode`, and on `nil` wrote a
///    bare `0.0.0` / `scarf/<id>` stub carrying only the one field they
///    owned. A dropped SSH round-trip on a template-installed project
///    therefore replaced the template's manifest — id, version, config
///    schema, contents claim, everything the Configuration editor renders
///    from — with a stub that says the project came from nowhere.
/// 2. **Unknown keys were dropped even when everything succeeded**, because
///    both re-encoded through `ProjectTemplateManifest`. Any key a newer
///    Scarf, a template author, or Hermes had put in the file was erased by
///    a preset binding.
///
/// This closes both, once, for the file — not once per writer, which is the
/// pattern the whole Guarded-Write phase exists to end. The mutation happens
/// on the JSON OBJECT GRAPH (`JSONValue`), so every key this app has never
/// heard of survives a round trip, and it publishes through
/// `GuardedJSONStore`: proof-based absence, a refusal when the file is
/// provably there and unreadable, quarantine for bytes that won't decode,
/// and a one-deep `manifest.json.bak`.
///
/// The sentinel is still written — a bare project genuinely has no manifest
/// — but now only when the file is PROVABLY absent (or was quarantined),
/// never when a read merely failed.
nonisolated struct ProjectManifestStore: GuardedSidecarStore, Sendable {
    private nonisolated static let logger = Logger(
        subsystem: "com.scarf", category: "ProjectManifestStore"
    )

    /// Manifests are small documents; past this it is not one, and the
    /// bytes are quarantined rather than parsed or replaced.
    nonisolated static let maxBytes = 1 * 1024 * 1024

    static let label = "manifest.json"
    /// REBUILDABLE — but only just, and only because the rebuild is the
    /// caller's `sentinel` stub rather than an empty file. A manifest that
    /// will not decode is not a manifest; its bytes are copied aside for the
    /// human and the project keeps working. The state this policy must NOT
    /// reach is the one that motivated the type: a stat-confirmed unreadable
    /// file, which refuses under either policy.
    static let damagePolicy = GuardedDamagePolicy.quarantineAndRebuild

    nonisolated var transport: any ServerTransport { context.makeTransport() }

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    nonisolated static func path(for project: ProjectEntry) -> String {
        project.scarfDir + "/manifest.json"
    }

    /// Typed read for callers that just want to look. Unchanged in
    /// behavior: `nil` for anything that isn't a decodable manifest.
    nonisolated func read(for project: ProjectEntry) -> ProjectTemplateManifest? {
        let transport = context.makeTransport()
        let path = Self.path(for: project)
        guard transport.fileExists(path),
              let data = try? transport.readFile(path)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ProjectTemplateManifest.self, from: data)
    }

    /// Set (or, with `nil`, remove) ONE top-level key, preserving every
    /// other key in the file.
    ///
    /// - Parameter sentinel: the manifest to write when there is provably no
    ///   file yet. Built by the caller because the two call sites mint
    ///   slightly different stubs; it is invoked ONLY on the proven-absent
    ///   and quarantined paths.
    /// - Throws: `GuardedStoreError.refusedUnreadableOverwrite` when the
    ///   file is stat-confirmed but unreadable — the case that used to
    ///   publish a sentinel over a real manifest.
    nonisolated func setField(
        _ key: String,
        to value: JSONValue?,
        for project: ProjectEntry,
        sentinel: () -> ProjectTemplateManifest
    ) throws {
        let transport = context.makeTransport()
        let path = Self.path(for: project)

        // Ensure .scarf/ exists. Kept ahead of the guarded write (which
        // mkdir -p's the parent itself) so the pre-existing behavior of
        // creating the directory even for a no-op is unchanged.
        let scarfDir = project.scarfDir
        if !transport.fileExists(scarfDir) {
            try transport.createDirectory(scarfDir)
        }

        let (inspection, existing) = inspectDecoding(JSONValue.self, at: path)
        if case .unreadable(let damaged) = inspection.state {
            Self.logger.error(
                "refusing to write manifest.json at \(damaged, privacy: .public) — it exists but couldn't be read; a sentinel here would erase the real manifest"
            )
            throw GuardedStoreError.refusedUnreadableOverwrite(
                path: damaged, label: "manifest.json"
            )
        }

        var root: [String: JSONValue]
        if let existing, case .object(let object) = existing {
            root = object
        } else {
            // Proven-absent (or quarantined, or a JSON document that isn't
            // an object): mint the caller's stub. Encoded through the model
            // so the bytes are byte-identical to what the old sentinel path
            // produced.
            let data = try JSONEncoder().encode(sentinel())
            guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data)
            else {
                throw GuardedStoreError.refusedUnreadableOverwrite(
                    path: path, label: "manifest.json"
                )
            }
            root = object
        }

        if let value {
            root[key] = value
        } else {
            root.removeValue(forKey: key)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(JSONValue.object(root))
        try publish(data, to: path, after: inspection)
    }
}
