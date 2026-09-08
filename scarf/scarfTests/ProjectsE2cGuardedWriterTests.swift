import Testing
import Foundation
import ScarfCore
@testable import scarf

/// GW-E2c — the Mac-target half of the projects/skills surface converted off
/// destroy-shaped read-modify-write: `<project>/.scarf/config.json`, the two
/// `manifest.json` writers, the uninstaller's `MEMORY.md` splice, and the
/// three bootstrap gates whose "absent" was inference.
///
/// W1 shape: real files, real `LocalTransport`, and the failure is induced by
/// making a file genuinely unreadable (mode 0000) rather than by a mock that
/// lies. Those cases self-skip under root, where 0000 is still readable.
@Suite("Projects E2c guarded writers")
struct ProjectsE2cGuardedWriterTests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    private static func withTempDir(_ body: (String) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-e2c-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body(dir.path)
    }

    private static func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    private static func write(_ contents: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func json(_ path: String) -> [String: Any]? {
        (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    // MARK: - config.json (ProjectConfigService)

    /// The parity fix: the MCP writer of this same file preserved unknown
    /// top-level keys; the Mac-side one re-encoded a fresh four-key object
    /// and dropped them.
    @Test func configSavePreservesEveryKeyScarfDoesNotOwn() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "P", path: dir)
            try Self.write(
                """
                {
                  "schemaVersion": 2,
                  "templateId": "alice/example",
                  "values": {"old": "value"},
                  "updatedAt": "2026-01-01T00:00:00Z",
                  "somethingElseEntirely": {"nested": [1, 2, 3]}
                }
                """,
                to: dir + "/.scarf/config.json"
            )

            try ProjectConfigService(context: .local).save(
                project: project, templateId: "alice/example", values: ["new": .string("v")]
            )

            let root = try #require(Self.json(dir + "/.scarf/config.json"))
            #expect((root["values"] as? [String: Any])?["new"] != nil)
            #expect(
                root["somethingElseEntirely"] != nil,
                "an unknown top-level key must survive a Configuration save"
            )
        }
    }

    @Test func configSaveRefusesOverAnUnreadableConfigJSON() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "P", path: dir)
            let path = dir + "/.scarf/config.json"
            let original = "{\"schemaVersion\":2,\"templateId\":\"t\",\"values\":{\"k\":\"secret-ref\"},\"updatedAt\":\"x\"}"
            try Self.write(original, to: path)
            try Self.chmod(path, 0o000)

            #expect(throws: GuardedStoreError.self) {
                try ProjectConfigService(context: .local).save(
                    project: project, templateId: "t", values: [:]
                )
            }
            // The load half of the same hole: an unreadable file must not
            // read as "no config", because the form would then save defaults
            // over it.
            #expect(throws: GuardedStoreError.self) {
                _ = try ProjectConfigService(context: .local).load(project: project)
            }

            try Self.chmod(path, 0o644)
            #expect(
                Self.text(path) == original,
                "rebuilding this file orphans every keychain:// ref in it"
            )
        }
    }

    @Test func configSaveStillWritesFreshWhenTheFileIsAbsent() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "P", path: dir)
            try ProjectConfigService(context: .local).save(
                project: project, templateId: "t", values: ["a": .string("b")]
            )
            let loaded = try #require(
                try ProjectConfigService(context: .local).load(project: project)
            )
            #expect(loaded.values["a"] == .string("b"))
            #expect(loaded.templateId == "t")
        }
    }

    @Test func configSaveKeepsABakOfWhatItReplaced() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "P", path: dir)
            let service = ProjectConfigService(context: .local)
            try service.save(project: project, templateId: "t", values: ["a": .string("1")])
            let first = try #require(Self.text(dir + "/.scarf/config.json"))
            try service.save(project: project, templateId: "t", values: ["a": .string("2")])
            #expect(Self.text(dir + "/.scarf/config.json.bak") == first)
        }
    }

    // MARK: - manifest.json (both writers, one store)

    private static let realManifest = """
    {
      "schemaVersion": 3,
      "id": "alice/real-template",
      "name": "Real",
      "version": "2.1.0",
      "description": "A real installed template",
      "contents": {"dashboard": true, "agentsMd": true},
      "authorNotesTheAppNeverModels": "keep me"
    }
    """

    @Test func tenantMintPreservesTheManifestAndItsUnknownKeys() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "Repo", path: dir)
            try Self.write(Self.realManifest, to: dir + "/.scarf/manifest.json")

            try KanbanTenantResolver(context: .local).setTenant("scarf:mine", for: project)

            let root = try #require(Self.json(dir + "/.scarf/manifest.json"))
            #expect(root["kanbanTenant"] as? String == "scarf:mine")
            #expect(root["version"] as? String == "2.1.0", "no sentinel over a real manifest")
            #expect(
                root["authorNotesTheAppNeverModels"] as? String == "keep me",
                "both writers used to re-encode through the model and drop this"
            )
        }
    }

    @Test func presetBindPreservesTheManifestAndItsUnknownKeys() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "Repo", path: dir)
            try Self.write(Self.realManifest, to: dir + "/.scarf/manifest.json")

            try ProjectModelPresetBinding(context: .local).bind(presetID: "abc", to: project)

            let root = try #require(Self.json(dir + "/.scarf/manifest.json"))
            #expect(root["modelPresetID"] as? String == "abc")
            #expect(root["id"] as? String == "alice/real-template")
            #expect(root["authorNotesTheAppNeverModels"] as? String == "keep me")
        }
    }

    /// THE BUG: a read that merely FAILED used to mint a `0.0.0` sentinel
    /// over a real template manifest.
    @Test func manifestWritersRefuseRatherThanWriteASentinelOverAnUnreadableManifest() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "Repo", path: dir)
            let path = dir + "/.scarf/manifest.json"
            try Self.write(Self.realManifest, to: path)
            try Self.chmod(path, 0o000)

            #expect(throws: GuardedStoreError.self) {
                try KanbanTenantResolver(context: .local).setTenant("scarf:mine", for: project)
            }
            #expect(throws: GuardedStoreError.self) {
                try ProjectModelPresetBinding(context: .local).bind(presetID: "abc", to: project)
            }

            try Self.chmod(path, 0o644)
            #expect(Self.text(path) == Self.realManifest)
        }
    }

    @Test func bareProjectStillGetsItsSentinelManifest() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "Bare", path: dir)
            try KanbanTenantResolver(context: .local).setTenant("scarf:bare", for: project)
            let root = try #require(Self.json(dir + "/.scarf/manifest.json"))
            #expect(root["kanbanTenant"] as? String == "scarf:bare")
            #expect(root["version"] as? String == ProjectManifestProjection.sentinelVersion)
        }
    }

    // MARK: - MEMORY.md (uninstaller splice)

    @Test func memoryStripRefusesOnAnUnreadableFileAndKeepsABakOtherwise() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { dir in
            let memoryPath = dir + "/MEMORY.md"
            let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: "tmpl")
            let end = ProjectTemplateService.memoryBlockEndMarker(templateId: "tmpl")
            let original = "# My notes\n\n\(begin)\ntemplate stuff\n\(end)\n\nyears of prose\n"
            try Self.write(original, to: memoryPath)
            try Self.chmod(memoryPath, 0o000)

            let uninstaller = ProjectTemplateUninstaller(context: .local)
            #expect(throws: ProjectTemplateError.self) {
                try uninstaller.stripMemoryBlock(
                    blockId: "tmpl", memoryPath: memoryPath, transport: LocalTransport()
                )
            }
            try Self.chmod(memoryPath, 0o644)
            #expect(Self.text(memoryPath) == original)

            // Healthy path: strips its own region and keeps the .bak the
            // installer's half has had since G2.
            try uninstaller.stripMemoryBlock(
                blockId: "tmpl", memoryPath: memoryPath, transport: LocalTransport()
            )
            let after = try #require(Self.text(memoryPath))
            #expect(!after.contains(begin))
            #expect(after.contains("years of prose"))
            #expect(Self.text(memoryPath + ".bak") == original)
        }
    }

    // MARK: - Bootstrap gates (proof, not inference)

    @Test func skillBootstrapSkipsRatherThanDowngradingAnUnreadableSkill() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { dir in
            let ctx = ServerContext.local(home: URL(fileURLWithPath: dir + "/.hermes"))
            let destDir = ctx.paths.skillsDir + "/scarf/scarf-help"
            let path = destDir + "/SKILL.md"
            let handEdited = "---\nname: scarf-help\nversion: 99.0.0\n---\n\nmy own edits\n"
            try Self.write(handEdited, to: path)
            try Self.chmod(path, 0o000)

            // Bundled source is NEWER, so without proof the gate would
            // "upgrade" the hand-edited copy away.
            let bundled = dir + "/bundle/scarf-help"
            try Self.write(
                "---\nname: scarf-help\nversion: 100.0.0\n---\n\nbundled\n",
                to: bundled + "/SKILL.md"
            )
            try SkillBootstrapService(context: ctx).installSkill(
                from: URL(fileURLWithPath: bundled),
                named: "scarf-help",
                transport: LocalTransport()
            )

            try Self.chmod(path, 0o644)
            #expect(
                Self.text(path) == handEdited,
                "a blipped read used to downgrade the user's newer skill, permanently"
            )
        }
    }

    @Test func slashCommandBootstrapSkipsRatherThanDowngradingAnUnreadableCommand() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { dir in
            let ctx = ServerContext.local(home: URL(fileURLWithPath: dir + "/.hermes"))
            let path = ctx.paths.globalSlashCommandsDir + "/scarf-help.md"
            let handEdited = "---\nname: scarf-help\nversion: 99.0.0\n---\n\nmy own edits\n"
            try Self.write(handEdited, to: path)
            try Self.chmod(path, 0o000)

            let bundled = dir + "/bundle/scarf-help.md"
            try Self.write(
                "---\nname: scarf-help\nversion: 100.0.0\n---\n\nbundled\n", to: bundled
            )
            try SlashCommandBootstrapService(context: ctx).installCommand(
                from: URL(fileURLWithPath: bundled),
                named: "scarf-help",
                transport: LocalTransport()
            )

            try Self.chmod(path, 0o644)
            #expect(Self.text(path) == handEdited)
        }
    }

    /// The gate IS the guard here: `!fileExists` is one round trip, and a
    /// dropped one used to publish the placeholder over a real dashboard.
    @Test func existenceProbeNeedsTwoProbesToAgreeBeforeCallingAPathEmpty() throws {
        try Self.withTempDir { dir in
            let transport = LocalTransport()
            let present = dir + "/dashboard.json"
            try Self.write("{\"real\": true}", to: present)
            #expect(
                GuardedJSONStore.probeExistence(present, transport: transport) == .present
            )
            #expect(
                GuardedJSONStore.probeExistence(dir + "/nope.json", transport: transport)
                    == .provenAbsent
            )
        }
    }
}

/// GW-F6 — the E5 audit's remaining data-robustness findings on this same
/// surface: `config.json`'s undecodable-bytes policy (DI M8), the
/// wrong-shaped `manifest.json` (L4), and the zero-byte bootstrap files that
/// could never be repaired (L2).
@Suite("Projects F6 robustness")
struct ProjectsF6RobustnessTests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    private static func withTempDir(_ body: (String) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-f6-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body(dir.path)
    }

    private static func write(_ text: String, to path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    private static func json(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func sentinelManifest() -> ProjectTemplateManifest {
        ProjectTemplateManifest(
            schemaVersion: 3,
            id: "scarf/sentinel",
            name: "M",
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
                dashboard: false, agentsMd: false, instructions: nil, skills: nil,
                cron: nil, memory: nil, config: nil, slashCommands: nil
            ),
            config: nil
        )
    }

    // MARK: - DI M8: config.json refuses, it does not rebuild

    /// The hole: `inspectDecoding` classified undecodable bytes as
    /// `.quarantined` (writable), `existingRoot` came back nil, and `save`
    /// rebuilt from `root = [:]` — every `keychain://` reference in the file
    /// gone, and the Keychain items they pointed at orphaned. Declaring
    /// `.refuseForever` on the store is what makes the existing
    /// `if case .unreadable` branch cover this too.
    @Test func configSaveRefusesUndecodableBytesInsteadOfRebuildingFromEmpty() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "P", path: dir)
            let path = dir + "/.scarf/config.json"
            // Held bytes that are not JSON — the quarantine shape, not the
            // unreadable one.
            let original = "{ this was a config until an editor mangled it"
            try Self.write(original, to: path)

            #expect(throws: GuardedStoreError.self) {
                try ProjectConfigService(context: .local).save(
                    project: project, templateId: "t", values: ["a": .string("b")]
                )
            }
            #expect(
                Self.text(path) == original,
                "a rebuild here drops every keychain:// ref with no pointer left to the secrets"
            )
            // The bytes are still copied aside for the human — refusing is
            // not the same as discarding.
            let siblings = try FileManager.default.contentsOfDirectory(atPath: dir + "/.scarf")
            #expect(siblings.contains { $0.hasPrefix("config.json.corrupt-") })
            #expect(!siblings.contains("config.json.bak"), "a quarantine never eats the .bak")
        }
    }

    @Test func configPolicyIsDeclaredRefuseForever() {
        #expect(ProjectConfigService.damagePolicy == .refuseForever)
        #expect(ProjectConfigService.label == "config.json")
        #expect(ProjectConfigService.maxBytes == ProjectConfigService.configMaxBytes)
    }

    // MARK: - DI L4: a JSON object that is not a manifest

    @Test func wrongShapedManifestIsRepairedNotSilentlyExtended() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "M", path: dir)
            try Self.write(
                #"{"hello": "world", "notAManifest": true}"#,
                to: dir + "/.scarf/manifest.json"
            )

            try ProjectManifestStore(context: .local).setField(
                "kanbanTenant", to: .string("m-1"), for: project,
                sentinel: { Self.sentinelManifest() }
            )

            let root = try #require(Self.json(dir + "/.scarf/manifest.json"))
            #expect(root["kanbanTenant"] as? String == "m-1")
            #expect(root["hello"] as? String == "world", "foreign keys survive the repair")
            #expect(root["id"] as? String == "scarf/sentinel", "and the document is a decodable manifest again")
            // The repaired file must actually decode — the whole point of
            // repairing rather than extending.
            let reread = try ProjectManifestStore(context: .local).readProven(for: project)
            #expect(reread != nil)
        }
    }

    @Test func wellShapedManifestIsLeftAloneApartFromTheField() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "M", path: dir)
            try Self.write(
                #"""
                {"schemaVersion":3,"id":"alice/real","name":"Real","version":"2.0.0",
                 "description":"d",
                 "contents":{"dashboard":false,"agentsMd":false},
                 "extraKey":42}
                """#,
                to: dir + "/.scarf/manifest.json"
            )

            try ProjectManifestStore(context: .local).setField(
                "kanbanTenant", to: .string("m-2"), for: project,
                sentinel: { Self.sentinelManifest() }
            )

            let root = try #require(Self.json(dir + "/.scarf/manifest.json"))
            #expect(root["id"] as? String == "alice/real", "a real manifest is NOT overlaid")
            #expect(root["version"] as? String == "2.0.0")
            #expect(root["extraKey"] as? Int == 42)
            #expect(root["kanbanTenant"] as? String == "m-2")
        }
    }
}
