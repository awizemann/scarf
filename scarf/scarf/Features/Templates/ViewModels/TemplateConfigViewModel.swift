import Foundation
import Observation
import os

/// Drives the configure form for template install + post-install editing.
///
/// **Timing of secret storage.** The VM keeps freshly-entered secret bytes
/// in-memory (`pendingSecrets`) until the user clicks the commit button.
/// Only then does `commit()` push each secret through
/// `ProjectConfigService.storeSecret` and get back a `keychainRef` URI.
/// This means cancelling the sheet never leaves an orphan Keychain
/// entry behind — the form is transactional from the user's POV.
///
/// **Validation.** Runs via `ProjectConfigService.validateValues` every
/// time the user attempts to commit. Per-field errors are tracked in
/// `errors` so the sheet can surface them inline with the offending field.
/// No live validation on every keystroke — that creates a messy
/// "error appears the moment you start typing" UX.
@Observable
@MainActor
final class TemplateConfigViewModel {
    private static let logger = Logger(subsystem: "com.scarf", category: "TemplateConfigViewModel")

    enum Mode: Sendable {
        /// User is filling in values for the first time as part of the
        /// install flow. Secrets will be written to the Keychain when
        /// `commit` succeeds.
        case install
        /// User is editing values for an already-installed project.
        /// Existing keychain refs are preserved for fields the user
        /// doesn't touch; only secrets the user actually changes get
        /// re-written to the Keychain.
        case edit(project: ProjectEntry)
    }

    let schema: TemplateConfigSchema
    let templateId: String
    let templateSlug: String
    let mode: Mode
    private let configService: ProjectConfigService

    /// Current form values, keyed by field key. Non-secret values live
    /// here directly; secret fields either hold a `.keychainRef(...)`
    /// (existing, untouched in edit mode) or nothing at all (user
    /// hasn't entered a secret yet, or they just cleared it).
    var values: [String: TemplateConfigValue] = [:]

    /// Raw secret bytes waiting to be written to the Keychain on
    /// `commit()`. Indexed by field key. `values[key]` stays as its
    /// current `.keychainRef(...)` (for edit mode) or missing (for
    /// install mode) until commit swaps it for the freshly-written
    /// ref URI.
    var pendingSecrets: [String: Data] = [:]

    /// One error per field with a problem. Populated by `commit()` on
    /// validation failure; the sheet surfaces the message inline below
    /// the offending control.
    var errors: [String: String] = [:]

    init(
        schema: TemplateConfigSchema,
        templateId: String,
        templateSlug: String,
        initialValues: [String: TemplateConfigValue] = [:],
        mode: Mode,
        configService: ProjectConfigService = ProjectConfigService()
    ) {
        self.schema = schema
        self.templateId = templateId
        self.templateSlug = templateSlug
        self.mode = mode
        self.configService = configService
        self.values = Self.applyDefaults(schema: schema, initial: initialValues)
    }

    // MARK: - Field setters (the sheet calls these as controls change)

    func setString(_ key: String, _ value: String) {
        values[key] = .string(value)
        errors.removeValue(forKey: key)
    }

    func setNumber(_ key: String, _ value: Double) {
        values[key] = .number(value)
        errors.removeValue(forKey: key)
    }

    func setBool(_ key: String, _ value: Bool) {
        values[key] = .bool(value)
        errors.removeValue(forKey: key)
    }

    func setList(_ key: String, _ items: [String]) {
        values[key] = .list(items)
        errors.removeValue(forKey: key)
    }

    /// Stage a new secret value. Doesn't hit the Keychain until
    /// `commit()`. An empty `value` clears both the pending secret and
    /// the field's stored keychainRef — only valid in edit mode, where
    /// "empty" means "I want to remove this secret."
    func setSecret(_ key: String, _ value: String) {
        if value.isEmpty {
            pendingSecrets.removeValue(forKey: key)
            values.removeValue(forKey: key)
        } else {
            pendingSecrets[key] = Data(value.utf8)
            // Keep any existing ref around; the sheet can display
            // "(changed)" while the ref is still the old one. commit()
            // overwrites on disk.
        }
        errors.removeValue(forKey: key)
    }

    // MARK: - Commit

    /// Validate, persist secrets to the Keychain, and hand back the
    /// final values dictionary. On validation failure, `errors` is
    /// populated and the method returns `nil` without touching the
    /// Keychain — the form is transactional.
    ///
    /// In install mode, `project` is required (secrets need a path
    /// hash for their Keychain account). In edit mode it falls out of
    /// the `.edit(project:)` associated value.
    func commit(project: ProjectEntry? = nil) -> [String: TemplateConfigValue]? {
        // Build the value set we're about to validate. For secrets
        // that have a pending update, we treat them as present (we'll
        // write them in a moment); for secrets already stored as
        // keychainRef, we treat them as present too. Only a completely
        // empty secret field is "missing."
        var candidate = values
        for key in pendingSecrets.keys {
            // The field is about to have a fresh keychainRef — for
            // validation purposes, use a placeholder ref so the type
            // check passes. The real ref replaces it below.
            candidate[key] = .keychainRef("pending://\(key)")
        }
        let validationErrors = ProjectConfigService.validateValues(candidate, against: schema)
        guard validationErrors.isEmpty else {
            var byField: [String: String] = [:]
            for err in validationErrors {
                guard let key = err.fieldKey else { continue }
                byField[key] = err.message
            }
            self.errors = byField
            return nil
        }

        // Validation passed — write the pending secrets to the Keychain.
        let targetProject: ProjectEntry
        switch mode {
        case .install:
            guard let project else {
                Self.logger.error("commit(project:) called in install mode without a project")
                return nil
            }
            targetProject = project
        case .edit(let proj):
            targetProject = proj
        }

        for (key, secret) in pendingSecrets {
            do {
                let ref = try configService.storeSecret(
                    templateSlug: templateSlug,
                    fieldKey: key,
                    project: targetProject,
                    secret: secret
                )
                values[key] = ref
            } catch {
                Self.logger.error("failed to store secret for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                errors[key] = "Couldn't save secret to the Keychain: \(error.localizedDescription)"
                return nil
            }
        }
        pendingSecrets.removeAll()
        errors.removeAll()
        return values
    }

    // MARK: - Helpers

    /// Seed the form with any author-supplied defaults for fields that
    /// don't already have an initial value (from a saved config.json).
    nonisolated private static func applyDefaults(
        schema: TemplateConfigSchema,
        initial: [String: TemplateConfigValue]
    ) -> [String: TemplateConfigValue] {
        var out = initial
        for field in schema.fields where out[field.key] == nil {
            if let def = field.defaultValue {
                out[field.key] = def
            }
        }
        return out
    }
}
