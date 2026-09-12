import Testing
import Foundation
import ScarfCore
@testable import scarf

/// GW-F1 — a refused read must never skip security-critical cleanup, and must
/// never land after destruction.
///
/// Two holes from the E5 audit:
///
/// * **SEC F1 / DI M1+M2.** `stripMemoryBlock`'s refusal (MEMORY.md present
///   but unreadable) threw out of `uninstall(plan:)` between the destructive
///   steps and the cleanup ones — the template's Keychain secrets, the
///   registry row and the mini-app grants were all skipped. Since MEMORY.md
///   sits in the Hermes home any agent can write, `chmod 000 MEMORY.md` was a
///   one-command way to make an uninstall PRESERVE the secrets it promised to
///   remove. The proof now runs at PLAN time (so the sheet says what will
///   happen) and the execute-side refusal is a warning.
/// * **DI M3.** The Configuration sheet minted Keychain items and only then
///   asked `config.json` to accept the write, orphaning the secret on refusal.
///
/// W1 shape: real temp dirs, real `LocalTransport`, failures induced by making
/// a file genuinely unreadable (mode 0000). Those cases self-skip under root,
/// where 0000 is still readable. Keychain items go through an isolated service
/// suffix, so nothing here touches the developer's login Keychain.
@Suite("GW-F1 refusal ordering")
struct GwF1RefusalOrderingTests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    private static func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    /// Install a minimal template into an isolated home and return the
    /// registry entry plus the project dir.
    private static func installMinimal(
        home: TempHermesHome,
        scratch: String
    ) async throws -> (entry: ProjectEntry, projectDir: String) {
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])
        let service = ProjectTemplateService(context: home.context)
        let inspection = try await service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)
        let entry = try ProjectTemplateInstaller(context: home.context).install(plan: plan)
        return (entry, plan.projectDir)
    }

    /// Splice extra keys into the installed `template.lock.json` — the lock is
    /// agent-writable by design, and this is the shape a template with a
    /// memory block + config secrets leaves behind.
    private static func amendLock(
        at projectDir: String,
        memoryBlockId: String?,
        keychainURIs: [String]
    ) throws {
        let path = projectDir + "/.scarf/template.lock.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        if let memoryBlockId { root["memory_block_id"] = memoryBlockId }
        if !keychainURIs.isEmpty { root["config_keychain_items"] = keychainURIs }
        try JSONSerialization.data(withJSONObject: root)
            .write(to: URL(fileURLWithPath: path))
    }

    private static func registryText(_ home: TempHermesHome) -> String {
        (try? String(contentsOfFile: home.context.paths.projectsRegistry, encoding: .utf8)) ?? ""
    }

    // MARK: - SEC F1 / DI M2 — the attack

    /// The attack, end to end: an unreadable MEMORY.md must not buy the
    /// template's secrets another day in the login Keychain, and must not
    /// leave the sidebar row behind either.
    @Test func unreadableMemoryDoesNotPreserveTemplateSecretsOrTheRegistryRow() async throws {
        try #require(!Self.runningAsRoot)
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let installed = try await Self.installMinimal(home: home, scratch: scratch)
        let blockId = "tester/minimal"

        // A secret this template "installed", in an isolated Keychain.
        let keychain = ProjectConfigKeychain(testServiceSuffix: "tests-" + UUID().uuidString)
        let ref = TemplateKeychainRef.make(
            templateSlug: "minimal", fieldKey: "api_token", projectPath: installed.projectDir
        )
        try keychain.set(ref: ref, secret: Data("sk-top-secret".utf8))
        defer { try? keychain.delete(ref: ref) }
        try Self.amendLock(
            at: installed.projectDir, memoryBlockId: blockId, keychainURIs: [ref.uri]
        )

        // …and the agent's move: a MEMORY.md that holds the block and cannot
        // be read.
        let memoryPath = home.context.paths.memoryMD
        let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: blockId)
        let end = ProjectTemplateService.memoryBlockEndMarker(templateId: blockId)
        let original = "# Notes\n\n\(begin)\ntemplate stuff\n\(end)\n\nyears of prose\n"
        try FileManager.default.createDirectory(
            atPath: (memoryPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(original.utf8).write(to: URL(fileURLWithPath: memoryPath))
        try Self.chmod(memoryPath, 0o000)

        let uninstaller = ProjectTemplateUninstaller(context: home.context, keychain: keychain)
        let plan = try uninstaller.loadUninstallPlan(for: installed.entry)

        // DI M1: unreadable is its own answer, decided BEFORE anything is
        // deleted — not silently folded into "no block installed".
        #expect(plan.memoryUnreadable != nil)
        #expect(plan.memoryBlockPresent == false)

        // DI M2 / SEC F1: the uninstall completes rather than throwing
        // mid-flight…
        try uninstaller.uninstall(plan: plan)

        // …the secret is gone…
        #expect((try keychain.get(ref: ref)) == nil)
        // …the project's files are gone…
        #expect(FileManager.default.fileExists(atPath: installed.projectDir) == false)
        // …the registry row is gone…
        #expect(Self.registryText(home).contains(installed.projectDir) == false)
        // …and the file we could not read is untouched, block and all.
        try Self.chmod(memoryPath, 0o644)
        #expect((try String(contentsOfFile: memoryPath, encoding: .utf8)) == original)
    }

    /// Healthy-path parity: a readable MEMORY.md still plans and performs the
    /// strip exactly as before.
    @Test func aReadableMemoryBlockIsStillPlannedAndStripped() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let installed = try await Self.installMinimal(home: home, scratch: scratch)
        let blockId = "tester/minimal"
        try Self.amendLock(at: installed.projectDir, memoryBlockId: blockId, keychainURIs: [])

        let memoryPath = home.context.paths.memoryMD
        let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: blockId)
        let end = ProjectTemplateService.memoryBlockEndMarker(templateId: blockId)
        try FileManager.default.createDirectory(
            atPath: (memoryPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("# Notes\n\n\(begin)\ntemplate stuff\n\(end)\n\nyears of prose\n".utf8)
            .write(to: URL(fileURLWithPath: memoryPath))

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        let plan = try uninstaller.loadUninstallPlan(for: installed.entry)
        #expect(plan.memoryBlockPresent)
        #expect(plan.memoryUnreadable == nil)

        try uninstaller.uninstall(plan: plan)
        let after = try String(contentsOfFile: memoryPath, encoding: .utf8)
        #expect(!after.contains(begin))
        #expect(after.contains("years of prose"))
    }

    /// An absent MEMORY.md is still "nothing to strip", not a warning — the
    /// discrimination the plan now makes has to cut both ways.
    @Test func anAbsentMemoryFileIsNotReportedAsUnreadable() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let installed = try await Self.installMinimal(home: home, scratch: scratch)
        try Self.amendLock(
            at: installed.projectDir, memoryBlockId: "tester/minimal", keychainURIs: []
        )
        try? FileManager.default.removeItem(atPath: home.context.paths.memoryMD)

        let plan = try ProjectTemplateUninstaller(context: home.context)
            .loadUninstallPlan(for: installed.entry)
        #expect(plan.memoryUnreadable == nil)
        #expect(plan.memoryBlockPresent == false)
    }

    // MARK: - DI M3 — order the config refusal before the Keychain write

    /// A config sheet commit whose destination is unreadable must leave the
    /// Keychain exactly as it found it: no orphan item for a new field, and
    /// — the case a compensating delete could never fix — no overwritten
    /// value for a field the surviving `config.json` still points at.
    @MainActor
    @Test func aRefusedConfigSaveNeverReachesTheKeychain() throws {
        try #require(!Self.runningAsRoot)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-gwf1-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: dir.path + "/.scarf/config.json"
            )
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(
            atPath: dir.path + "/.scarf", withIntermediateDirectories: true
        )
        let project = ProjectEntry(name: "P", path: dir.path)
        let configPath = dir.path + "/.scarf/config.json"
        try Data(#"{"schemaVersion":2,"templateId":"t/x","values":{}}"#.utf8)
            .write(to: URL(fileURLWithPath: configPath))
        try Self.chmod(configPath, 0o000)

        let keychain = ProjectConfigKeychain(testServiceSuffix: "tests-" + UUID().uuidString)
        let service = ProjectConfigService(keychain: keychain)
        // The field the user is ROTATING: its old value must survive a
        // refusal, because `config.json` still references this exact account.
        let existing = TemplateKeychainRef.make(
            templateSlug: "acme", fieldKey: "api_token", projectPath: dir.path
        )
        try keychain.set(ref: existing, secret: Data("old-secret".utf8))
        defer { try? keychain.delete(ref: existing) }

        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "api_token", type: .secret, label: "API Token",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: nil,
                      maxNumber: nil, step: nil, itemType: nil,
                      minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let vm = TemplateConfigViewModel(
            schema: schema,
            templateId: "tester/acme",
            templateSlug: "acme",
            initialValues: ["api_token": .keychainRef(existing.uri)],
            mode: .edit(project: project),
            configService: service
        )
        vm.setSecret("api_token", "rotated-secret")

        #expect(vm.commit() == nil)
        #expect(vm.commitError != nil)
        // The old secret is intact — not overwritten, not deleted.
        #expect((try keychain.get(ref: existing)) == Data("old-secret".utf8))
        // …and the pending edit is still pending, so a retry after fixing
        // the file works.
        #expect(vm.pendingSecrets["api_token"] != nil)
    }

    /// The same commit succeeds once the destination is readable — the
    /// pre-check must not become a new way for an ordinary save to fail.
    @MainActor
    @Test func ahealthyCommitStillWritesTheSecret() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-gwf1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            atPath: dir.path + "/.scarf", withIntermediateDirectories: true
        )
        let project = ProjectEntry(name: "P", path: dir.path)
        let keychain = ProjectConfigKeychain(testServiceSuffix: "tests-" + UUID().uuidString)
        let service = ProjectConfigService(keychain: keychain)

        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "api_token", type: .secret, label: "API Token",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: nil,
                      maxNumber: nil, step: nil, itemType: nil,
                      minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let vm = TemplateConfigViewModel(
            schema: schema,
            templateId: "tester/acme",
            templateSlug: "acme",
            mode: .edit(project: project),
            configService: service
        )
        vm.setSecret("api_token", "fresh-secret")

        let values = try #require(vm.commit())
        #expect(vm.commitError == nil)
        let ref = TemplateKeychainRef.make(
            templateSlug: "acme", fieldKey: "api_token", projectPath: dir.path
        )
        defer { try? keychain.delete(ref: ref) }
        #expect((try keychain.get(ref: ref)) == Data("fresh-secret".utf8))
        if case .keychainRef(let uri) = values["api_token"] {
            #expect(uri == ref.uri)
        } else {
            Issue.record("api_token should have been stored as a keychainRef")
        }
    }
}
