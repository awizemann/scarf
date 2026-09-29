import Testing
import Foundation
import ScarfCore
@testable import scarf

/// #142 P3 on the Mac: a project chat on a host that reads
/// `HERMES_ENVIRONMENT_HINT` (v0.16+, confirmed by a probe) spawns
/// `hermes acp` with the hint and strips the managed block from the project;
/// an older or undetected host keeps writing the block and spawns with no
/// hint (C1).
///
/// The spawn is scripted through `acpClientFactory`, but the factory reads
/// `environmentHintSlot` INSIDE the channel factory — i.e. at `start()`,
/// exactly when the production factory reads it — so the assertion also
/// proves the prep lands before the spawn.
@Suite struct ChatViewModelEnvironmentHintTests {
    typealias AAE = ChatViewModelAutoAcceptEditsTests

    /// What the scripted spawn saw.
    final class SpawnRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var _hints: [EnvironmentHintRequest?] = []
        var hints: [EnvironmentHintRequest?] { lock.withLock { _hints } }
        func record(_ hint: EnvironmentHintRequest?) { lock.withLock { _hints.append(hint) } }
    }

    static let block = "\(ProjectContextBlock.beginMarker)\nOLD-SCARF-BLOCK\n\(ProjectContextBlock.endMarker)"

    @MainActor
    static func boot(
        home: TempHermesHome, store: HermesCapabilitiesStore?
    ) async throws -> (vm: ChatViewModel, spawns: SpawnRecord, agentsPath: String, projectPath: String) {
        let projectPath = home.path + "/projects/demo"
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
        let agentsPath = projectPath + "/AGENTS.md"
        try "# Mine\n\nkeep me\n\n\(block)\n".write(toFile: agentsPath, atomically: true, encoding: .utf8)
        try ProjectDashboardService(context: home.context)
            .saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "Demo", path: projectPath)]))

        let vm = ChatViewModel(context: home.context)
        vm.capabilitiesStore = store
        let spawns = SpawnRecord()
        let slot = vm.environmentHintSlot
        let channel = AAE.ModeRecordingChannel(sessionId: "sess-HINT")
        vm.acpClientFactory = { ctx, cwd in
            ACPClient(context: ctx) { _ in
                spawns.record(slot.request(forProjectCwd: cwd))
                return channel
            }
        }
        vm.startNewSession(projectPath: projectPath)
        let booted = await AAE.waitUntil { vm.richChatViewModel.sessionId == "sess-HINT" }
        #expect(booted, "session never booted")
        return (vm, spawns, agentsPath, projectPath)
    }

    static func home(configHint: String?) throws -> TempHermesHome {
        let home = try TempHermesHome()
        var yaml = "model:\n  default: test-model\n  provider: anthropic\n"
        if let configHint { yaml += "agent:\n  environment_hint: \(configHint)\n" }
        try yaml.write(toFile: home.path + "/config.yaml", atomically: true, encoding: .utf8)
        return home
    }

    @Test @MainActor func v016HostSpawnsWithTheHintAndStripsTheBlock() async throws {
        let home = try Self.home(configHint: "user-hint")
        defer { home.cleanup() }
        let suite = "com.scarf.tests.envhint.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = await AAE.capabilities("0.16.0", context: home.context, suite: suite)

        let (_, spawns, agentsPath, projectPath) = try await Self.boot(home: home, store: store)

        let hint = try #require(spawns.hints.first ?? nil, "spawn carried no hint")
        #expect(spawns.hints.count == 1)
        #expect(hint.configHint == "user-hint", "the user's config hint must reach the composer")
        #expect(hint.scarfHint.contains("\"Demo\""))
        #expect(hint.scarfHint.contains(projectPath))
        #expect(!hint.scarfHint.contains(ProjectContextBlock.beginMarker))
        let agents = try String(contentsOfFile: agentsPath, encoding: .utf8)
        #expect(!agents.contains("OLD-SCARF-BLOCK"))
        #expect(!agents.contains(ProjectContextBlock.beginMarker), "no fresh block written either")
        #expect(agents == "# Mine\n\nkeep me\n")
    }

    /// C1: a v0.15 host renders the block exactly as before and the spawn
    /// has no hint.
    @Test @MainActor func v015HostKeepsTheManagedBlockAndNoHint() async throws {
        let home = try Self.home(configHint: "user-hint")
        defer { home.cleanup() }
        let suite = "com.scarf.tests.envhint.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = await AAE.capabilities("0.15.2", context: home.context, suite: suite)

        let (_, spawns, agentsPath, _) = try await Self.boot(home: home, store: store)

        #expect(spawns.hints.count == 1)
        #expect(spawns.hints.first! == nil)
        let agents = try String(contentsOfFile: agentsPath, encoding: .utf8)
        #expect(agents.contains(ProjectContextBlock.beginMarker))
        #expect(agents.contains("## Scarf project context"), "the block was refreshed")
        #expect(!agents.contains("OLD-SCARF-BLOCK"))
        #expect(agents.hasPrefix("# Mine\n\nkeep me"))
    }

    /// An unknown version (no store / failed probe) is the old path too.
    @Test @MainActor func undetectedHostKeepsTheManagedBlock() async throws {
        let home = try Self.home(configHint: nil)
        defer { home.cleanup() }

        let (_, spawns, agentsPath, _) = try await Self.boot(home: home, store: nil)

        #expect(spawns.hints.first! == nil)
        let agents = try String(contentsOfFile: agentsPath, encoding: .utf8)
        #expect(agents.contains("## Scarf project context"))
    }
}
