import Foundation
import ScarfCore

// MARK: - Schema (ships inside template.json as manifest.config)

/// Author-declared configuration schema for a template. Published as the
/// `config` block of `template.json` (manifest schemaVersion 2). Users fill
/// in values at install time via `TemplateConfigSheet`; values land in
/// `<project>/.scarf/config.json` with secrets resolved through the
/// macOS Keychain.
nonisolated struct TemplateConfigSchema: Codable, Sendable, Equatable {
    let fields: [TemplateConfigField]
    let modelRecommendation: TemplateModelRecommendation?

    enum CodingKeys: String, CodingKey {
        case fields = "schema"
        case modelRecommendation
    }

    nonisolated var isEmpty: Bool { fields.isEmpty }

    /// Fast lookup by key. Validators guarantee keys are unique within a
    /// schema at manifest-parse time, so this is safe.
    nonisolated func field(for key: String) -> TemplateConfigField? {
        fields.first { $0.key == key }
    }
}

/// One configurable field the user fills in. Discriminated by `type`.
/// We keep one flat struct rather than an enum-associated-value encoding
/// so JSON reads cleanly as a record and authors can hand-edit manifests
/// without fighting Swift's `"case"` discriminator syntax.
nonisolated struct TemplateConfigField: Codable, Sendable, Equatable, Identifiable {
    nonisolated var id: String { key }

    let key: String
    let type: FieldType
    let label: String
    let description: String?
    let required: Bool
    let placeholder: String?

    // Type-specific constraints — all optional. The validator enforces
    // only the ones that apply to `type`; extras are ignored.
    let defaultValue: TemplateConfigValue?
    let options: [EnumOption]?        // type == .enum
    let minLength: Int?               // type == .string / .text
    let maxLength: Int?
    let pattern: String?              // type == .string (regex)
    let minNumber: Double?            // type == .number
    let maxNumber: Double?
    let step: Double?
    let itemType: String?             // type == .list — only "string" supported in v1
    let minItems: Int?
    let maxItems: Int?

    enum CodingKeys: String, CodingKey {
        case key, type, label, description, required, placeholder
        case defaultValue = "default"
        case options
        case minLength, maxLength, pattern
        case minNumber = "min"
        case maxNumber = "max"
        case step
        case itemType, minItems, maxItems
    }

    enum FieldType: String, Codable, Sendable, Equatable {
        case string
        case text
        case number
        case bool
        case `enum`
        case list
        case secret
    }

    /// One option of an `enum` field. `value` is what ends up in
    /// `config.json`; `label` is the human-readable text shown in the UI.
    struct EnumOption: Codable, Sendable, Equatable, Identifiable {
        nonisolated var id: String { value }
        let value: String
        let label: String
    }
}

/// Author's model-of-choice hint, shown in the install preview + on the
/// catalog detail page. Purely advisory — Scarf never auto-switches the
/// active model. Individual cron jobs can override via
/// `HermesCronJob.model` if the author wants enforcement.
nonisolated struct TemplateModelRecommendation: Codable, Sendable, Equatable {
    let preferred: String
    let rationale: String?
    let alternatives: [String]?
}

// MARK: - Values (what lands in config.json and the Keychain)

/// One configured value. Secrets don't carry their raw bytes — only a
/// Keychain reference of the form `"keychain://<service>/<account>"` so
/// serialising config.json to disk never leaks the secret into git or
/// into backups.
nonisolated enum TemplateConfigValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([String])
    case keychainRef(String)

    /// Convenience: the string representation suitable for display or
    /// for writing into a placeholder that the agent reads. Keychain
    /// refs return the ref string, not the resolved secret — callers
    /// resolve through `ProjectConfigKeychain` explicitly when they
    /// actually need the plaintext.
    nonisolated var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            return n.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(n))
                : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .list(let items): return items.joined(separator: ", ")
        case .keychainRef(let ref): return ref
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            // Preserve the keychain:// scheme so secrets round-trip as
            // references, not as plaintext.
            if s.hasPrefix("keychain://") {
                self = .keychainRef(s)
            } else {
                self = .string(s)
            }
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let arr = try? container.decode([String].self) {
            self = .list(arr)
        } else {
            throw DecodingError.typeMismatch(
                TemplateConfigValue.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected String, Bool, Number, or [String]")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .list(let items): try container.encode(items)
        case .keychainRef(let ref): try container.encode(ref)
        }
    }
}

// MARK: - On-disk shape (what's in <project>/.scarf/config.json)

/// The JSON file the installer writes + the editor reads. Non-secret
/// values appear inline; secrets are `"keychain://<service>/<account>"`
/// references that `ProjectConfigService` resolves through the Keychain
/// on demand.
nonisolated struct ProjectConfigFile: Codable, Sendable {
    let schemaVersion: Int
    let templateId: String
    var values: [String: TemplateConfigValue]
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case templateId
        case values
        case updatedAt
    }
}

// MARK: - Keychain reference helpers

/// Lifted into `ScarfCore` (`ScarfCore/Services/ProjectConfigKeychain.swift`)
/// so the `scarf-projects` MCP server's `project_set_config` tool can mint
/// and resolve the exact same refs through the exact same Keychain calls
/// this app's Configuration UI uses. This typealias keeps every existing
/// call site in the app target working unchanged.
typealias TemplateKeychainRef = ScarfCore.TemplateKeychainRef

// MARK: - Validation

/// One schema- or value-validation problem. Carries `fieldKey` so the
/// UI can surface the error inline with the field rather than at the
/// top of the form.
nonisolated struct TemplateConfigValidationError: Error, Sendable, Equatable {
    let fieldKey: String?
    let message: String
}

nonisolated enum TemplateConfigSchemaError: LocalizedError, Sendable {
    case duplicateKey(String)
    case unsupportedType(String)
    case emptyEnumOptions(String)
    case duplicateEnumValue(key: String, value: String)
    case unsupportedListItemType(key: String, itemType: String)
    case secretFieldHasDefault(String)
    case emptyModelPreferred

    var errorDescription: String? {
        switch self {
        case .duplicateKey(let k):
            return "Config schema has duplicate key: \(k)"
        case .unsupportedType(let t):
            return "Config schema uses unsupported field type: \(t)"
        case .emptyEnumOptions(let k):
            return "Enum field '\(k)' must declare at least one option"
        case .duplicateEnumValue(let k, let v):
            return "Enum field '\(k)' has duplicate option value: \(v)"
        case .unsupportedListItemType(let k, let t):
            return "List field '\(k)' uses unsupported itemType '\(t)'. Only 'string' is supported in v1."
        case .secretFieldHasDefault(let k):
            return "Secret field '\(k)' cannot declare a default value — secrets belong only in the Keychain."
        case .emptyModelPreferred:
            return "modelRecommendation.preferred must be a non-empty model id."
        }
    }
}
