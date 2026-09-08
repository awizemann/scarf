import Foundation
import ScarfCore
import os

/// Per-project configuration I/O: reads `<project>/.scarf/config.json`
/// into typed values, writes them back, resolves Keychain-backed secrets
/// on demand, and validates user-entered values against the schema.
///
/// Separation of concerns:
///
/// - **Schema authority.** `TemplateConfigSchema` lives in the bundle's
///   `template.json` and a copy is stashed at `<project>/.scarf/manifest.json`
///   at install time so the post-install editor works offline. This
///   service treats the schema as read-only input; `validateSchema`
///   checks structural invariants and is called by
///   `ProjectTemplateService` during install-plan building.
/// - **Value storage.** Non-secret values live inline in `config.json`;
///   secret values are Keychain references of the form
///   `"keychain://<service>/<account>"`. The service owns both halves
///   of that storage — callers never open `config.json` or touch the
///   Keychain directly.
/// - **Remote readiness.** All file I/O goes through
///   `ServerContext.makeTransport()` so when `ProjectTemplateInstaller`
///   eventually supports remote contexts, the config store comes along
///   for the ride. Keychain access stays local (it's a macOS-side thing
///   by definition — agents on remote Hermes installs would fetch
///   values via Scarf's channel, same as today).
///
/// **The `config.json` policy is DECLARED, not hand-rolled (GW-F6 / audit
/// DI M8).** This type conforms to `GuardedSidecarStore` with
/// `damagePolicy == .refuseForever`, which is what makes the three
/// `if case .unreadable` branches below sufficient. Before that it ran
/// `GuardedJSONStore` directly, so bytes that would not DECODE arrived as
/// `.quarantined`, `existingRoot` came back `nil`, and `save` rebuilt the
/// file from `root = [:]` — silently dropping every `keychain://` reference
/// in it and orphaning the secrets they pointed at, which is exactly the
/// destruction the refusal on the unreadable branch exists to prevent. The
/// rows in `config.json` (the user's configured values, and the only
/// pointers to their Keychain items) exist nowhere else, so it takes
/// `projects.json`'s policy, and the protocol reclassifies the quarantine to
/// `.unreadable` centrally — the bytes are still copied aside for the human,
/// and `Inspection.quarantineCopy` still carries where.
struct ProjectConfigService: GuardedSidecarStore, Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectConfigService")

    nonisolated static let label = "config.json"
    /// Cap shared verbatim with `ProjectMCPTools.configMaxBytes` — the same
    /// file, so the same ceiling.
    nonisolated static let maxBytes = 1 * 1024 * 1024
    /// REFUSE FOREVER — see the type's header.
    nonisolated static let damagePolicy = GuardedDamagePolicy.refuseForever

    nonisolated var transport: any ServerTransport { context.makeTransport() }

    let context: ServerContext
    let keychain: ProjectConfigKeychain

    nonisolated init(
        context: ServerContext = .local,
        keychain: ProjectConfigKeychain = ProjectConfigKeychain()
    ) {
        self.context = context
        self.keychain = keychain
    }

    // MARK: - Paths

    nonisolated static func configPath(for project: ProjectEntry) -> String {
        project.path + "/.scarf/config.json"
    }

    nonisolated static func manifestCachePath(for project: ProjectEntry) -> String {
        project.path + "/.scarf/manifest.json"
    }

    // MARK: - Load / save on-disk config

    /// Read + decode `<project>/.scarf/config.json`. Returns `nil`
    /// cleanly when the file is absent (e.g. a project installed from
    /// a schema-less template, or a hand-added project). Throws on
    /// malformed JSON so the caller can surface a concrete error
    /// rather than silently treating a corrupt file as missing.
    ///
    /// **Absent takes PROOF (GW-E2c).** This used to gate on
    /// `transport.fileExists`, so a dropped round-trip reported "no config"
    /// — and the Configuration form then opened on schema defaults and
    /// SAVED them, wiping the real values. Guarding only `save` would not
    /// have closed that: the destruction enters through the load.
    nonisolated func load(project: ProjectEntry) throws -> ProjectConfigFile? {
        let path = Self.configPath(for: project)
        let inspection = inspect(path)
        switch inspection.state {
        case .absent:
            return nil
        case .unreadable(let damaged):
            throw GuardedStoreError.refusedUnreadableOverwrite(path: damaged, label: Self.label)
        case .quarantined:
            // Unreachable: `.refuseForever` reclassifies it to `.unreadable`
            // above. Kept exhaustive rather than defaulted so a policy
            // change surfaces here as a compile-time decision.
            throw GuardedStoreError.refusedUnreadableOverwrite(path: path, label: Self.label)
        case .present:
            break
        }
        let data = inspection.bytes ?? Data()
        do {
            return try JSONDecoder().decode(ProjectConfigFile.self, from: data)
        } catch {
            Self.logger.error("couldn't decode config.json at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Write `<project>/.scarf/config.json`. Secrets should already be
    /// represented as `TemplateConfigValue.keychainRef` references here
    /// — this service never inspects their plaintext.
    /// Spelling kept for the call sites (and for `manifest.json`, which
    /// borrows the same ceiling); the value is now the protocol's
    /// ``maxBytes``.
    nonisolated static var configMaxBytes: Int { maxBytes }

    /// Prove `save` would be ALLOWED to publish, without writing anything.
    ///
    /// **Ordering, not compensation (GW-F1 / DI M3).** The Configuration
    /// sheet used to mint the Keychain items first and call `save` after, so
    /// a refused config write (an unreadable `config.json`) left a secret in
    /// the login Keychain that nothing on disk pointed at. Deleting it
    /// afterwards is not a fix: `storeSecret` writes to a DETERMINISTIC
    /// account (slug, field key, project path), so rotating an existing
    /// secret OVERWRITES the old one in place — a compensating delete would
    /// destroy the value the surviving `config.json` still references. The
    /// only clean order is to learn the write would be refused BEFORE the
    /// Keychain is touched at all, which is what this is.
    ///
    /// Costs one inspection (the same one `save` runs again at time of use —
    /// this is a pre-check, never a substitute for the guard).
    nonisolated func preflightSave(project: ProjectEntry) throws {
        let path = Self.configPath(for: project)
        if case .unreadable = inspect(path).state {
            throw GuardedStoreError.refusedUnreadableOverwrite(path: path, label: Self.label)
        }
    }

    nonisolated func save(
        project: ProjectEntry,
        templateId: String,
        values: [String: TemplateConfigValue]
    ) throws {
        let path = Self.configPath(for: project)

        // GUARDED read-modify-write (GW-E2c) — the SAME policy the
        // `scarf-projects` MCP `project_set_config` tool applies to this
        // exact file, not a second one. That writer was guarded in W1 and
        // this Mac-side one was not: the guard belonged to the FILE via
        // whichever writer got audited, which is the whole disease this
        // phase exists to end.
        //
        // The policy, matching `ProjectMCPTools.setConfig`:
        //  * one proof-based inspection (stat-confirm + retried read) that
        //    REFUSES the write when the file is provably there and
        //    unreadable — rebuilding it would orphan every `keychain://`
        //    reference in it, with no pointer left to the secrets;
        //  * bytes that won't decode are copied aside AND refused, not
        //    rebuilt (GW-F6 / DI M8): a rebuild from `[:]` here would drop
        //    every `keychain://` reference and orphan the secrets;
        //  * the object graph is MUTATED, so every top-level key Scarf
        //    doesn't own survives the round trip;
        //  * a one-deep `config.json.bak` of whatever gets replaced.
        let (inspection, existingRoot) = inspectDecoding(JSONValue.self, at: path)
        if case .unreadable = inspection.state {
            throw GuardedStoreError.refusedUnreadableOverwrite(path: path, label: Self.label)
        }
        var root: [String: JSONValue] = [:]
        if let existingRoot, case .object(let object) = existingRoot { root = object }

        // Scarf's four keys, written from the caller's values; everything
        // else in `root` is left exactly as it was found.
        root["schemaVersion"] = .int(2)
        root["templateId"] = .string(templateId)
        root["values"] = try Self.jsonValues(from: values)
        root["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(JSONValue.object(root))
        try publish(data, to: path, after: inspection)
    }

    /// Re-express the typed values as a `JSONValue` object so they can be
    /// spliced into the graph read from disk. Routed through
    /// `TemplateConfigValue`'s own `Codable` so the on-the-wire shape stays
    /// byte-identical to what `JSONEncoder().encode(ProjectConfigFile)`
    /// produced before this became a splice.
    nonisolated private static func jsonValues(
        from values: [String: TemplateConfigValue]
    ) throws -> JSONValue {
        let data = try JSONEncoder().encode(values)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - Manifest cache (schema used by post-install editor)

    /// Load the cached manifest into a `ProjectTemplateManifest` so the
    /// editor can look up field types + labels. Returns `nil` when the
    /// project wasn't installed from a schemaful template.
    ///
    /// **Absent takes PROOF here too (GW-F2, audit DI L7.)** The old
    /// `fileExists` gate turned one dropped round-trip into `nil`, which the
    /// Configuration sheet renders as "This project isn't configurable" —
    /// a confident, false statement about the project, told to the user
    /// because a read failed. `nil` now means the cache is provably absent;
    /// a file that is there but unreadable throws, and the sheet says it
    /// couldn't read the manifest.
    nonisolated func loadCachedManifest(project: ProjectEntry) throws -> ProjectTemplateManifest? {
        let transport = context.makeTransport()
        let path = Self.manifestCachePath(for: project)
        let inspection = GuardedJSONStore(transport: transport, label: "manifest.json")
            .inspect(path, maxBytes: Self.configMaxBytes)
        switch inspection.state {
        case .absent:
            return nil
        case .unreadable(let damaged):
            throw ManifestCacheError.unreadable(path: damaged)
        case .quarantined:
            throw ManifestCacheError.unreadable(path: path)
        case .present:
            break
        }
        return try JSONDecoder().decode(
            ProjectTemplateManifest.self, from: inspection.bytes ?? Data()
        )
    }

    /// Why the cached template manifest could not be read. Deliberately NOT
    /// `GuardedStoreError`: nothing is being written here, and telling the
    /// user we are "refusing to overwrite" a file they only tried to open
    /// is the wrong sentence (GW-F2).
    enum ManifestCacheError: LocalizedError, Equatable {
        case unreadable(path: String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(path):
                return "Couldn't read this project's template manifest at \(path). It's there, but two reads of it failed — check the connection, then try again."
            }
        }
    }

    // MARK: - Secrets

    /// Resolve a `keychainRef` value into the actual secret bytes.
    /// Returns `nil` if the Keychain entry has been removed (e.g.
    /// external user cleanup, a previous uninstall that didn't finish).
    ///
    /// **`config.json` is agent-writable**, so the uri is untrusted input:
    /// it is admitted only when it parses into Scarf's own Keychain
    /// namespace AND is bound to `project` (see
    /// `TemplateKeychainRef.belongs(toProjectPath:)`). A ref pointing at
    /// another project's item resolves to `nil` — the agent in project A
    /// cannot make Scarf read project B's secret on its behalf.
    ///
    /// A project moved by hand fails the binding (its refs carry the old
    /// path's fingerprint); the secret then reads as absent and the user
    /// re-enters it in the Configuration sheet, which re-mints the ref
    /// under the current path. That is the intended migration — there is
    /// no supported hand-move flow today either way.
    nonisolated func resolveSecret(
        ref value: TemplateConfigValue,
        for project: ProjectEntry
    ) throws -> Data? {
        guard case .keychainRef(let uri) = value,
              let ref = TemplateKeychainRef.parse(uri) else {
            return nil
        }
        guard ref.belongs(toProjectPath: project.path) else {
            Self.logger.warning(
                "refusing keychain ref \(uri, privacy: .public) — not bound to project \(project.path, privacy: .public)"
            )
            return nil
        }
        let secret = try keychain.get(ref: ref)
        // OPPORTUNISTIC RE-MINT. `belongs` still accepts the retired 8-hex
        // FNV account so existing installs don't lose their secrets — and
        // that branch is chosen-preimage-breakable, so the window has to
        // actually close. Waiting for the user to re-save the field in the
        // Configuration sheet closes it for a secret that is broken, never
        // for one that works. Reading it is the event that reliably happens,
        // so that is where the migration hangs: mint the SHA-256-bound item,
        // repoint `config.json` through the guarded write, drop the legacy
        // item. Best effort — the secret is returned either way.
        if let secret, LegacyKeychainRefMigrator.isLegacy(ref) {
            LegacyKeychainRefMigrator(
                transport: context.makeTransport(), keychain: keychain
            ).migrate(
                ref: ref,
                secret: secret,
                projectPath: project.path,
                configPath: Self.configPath(for: project)
            )
        }
        return secret
    }

    /// Store a freshly-entered secret. Returns the `keychainRef` value
    /// suitable for writing into `config.json`.
    nonisolated func storeSecret(
        templateSlug: String,
        fieldKey: String,
        project: ProjectEntry,
        secret: Data
    ) throws -> TemplateConfigValue {
        let ref = TemplateKeychainRef.make(
            templateSlug: templateSlug,
            fieldKey: fieldKey,
            projectPath: project.path
        )
        try keychain.set(ref: ref, secret: secret)
        return .keychainRef(ref.uri)
    }

    /// Delete every Keychain item tracked in `refs`. Absent items are
    /// fine (uninstall may run after the user manually cleaned an
    /// entry). Any other failure is logged and re-thrown so the
    /// uninstaller can surface it.
    nonisolated func deleteSecrets(refs: [TemplateKeychainRef]) throws {
        for ref in refs {
            try keychain.delete(ref: ref)
        }
    }

    // MARK: - Schema validation (author-facing; called at bundle inspect time)

    /// Verify structural invariants on a schema: unique keys, known
    /// types, enum options, secret-without-default rule, model
    /// recommendation non-empty when present. Called by
    /// `ProjectTemplateService.inspect` before buildPlan runs.
    nonisolated static func validateSchema(_ schema: TemplateConfigSchema) throws {
        var seen = Set<String>()
        for field in schema.fields {
            if !seen.insert(field.key).inserted {
                throw TemplateConfigSchemaError.duplicateKey(field.key)
            }
            switch field.type {
            case .enum:
                let opts = field.options ?? []
                guard !opts.isEmpty else {
                    throw TemplateConfigSchemaError.emptyEnumOptions(field.key)
                }
                var seenValues = Set<String>()
                for opt in opts {
                    if !seenValues.insert(opt.value).inserted {
                        throw TemplateConfigSchemaError.duplicateEnumValue(key: field.key, value: opt.value)
                    }
                }
            case .list:
                let item = field.itemType ?? "string"
                if item != "string" {
                    throw TemplateConfigSchemaError.unsupportedListItemType(key: field.key, itemType: item)
                }
            case .secret:
                if field.defaultValue != nil {
                    throw TemplateConfigSchemaError.secretFieldHasDefault(field.key)
                }
            case .string, .text, .number, .bool:
                break
            }
        }
        if let rec = schema.modelRecommendation {
            if rec.preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TemplateConfigSchemaError.emptyModelPreferred
            }
        }
    }

    // MARK: - Value validation (runs on user input in the configure sheet)

    /// Validate user-entered values against the schema. Returns one
    /// `TemplateConfigValidationError` per problem. Empty array means
    /// the form is submittable.
    nonisolated static func validateValues(
        _ values: [String: TemplateConfigValue],
        against schema: TemplateConfigSchema
    ) -> [TemplateConfigValidationError] {
        var errors: [TemplateConfigValidationError] = []
        for field in schema.fields {
            let value = values[field.key]
            if field.required && !Self.hasMeaningfulValue(value, type: field.type) {
                errors.append(.init(fieldKey: field.key, message: "\(field.label) is required."))
                continue
            }
            guard let value else { continue }
            switch field.type {
            case .string, .text:
                if case .string(let s) = value {
                    if let min = field.minLength, s.count < min {
                        errors.append(.init(fieldKey: field.key,
                                            message: "\(field.label) must be at least \(min) characters."))
                    }
                    if let max = field.maxLength, s.count > max {
                        errors.append(.init(fieldKey: field.key,
                                            message: "\(field.label) must be at most \(max) characters."))
                    }
                    if let pattern = field.pattern,
                       s.range(of: pattern, options: .regularExpression) == nil {
                        errors.append(.init(fieldKey: field.key,
                                            message: "\(field.label) doesn't match the expected format."))
                    }
                } else {
                    errors.append(.init(fieldKey: field.key,
                                        message: "\(field.label) must be a string."))
                }

            case .number:
                if case .number(let n) = value {
                    if let min = field.minNumber, n < min {
                        errors.append(.init(fieldKey: field.key,
                                            message: "\(field.label) must be ≥ \(min)."))
                    }
                    if let max = field.maxNumber, n > max {
                        errors.append(.init(fieldKey: field.key,
                                            message: "\(field.label) must be ≤ \(max)."))
                    }
                } else {
                    errors.append(.init(fieldKey: field.key,
                                        message: "\(field.label) must be a number."))
                }

            case .bool:
                if case .bool = value { /* ok */ } else {
                    errors.append(.init(fieldKey: field.key,
                                        message: "\(field.label) must be true or false."))
                }

            case .enum:
                if case .string(let s) = value {
                    let options = (field.options ?? []).map(\.value)
                    if !options.contains(s) {
                        errors.append(.init(fieldKey: field.key,
                                            message: "\(field.label) must be one of \(options.joined(separator: ", "))."))
                    }
                } else {
                    errors.append(.init(fieldKey: field.key,
                                        message: "\(field.label) must be one of the predefined options."))
                }

            case .list:
                if case .list(let items) = value {
                    if let min = field.minItems, items.count < min {
                        errors.append(.init(fieldKey: field.key,
                                            message: "\(field.label) needs at least \(min) item(s)."))
                    }
                    if let max = field.maxItems, items.count > max {
                        errors.append(.init(fieldKey: field.key,
                                            message: "\(field.label) accepts at most \(max) item(s)."))
                    }
                } else {
                    errors.append(.init(fieldKey: field.key,
                                        message: "\(field.label) must be a list."))
                }

            case .secret:
                if case .keychainRef = value { /* opaque — trust it */ } else {
                    errors.append(.init(fieldKey: field.key,
                                        message: "\(field.label) must be supplied (Keychain entry missing)."))
                }
            }
        }
        return errors
    }

    nonisolated private static func hasMeaningfulValue(
        _ value: TemplateConfigValue?,
        type: TemplateConfigField.FieldType
    ) -> Bool {
        guard let value else { return false }
        switch (type, value) {
        case (.string, .string(let s)), (.text, .string(let s)), (.enum, .string(let s)):
            return !s.isEmpty
        case (.number, .number):
            return true
        case (.bool, .bool):
            return true
        case (.list, .list(let arr)):
            return !arr.isEmpty
        case (.secret, .keychainRef):
            return true
        default:
            return false
        }
    }
}
