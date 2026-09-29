import Testing
import Foundation
@testable import ScarfCore

/// #142 P3: the chat-start gate between the managed AGENTS.md block and
/// `HERMES_ENVIRONMENT_HINT`, the migration strip, and the config-hint read.
/// Real temp directories through `LocalTransport`.
@Suite struct ProjectEnvironmentHintTests {

    private static let block = "\(ProjectContextBlock.beginMarker)\nSCARF-BLOCK\n\(ProjectContextBlock.endMarker)"

    private static func withHome(_ body: (_ base: URL, _ project: URL, _ ctx: ServerContext) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-envhint-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("hermes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base, project, .local(home: base.appendingPathComponent("hermes")))
    }

    private static func write(_ text: String, _ url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Gate

    @Test func gateFollowsTheV016Floor() {
        #expect(ProjectEnvironmentHint.delivery(for: .empty) == .managedBlock)
        #expect(ProjectEnvironmentHint.delivery(
            for: .parseLine("Hermes Agent v0.15.2 (2026.5.29)")) == .managedBlock)
        #expect(ProjectEnvironmentHint.delivery(
            for: .parseLine("Hermes Agent v0.16.0 (2026.6.5)")) == .environmentHint)
        #expect(ProjectEnvironmentHint.delivery(
            for: .parseLine("Hermes Agent v0.21.5 (2026.9.24)")) == .environmentHint)
    }

    // MARK: - Config hint

    @Test func configHintReadsPlainQuotedAndBlockScalars() {
        #expect(ProjectEnvironmentHint.configHint(fromConfigYAML: """
        model:
          default: x
        agent:
          max_turns: 60
          environment_hint: Runs in a devcontainer
        """) == "Runs in a devcontainer")
        #expect(ProjectEnvironmentHint.configHint(fromConfigYAML: """
        agent:
          environment_hint: "GPU box: use --device cuda"
        """) == "GPU box: use --device cuda")
        let block = ProjectEnvironmentHint.configHint(fromConfigYAML: """
        agent:
          environment_hint: |
            Line one.
            Line two.
          max_turns: 60
        """)
        #expect(block?.contains("Line one.") == true)
        #expect(block?.contains("Line two.") == true)
        #expect(block?.contains("max_turns") == false)
    }

    @Test func configHintIsNilWhenAbsentBlankOrElsewhere() {
        #expect(ProjectEnvironmentHint.configHint(fromConfigYAML: "agent:\n  max_turns: 60\n") == nil)
        #expect(ProjectEnvironmentHint.configHint(fromConfigYAML: "agent:\n  environment_hint: \"  \"\n") == nil)
        // Same key name under another section is not the agent's.
        #expect(ProjectEnvironmentHint.configHint(fromConfigYAML: "other:\n  environment_hint: nope\n") == nil)
        #expect(ProjectEnvironmentHint.configHint(fromConfigYAML: "") == nil)
    }

    @Test func readConfigHintReadsTheContextsConfigYAML() throws {
        try Self.withHome { base, _, ctx in
            #expect(ProjectEnvironmentHint.readConfigHint(context: ctx) == nil, "missing file → nil")
            try Self.write("agent:\n  environment_hint: from-config\n",
                           base.appendingPathComponent("hermes/config.yaml"))
            #expect(ProjectEnvironmentHint.readConfigHint(context: ctx) == "from-config")
        }
    }

    // MARK: - Migration strip

    @Test func stripKeepsUserTextAndRemovesOnlyTheBlock() throws {
        try Self.withHome { _, project, ctx in
            let agents = project.appendingPathComponent("AGENTS.md")
            try Self.write("# My rules\n\nUse tabs.\n\n\(Self.block)\n\n## More\nkeep me\n", agents)
            #expect(try ProjectContextBlock.stripForEnvironmentHint(forProjectAt: project.path, context: ctx))
            let after = try #require(Self.read(agents))
            #expect(!after.contains("SCARF-BLOCK"))
            #expect(!after.contains(ProjectContextBlock.beginMarker))
            #expect(after.contains("# My rules\n\nUse tabs."))
            #expect(after.contains("## More\nkeep me"))
            // Idempotent: nothing left to do.
            #expect(try ProjectContextBlock.stripForEnvironmentHint(forProjectAt: project.path, context: ctx) == false)
            #expect(Self.read(agents) == after)
        }
    }

    @Test func stripDeletesABlockOnlyAgentsMdAndCleansOtherContextFiles() throws {
        try Self.withHome { _, project, ctx in
            let agents = project.appendingPathComponent("AGENTS.md")
            let claude = project.appendingPathComponent("CLAUDE.md")
            try Self.write(Self.block + "\n", agents)
            try Self.write("Build with make.\n\n\(Self.block)\n", claude)
            #expect(try ProjectContextBlock.stripForEnvironmentHint(forProjectAt: project.path, context: ctx))
            #expect(!FileManager.default.fileExists(atPath: agents.path), "Scarf's own stub goes")
            #expect(Self.read(claude) == "Build with make.\n")
        }
    }

    @Test func stripIsANoOpWithoutABlock() throws {
        try Self.withHome { _, project, ctx in
            let agents = project.appendingPathComponent("AGENTS.md")
            try Self.write("# Only mine\n", agents)
            #expect(try ProjectContextBlock.stripForEnvironmentHint(forProjectAt: project.path, context: ctx) == false)
            #expect(Self.read(agents) == "# Only mine\n")
            #expect(!FileManager.default.fileExists(atPath: agents.path + ".bak"))
        }
    }

    // MARK: - prepare

    @Test func prepareRendersTheHintReadsConfigAndStrips() throws {
        try Self.withHome { base, project, ctx in
            try Self.write("agent:\n  environment_hint: user-hint\n",
                           base.appendingPathComponent("hermes/config.yaml"))
            let agents = project.appendingPathComponent("AGENTS.md")
            try Self.write("mine\n\n\(Self.block)\n", agents)
            let id = UUID()
            let scarfProject = ScarfProject(id: id, name: "Demo", rootPath: project.path)

            let prepared = ProjectEnvironmentHint.prepare(project: scarfProject, context: ctx)

            #expect(prepared.stripError == nil)
            #expect(prepared.request.configHint == "user-hint")
            #expect(prepared.request.scarfHint.contains("\"Demo\""))
            #expect(prepared.request.scarfHint.contains(project.path))
            #expect(prepared.request.scarfHint.contains("[proj:\(id.uuidString)]"))
            #expect(!prepared.request.scarfHint.contains(ProjectContextBlock.beginMarker))
            #expect(Self.read(agents) == "mine\n")
        }
    }

    // MARK: - Slot

    @Test func slotAnswersOnlyForTheProjectItWasFilledFor() {
        let slot = EnvironmentHintSlot()
        let req = EnvironmentHintRequest(scarfHint: "h", configHint: nil)
        #expect(slot.request(forProjectCwd: "/p/a") == nil)
        slot.set(req, forProjectPath: "/p/a")
        #expect(slot.request(forProjectCwd: "/p/a") == req)
        #expect(slot.request(forProjectCwd: "/p/b") == nil)
        #expect(slot.request(forProjectCwd: nil) == nil)
        slot.set(nil, forProjectPath: "/p/a")
        #expect(slot.request(forProjectCwd: "/p/a") == nil)
    }
}
