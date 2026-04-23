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
struct ProjectConfigService: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectConfigService")

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
    nonisolated func load(project: ProjectEntry) throws -> ProjectConfigFile? {
        let transport = context.makeTransport()
        let path = Self.configPath(for: project)
        guard transport.fileExists(path) else { return nil }
        let data = try transport.readFile(path)
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
    nonisolated func save(
        project: ProjectEntry,
        templateId: String,
        values: [String: TemplateConfigValue]
    ) throws {
        let transport = context.makeTransport()
        let file = ProjectConfigFile(
            schemaVersion: 2,
            templateId: templateId,
            values: values,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        let parent = (Self.configPath(for: project) as NSString).deletingLastPathComponent
        try transport.createDirectory(parent)
        try transport.writeFile(Self.configPath(for: project), data: data)
    }

    // MARK: - Manifest cache (schema used by post-install editor)

    /// Copy a template's `template.json` into `<project>/.scarf/manifest.json`
    /// so the post-install "Configuration" button can render the form
    /// offline. Called once by the installer after unpack + validate.
    nonisolated func cacheManifest(project: ProjectEntry, manifestData: Data) throws {
        let transport = context.makeTransport()
        let path = Self.manifestCachePath(for: project)
        let parent = (path as NSString).deletingLastPathComponent
        try transport.createDirectory(parent)
        try transport.writeFile(path, data: manifestData)
    }

    /// Load the cached manifest into a `ProjectTemplateManifest` so the
    /// editor can look up field types + labels. Returns `nil` when the
    /// project wasn't installed from a schemaful template.
    nonisolated func loadCachedManifest(project: ProjectEntry) throws -> ProjectTemplateManifest? {
        let transport = context.makeTransport()
        let path = Self.manifestCachePath(for: project)
        guard transport.fileExists(path) else { return nil }
        let data = try transport.readFile(path)
        return try JSONDecoder().decode(ProjectTemplateManifest.self, from: data)
    }

    // MARK: - Secrets

    /// Resolve a `keychainRef` value into the actual secret bytes.
    /// Returns `nil` if the Keychain entry has been removed (e.g.
    /// external user cleanup, a previous uninstall that didn't finish).
    nonisolated func resolveSecret(ref value: TemplateConfigValue) throws -> Data? {
        guard case .keychainRef(let uri) = value,
              let ref = TemplateKeychainRef.parse(uri) else {
            return nil
        }
        return try keychain.get(ref: ref)
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
