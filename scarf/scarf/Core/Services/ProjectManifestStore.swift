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

    /// Typed read for callers that just want to LOOK — display, not
    /// decision. `nil` for anything that isn't a decodable manifest,
    /// including a read that merely failed.
    ///
    /// **Deliberately tolerant, and only safe where nothing is written as a
    /// result** (GW-F2). The one remaining caller is
    /// `ProjectModelPresetBinding.boundPresetID`, which renders a picker
    /// selection: a dropped round-trip there shows "no preset bound" for one
    /// paint and self-corrects on the next read. Every caller whose answer
    /// feeds a WRITE — minting a Kanban tenant, deciding a binding is a
    /// no-op — must use ``readProven(for:)`` instead, because for those an
    /// unreadable manifest answered as `nil` is how a sentinel (or a
    /// duplicate slug) lands on top of a real file.
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

    /// The same read with PROOF behind its `nil` — for the callers whose
    /// answer decides whether to write (GW-F2, audit DI H1/H2).
    ///
    /// `nil` here means the manifest is provably absent, or held bytes that
    /// are not a manifest — both states in which minting a stub is correct.
    /// A stat-confirmed-but-unreadable file THROWS instead, so the decision
    /// aborts rather than inferring "no manifest" from a dropped SSH
    /// round-trip.
    ///
    /// Undecodable bytes stay `nil` rather than being quarantined: this is a
    /// read, and `setField` — which runs `inspectDecoding` immediately
    /// afterwards on the write path — owns the quarantine.
    ///
    /// - Throws: `GuardedStoreError.refusedUnreadableOverwrite`.
    nonisolated func readProven(for project: ProjectEntry) throws -> ProjectTemplateManifest? {
        let path = Self.path(for: project)
        let inspection = inspect(path)
        if case .unreadable(let damaged) = inspection.state {
            Self.logger.error(
                "manifest.json at \(damaged, privacy: .public) exists but couldn't be read — aborting rather than treating it as absent"
            )
            throw GuardedStoreError.refusedUnreadableOverwrite(
                path: damaged, label: Self.label
            )
        }
        guard let bytes = inspection.bytes else { return nil }
        return try? JSONDecoder().decode(ProjectTemplateManifest.self, from: bytes)
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
            // **A JSON object that is not a MANIFEST is repaired, not
            // extended (GW-F6 / audit DI L4).** Splicing one key into
            // `{"hello": 1}` used to produce a file that still would not
            // decode as a manifest — so the preset binding "succeeded", the
            // Configuration editor kept reporting the project as
            // unconfigurable, and nothing ever said why. The pre-arc
            // behavior for this state was to replace the file wholesale;
            // this is that decision, minus the destruction: the caller's
            // sentinel keys are overlaid so the document becomes a valid
            // manifest again, while every key we do not own — including the
            // foreign ones that made it undecodable — is preserved for the
            // human to find, per `GuardedSidecarStore` section 4. (Refusing
            // instead was the alternative; it was rejected because neither
            // caller can offer the user a repair, so it would freeze preset
            // bindings and Kanban tenants on a file only a text editor can
            // fix.)
            let bytes = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
            if (try? JSONDecoder().decode(ProjectTemplateManifest.self, from: bytes)) == nil {
                let stub = try JSONEncoder().encode(sentinel())
                if case .object(let stubObject) = try JSONDecoder().decode(JSONValue.self, from: stub) {
                    // **Log-only, deliberately (GW follow-up, item 3).** No UI
                    // is added for this repair, and that is the honest call
                    // rather than an omission:
                    //
                    // 1. Nothing is lost. Every key we do not own survives the
                    //    overlay — the log line below names them — so there is
                    //    no user decision waiting on the other side of a
                    //    notice.
                    // 2. The BROKEN state is already surfaced. A wrong-shaped
                    //    `manifest.json` is a `malformedSidecar` finding in
                    //    Project Doctor (`ProjectDoctorService`, sidecar scan)
                    //    from the moment it lands, before any preset binding
                    //    touches it. That is where a user learns their manifest
                    //    is not a manifest.
                    // 3. After the repair the file decodes, so the doctor would
                    //    correctly find nothing. Reporting "this was repaired"
                    //    there would need a persisted repair marker — new
                    //    state, new lifecycle, new staleness — for a
                    //    self-healing fix to an agent-owned file. That is not
                    //    a cheap fit for an existing channel; it is machinery.
                    //
                    // So the log carries the whole story, and it names the keys
                    // it kept and the keys it wrote so a support read of the
                    // console can reconstruct the file's before-state.
                    let overlaid = stubObject.keys.sorted()
                    let preserved = object.keys.filter { stubObject[$0] == nil }.sorted()
                    let clobbered = object.keys.filter { stubObject[$0] != nil }.sorted()
                    Self.logger.warning(
                        """
                        manifest.json at \(path, privacy: .public) is a JSON object but not a manifest; \
                        overlaying a fresh stub. wrote=[\(overlaid.joined(separator: ","), privacy: .public)] \
                        preserved=[\(preserved.joined(separator: ","), privacy: .public)] \
                        replaced=[\(clobbered.joined(separator: ","), privacy: .public)]
                        """
                    )
                    for (k, v) in stubObject { root[k] = v }
                }
            }
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
