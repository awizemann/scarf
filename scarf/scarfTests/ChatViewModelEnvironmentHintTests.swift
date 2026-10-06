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
        try #require(booted, "session never booted")
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
        let hint = try #require(spawns.hints.first, "no spawn recorded")
        #expect(hint == nil)
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

        let hint = try #require(spawns.hints.first, "no spawn recorded")
        #expect(hint == nil)
        let agents = try String(contentsOfFile: agentsPath, encoding: .utf8)
        #expect(agents.contains("## Scarf project context"))
    }

    // MARK: - #142 P6: the slot across supersede and reconnect

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Gated = ChatSessionsR16bMacTests.GatedReplayChannel

    /// What each spawn saw: the project cwd it was built for and the hint
    /// the slot answered for it at `start()`.
    final class CwdSpawnRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var _spawns: [(cwd: String?, hint: EnvironmentHintRequest?)] = []
        var spawns: [(cwd: String?, hint: EnvironmentHintRequest?)] { lock.withLock { _spawns } }
        func record(_ cwd: String?, _ hint: EnvironmentHintRequest?) { lock.withLock { _spawns.append((cwd, hint)) } }
    }

    /// Two projects registered on a v0.16 host, each with an old block.
    static func twoProjectHome() throws -> (home: TempHermesHome, a: String, b: String) {
        let home = try Self.home(configHint: "user-hint")
        var entries: [ProjectEntry] = []
        var paths: [String] = []
        for name in ["Alpha", "Beta"] {
            let path = home.path + "/projects/" + name.lowercased()
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try "\(block)\n".write(toFile: path + "/AGENTS.md", atomically: true, encoding: .utf8)
            entries.append(ProjectEntry(name: name, path: path))
            paths.append(path)
        }
        try ProjectDashboardService(context: home.context).saveRegistry(ProjectRegistry(projects: entries))
        return (home, paths[0], paths[1])
    }

    /// A start superseded by a newer one must never write the slot: the
    /// newer start's spawn carries ITS project's hint, and the older
    /// project's never spawns at all. Run with no gap and with a few
    /// yields, so the older prep is caught at either of its two
    /// `startStillCurrent` guards.
    @Test(arguments: [0, 3, 20]) @MainActor
    func aSupersededStartNeverOverwritesTheSlot(yields: Int) async throws {
        let (home, a, b) = try Self.twoProjectHome()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.envhint.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = await AAE.capabilities("0.16.0", context: home.context, suite: suite)

        let vm = ChatViewModel(context: home.context)
        vm.capabilitiesStore = store
        let record = CwdSpawnRecord()
        let slot = vm.environmentHintSlot
        vm.acpClientFactory = { ctx, cwd in
            ACPClient(context: ctx) { _ in
                record.record(cwd, slot.request(forProjectCwd: cwd))
                return AAE.ModeRecordingChannel(sessionId: cwd == b ? "sess-B" : "sess-A")
            }
        }
        vm.startNewSession(projectPath: a)
        for _ in 0..<yields { await Task.yield() }
        vm.startNewSession(projectPath: b)
        #expect(await AAE.waitUntil { vm.richChatViewModel.sessionId == "sess-B" }, "B never booted")
        // Let any straggling A prep run to completion before judging.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let bSpawn = try #require(record.spawns.last)
        #expect(bSpawn.cwd == b)
        let hint = try #require(bSpawn.hint, "B's spawn lost its hint")
        #expect(hint.scarfHint.contains("\"Beta\""))
        #expect(!hint.scarfHint.contains("\"Alpha\""))
        #expect(slot.request(forProjectCwd: b) == hint, "the slot no longer holds B's hint")
        #expect(slot.request(forProjectCwd: a) == nil, "a superseded start wrote the slot")
        vm.stopACP()
    }

    /// The reconnect ladder respawns under the same project and reuses the
    /// hint already in the slot — it does not re-run the prep. Proven by
    /// changing the user's config hint after boot: the respawn still carries
    /// the value read at chat start.
    @Test @MainActor func reconnectReusesTheSlotsHint() async throws {
        let home = try Self.home(configHint: "user-hint")
        defer { home.cleanup() }
        let suite = "com.scarf.tests.envhint.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = await AAE.capabilities("0.16.0", context: home.context, suite: suite)
        let projectPath = home.path + "/projects/demo"
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
        try ProjectDashboardService(context: home.context)
            .saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "Demo", path: projectPath)]))

        let vm = ChatViewModel(context: home.context)
        vm.capabilitiesStore = store
        let record = CwdSpawnRecord()
        let slot = vm.environmentHintSlot
        let first = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let calls = Lifecycle.CallCounter()
        let reconnect = Gated()
        vm.acpClientFactory = { ctx, cwd in
            let n = calls.next()
            return ACPClient(context: ctx) { _ in
                record.record(cwd, slot.request(forProjectCwd: cwd))
                return n == 1 ? first : reconnect
            }
        }
        vm.startNewSession(projectPath: projectPath)
        #expect(await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.richChatViewModel.sessionId == "sess-A"
        })
        let bootHint = try #require(record.spawns.first?.hint, "the first spawn carried no hint")
        #expect(bootHint.configHint == "user-hint")

        try "agent:\n  environment_hint: changed-after-boot\n"
            .write(toFile: home.path + "/config.yaml", atomically: true, encoding: .utf8)
        await first.close()
        let respawned = await Lifecycle.waitUntil(timeoutSeconds: 10) { record.spawns.count >= 2 }
        try #require(respawned, "the reconnect ladder never respawned")

        let respawn = try #require(record.spawns.dropFirst().first)
        #expect(respawn.cwd == projectPath, "the ladder left the project scope")
        #expect(respawn.hint == bootHint, "the respawn did not reuse the slot's hint")
        vm.stopACP()
    }
}
