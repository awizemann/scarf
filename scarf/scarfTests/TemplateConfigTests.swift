import Testing
import Foundation
@testable import scarf

// MARK: - Schema validation

@Suite struct TemplateConfigSchemaValidationTests {

    @Test func acceptsMinimalValidSchema() throws {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "name", type: .string, label: "Name",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: nil,
                      maxNumber: nil, step: nil, itemType: nil,
                      minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        try ProjectConfigService.validateSchema(schema)
    }

    @Test func rejectsDuplicateKeys() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "same", type: .string, label: "A", description: nil,
                      required: false, placeholder: nil, defaultValue: nil,
                      options: nil, minLength: nil, maxLength: nil,
                      pattern: nil, minNumber: nil, maxNumber: nil,
                      step: nil, itemType: nil, minItems: nil, maxItems: nil),
                .init(key: "same", type: .bool, label: "B", description: nil,
                      required: false, placeholder: nil, defaultValue: nil,
                      options: nil, minLength: nil, maxLength: nil,
                      pattern: nil, minNumber: nil, maxNumber: nil,
                      step: nil, itemType: nil, minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        #expect(throws: TemplateConfigSchemaError.self) {
            try ProjectConfigService.validateSchema(schema)
        }
    }

    @Test func rejectsSecretWithDefault() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "api_key", type: .secret, label: "API Key",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: .string("leaked-by-accident"),
                      options: nil, minLength: nil, maxLength: nil,
                      pattern: nil, minNumber: nil, maxNumber: nil,
                      step: nil, itemType: nil, minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        #expect(throws: TemplateConfigSchemaError.self) {
            try ProjectConfigService.validateSchema(schema)
        }
    }

    @Test func rejectsEnumWithoutOptions() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "choice", type: .enum, label: "Choice",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: [],
                      minLength: nil, maxLength: nil, pattern: nil,
                      minNumber: nil, maxNumber: nil, step: nil,
                      itemType: nil, minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        #expect(throws: TemplateConfigSchemaError.self) {
            try ProjectConfigService.validateSchema(schema)
        }
    }

    @Test func rejectsEnumWithDuplicateValues() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "choice", type: .enum, label: "Choice",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil,
                      options: [.init(value: "a", label: "A"),
                                .init(value: "a", label: "Another A")],
                      minLength: nil, maxLength: nil, pattern: nil,
                      minNumber: nil, maxNumber: nil, step: nil,
                      itemType: nil, minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        #expect(throws: TemplateConfigSchemaError.self) {
            try ProjectConfigService.validateSchema(schema)
        }
    }

    @Test func rejectsUnsupportedListItemType() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "items", type: .list, label: "Items",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil,
                      minLength: nil, maxLength: nil, pattern: nil,
                      minNumber: nil, maxNumber: nil, step: nil,
                      itemType: "number", minItems: 1, maxItems: 10)
            ],
            modelRecommendation: nil
        )
        #expect(throws: TemplateConfigSchemaError.self) {
            try ProjectConfigService.validateSchema(schema)
        }
    }

    @Test func rejectsEmptyModelPreferred() {
        let schema = TemplateConfigSchema(
            fields: [],
            modelRecommendation: .init(preferred: "  ", rationale: nil, alternatives: nil)
        )
        #expect(throws: TemplateConfigSchemaError.self) {
            try ProjectConfigService.validateSchema(schema)
        }
    }
}

// MARK: - Value validation

@Suite struct TemplateConfigValueValidationTests {

    @Test func requiredFieldRejectsEmptyString() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "name", type: .string, label: "Name",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: nil,
                      maxNumber: nil, step: nil, itemType: nil,
                      minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let errors = ProjectConfigService.validateValues(
            ["name": .string("")], against: schema
        )
        #expect(errors.count == 1)
        #expect(errors.first?.fieldKey == "name")
    }

    @Test func patternRejectsBadInput() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "email", type: .string, label: "Email",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: "^[^@]+@[^@]+$",
                      minNumber: nil, maxNumber: nil, step: nil,
                      itemType: nil, minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let errors = ProjectConfigService.validateValues(
            ["email": .string("not-an-email")], against: schema
        )
        #expect(errors.count == 1)
    }

    @Test func numberRangeEnforced() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "port", type: .number, label: "Port",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: 1024,
                      maxNumber: 65535, step: nil, itemType: nil,
                      minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let errors = ProjectConfigService.validateValues(
            ["port": .number(80)], against: schema
        )
        #expect(errors.count == 1)
    }

    @Test func enumRejectsUnknownValue() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "mode", type: .enum, label: "Mode",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil,
                      options: [.init(value: "fast", label: "Fast"),
                                .init(value: "slow", label: "Slow")],
                      minLength: nil, maxLength: nil, pattern: nil,
                      minNumber: nil, maxNumber: nil, step: nil,
                      itemType: nil, minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let errors = ProjectConfigService.validateValues(
            ["mode": .string("medium")], against: schema
        )
        #expect(errors.count == 1)
    }

    @Test func listItemBoundsEnforced() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "urls", type: .list, label: "URLs",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: nil,
                      maxNumber: nil, step: nil, itemType: "string",
                      minItems: 1, maxItems: 3)
            ],
            modelRecommendation: nil
        )
        let tooFew = ProjectConfigService.validateValues(
            ["urls": .list([])], against: schema
        )
        let tooMany = ProjectConfigService.validateValues(
            ["urls": .list(["a", "b", "c", "d"])], against: schema
        )
        let justRight = ProjectConfigService.validateValues(
            ["urls": .list(["a", "b"])], against: schema
        )
        #expect(tooFew.count == 1)
        #expect(tooMany.count == 1)
        #expect(justRight.isEmpty)
    }

    @Test func secretFieldAcceptsKeychainRef() {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "tok", type: .secret, label: "Token",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: nil,
                      maxNumber: nil, step: nil, itemType: nil,
                      minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let errors = ProjectConfigService.validateValues(
            ["tok": .keychainRef("keychain://test/tok:abc")],
            against: schema
        )
        #expect(errors.isEmpty)
    }
}

// MARK: - Keychain ref helpers

@Suite struct TemplateKeychainRefTests {

    @Test func uriRoundTrips() {
        let ref = TemplateKeychainRef(
            service: "com.scarf.template.alice-foo",
            account: "api_key:deadbeef"
        )
        #expect(ref.uri == "keychain://com.scarf.template.alice-foo/api_key:deadbeef")
        let parsed = TemplateKeychainRef.parse(ref.uri)
        #expect(parsed == ref)
    }

    @Test func parseRejectsMalformedUris() {
        #expect(TemplateKeychainRef.parse("") == nil)
        #expect(TemplateKeychainRef.parse("keychain://") == nil)
        #expect(TemplateKeychainRef.parse("keychain:///account-only") == nil)
        #expect(TemplateKeychainRef.parse("keychain://service-only") == nil)
        #expect(TemplateKeychainRef.parse("https://example.com/foo") == nil)
    }

    @Test func hashDiffersByProjectPath() {
        let a = TemplateKeychainRef.make(templateSlug: "s", fieldKey: "k", projectPath: "/Users/a/p1")
        let b = TemplateKeychainRef.make(templateSlug: "s", fieldKey: "k", projectPath: "/Users/a/p2")
        #expect(a.service == b.service) // same template
        #expect(a.account != b.account) // different project → different hash suffix
    }

    @Test func hashStableForSamePath() {
        let a = TemplateKeychainRef.make(templateSlug: "s", fieldKey: "k", projectPath: "/Users/a/p1")
        let b = TemplateKeychainRef.make(templateSlug: "s", fieldKey: "k", projectPath: "/Users/a/p1")
        #expect(a == b)
    }
}

// MARK: - On-disk config round-trip

@Suite struct ProjectConfigFileTests {

    @Test func roundTripsNonSecretValues() throws {
        let file = ProjectConfigFile(
            schemaVersion: 2,
            templateId: "alice/example",
            values: [
                "name": .string("Alice"),
                "enabled": .bool(true),
                "count": .number(42),
                "tags": .list(["a", "b", "c"]),
            ],
            updatedAt: "2026-04-25T00:00:00Z"
        )
        let encoded = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ProjectConfigFile.self, from: encoded)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.templateId == "alice/example")
        #expect(decoded.values["name"] == .string("Alice"))
        #expect(decoded.values["enabled"] == .bool(true))
        #expect(decoded.values["count"] == .number(42))
        #expect(decoded.values["tags"] == .list(["a", "b", "c"]))
    }

    @Test func preservesKeychainRefsOnRoundTrip() throws {
        let file = ProjectConfigFile(
            schemaVersion: 2,
            templateId: "alice/example",
            values: ["tok": .keychainRef("keychain://com.scarf.template.alice-example/tok:deadbeef")],
            updatedAt: "2026-04-25T00:00:00Z"
        )
        let encoded = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ProjectConfigFile.self, from: encoded)
        // Keychain refs must NOT demote to plain strings on round-trip
        // — otherwise a post-install editor would lose the secret
        // binding when saving unchanged values.
        #expect(decoded.values["tok"] == .keychainRef("keychain://com.scarf.template.alice-example/tok:deadbeef"))
    }
}

// MARK: - ProjectConfigService + Keychain integration

/// Exercises the full secret-storage path through a real macOS Keychain
/// with a test-only service suffix so nothing leaks into the user's
/// login Keychain. Every test sets + reads + deletes within a unique
/// service name so parallel runs don't collide.
@Suite struct ProjectConfigSecretsTests {

    @Test func storeAndResolveSecret() throws {
        let suffix = "tests-" + UUID().uuidString
        let keychain = ProjectConfigKeychain(testServiceSuffix: suffix)
        let service = ProjectConfigService(keychain: keychain)
        let project = ProjectEntry(name: "Scratch", path: NSTemporaryDirectory() + UUID().uuidString)

        let stored = try service.storeSecret(
            templateSlug: "alice-example",
            fieldKey: "api_key",
            project: project,
            secret: Data("hunter2".utf8)
        )

        // What goes into config.json is a keychainRef, not the bytes.
        guard case .keychainRef(let uri) = stored else {
            Issue.record("expected keychainRef, got \(stored)")
            return
        }
        #expect(uri.hasPrefix("keychain://"))

        // Resolve brings the bytes back.
        let resolved = try service.resolveSecret(ref: stored)
        #expect(resolved == Data("hunter2".utf8))

        // Clean up so we don't leave a test item in the Keychain.
        if let ref = TemplateKeychainRef.parse(uri) {
            try keychain.delete(ref: ref)
            #expect((try keychain.get(ref: ref)) == nil)
        }
    }

    @Test func setOverwritesExistingSecret() throws {
        let suffix = "tests-" + UUID().uuidString
        let keychain = ProjectConfigKeychain(testServiceSuffix: suffix)
        let ref = TemplateKeychainRef(service: "com.scarf.template.overwrite", account: "k:1")
        try keychain.set(ref: ref, secret: Data("first".utf8))
        try keychain.set(ref: ref, secret: Data("second".utf8))
        #expect((try keychain.get(ref: ref)) == Data("second".utf8))
        try keychain.delete(ref: ref)
    }

    @Test func deleteOfMissingItemSucceeds() throws {
        let suffix = "tests-" + UUID().uuidString
        let keychain = ProjectConfigKeychain(testServiceSuffix: suffix)
        let ref = TemplateKeychainRef(service: "com.scarf.template.absent", account: "never:set")
        // Deleting a non-existent item is a no-op — must not throw.
        try keychain.delete(ref: ref)
    }

    @Test func deleteMultipleSecretsClearsAll() throws {
        let suffix = "tests-" + UUID().uuidString
        let keychain = ProjectConfigKeychain(testServiceSuffix: suffix)
        let service = ProjectConfigService(keychain: keychain)

        let refs = (0..<3).map { i in
            TemplateKeychainRef(service: "com.scarf.template.bulk", account: "k:\(i)")
        }
        for ref in refs {
            try keychain.set(ref: ref, secret: Data("v".utf8))
        }
        try service.deleteSecrets(refs: refs)
        for ref in refs {
            #expect((try keychain.get(ref: ref)) == nil)
        }
    }
}
