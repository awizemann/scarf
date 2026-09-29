import Testing
import Foundation
import ScarfCore
@testable import scarf

/// #142 P6: a mini-app's agent session gets the project environment hint on
/// exactly the hosts a project chat does — a CONFIRMED v0.16+ — and on every
/// other host spawns as before, with no hint and no block written.
///
/// The spawn is the injected client factory, which receives the hint the
/// production `MiniAppAgentSession.projectHint` produced. The fake channel
/// fails `session/new`, so the prompt errors out right after the spawn.
@Suite(.serialized) struct MiniAppAgentSessionEnvironmentHintTests {
    typealias Fake = MiniAppAgentSessionTests.FakeACPChannel

    final class SpawnRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var _hints: [EnvironmentHintRequest?] = []
        var hints: [EnvironmentHintRequest?] { lock.withLock { _hints } }
        func record(_ hint: EnvironmentHintRequest?) { lock.withLock { _hints.append(hint) } }
    }

    static let block = "\(ProjectContextBlock.beginMarker)\nOLD-SCARF-BLOCK\n\(ProjectContextBlock.endMarker)"

    /// Spawn once with `capabilities`; return what the spawn got and the
    /// project's AGENTS.md afterwards.
    static func spawn(
        capabilities: HermesCapabilities
    ) async throws -> (hints: [EnvironmentHintRequest?], agents: String?, projectPath: String) {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try "agent:\n  environment_hint: user-hint\n"
            .write(toFile: home.path + "/config.yaml", atomically: true, encoding: .utf8)
        let projectPath = home.path + "/projects/demo"
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
        let agentsPath = projectPath + "/AGENTS.md"
        try "# Mine\n\n\(block)\n".write(toFile: agentsPath, atomically: true, encoding: .utf8)
        let project = ProjectStore(context: home.context)
            .derive(from: ProjectEntry(name: "Demo", path: projectPath))

        let spawns = SpawnRecord()
        let fake = Fake(failSessionNew: true)
        let session = MiniAppAgentSession(
            context: home.context,
            projectRoot: projectPath,
            environmentHint: MiniAppAgentSession.projectHint(
                project: project, projectPath: projectPath, context: home.context,
                capabilities: { capabilities })
        ) { ctx, hint in
            spawns.record(hint)
            return ACPClient(context: ctx) { _ in fake }
        }
        _ = try? await session.prompt("hi")
        await session.shutdown()
        return (spawns.hints, try? String(contentsOfFile: agentsPath, encoding: .utf8), projectPath)
    }

    @Test func v016HostGetsTheProjectHintAndTheBlockIsStripped() async throws {
        let (hints, agents, projectPath) = try await Self.spawn(
            capabilities: .parseLine("Hermes Agent v0.16.0 (2026.6.5)"))
        #expect(hints.count == 1)
        let hint = try #require(hints.first ?? nil, "the mini-app spawn carried no hint")
        #expect(hint.scarfHint.contains("\"Demo\""))
        #expect(hint.scarfHint.contains(projectPath))
        #expect(hint.configHint == "user-hint", "the user's config hint must reach the composer")
        #expect(agents == "# Mine\n", "same strip as a project chat")
    }

    /// C1: an older host is today's mini-app — no hint, and the folder is
    /// untouched (the mini-app never wrote the block and still doesn't).
    @Test func v015HostSpawnsWithoutAHintAndWritesNothing() async throws {
        let (hints, agents, _) = try await Self.spawn(
            capabilities: .parseLine("Hermes Agent v0.15.2 (2026.5.29)"))
        #expect(hints == [nil])
        #expect(agents == "# Mine\n\n\(Self.block)\n")
    }

    /// No confirmed version (no store, failed probe, provisional) = old path.
    @Test func unknownHostSpawnsWithoutAHint() async throws {
        let (hints, agents, _) = try await Self.spawn(capabilities: .empty)
        #expect(hints == [nil])
        #expect(agents == "# Mine\n\n\(Self.block)\n")
    }

    /// The default (no provider) is no hint — what tests and any other
    /// caller get without opting in.
    @Test func defaultProviderIsNoHint() async throws {
        let spawns = SpawnRecord()
        let fake = Fake(failSessionNew: true)
        let session = MiniAppAgentSession(context: .local, projectRoot: "/tmp/miniapp-hint") { ctx, hint in
            spawns.record(hint)
            return ACPClient(context: ctx) { _ in fake }
        }
        _ = try? await session.prompt("hi")
        await session.shutdown()
        #expect(spawns.hints == [nil])
    }

    /// `shutdown()` landing while the hint prep is in flight (an SSH round
    /// trip on a remote) must not let the cold start go on to spawn a
    /// `hermes acp` nobody will ever stop.
    @Test func shutdownDuringHintPrepSpawnsNothing() async throws {
        let spawns = SpawnRecord()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let session = MiniAppAgentSession(
            context: .local, projectRoot: "/tmp/miniapp-hint",
            environmentHint: {
                entered.continuation.yield()
                for await _ in release.stream { break }
                return nil
            }
        ) { ctx, hint in
            spawns.record(hint)
            return ACPClient(context: ctx) { _ in Fake() }
        }
        let prompt = Task { try await session.prompt("hi") }
        for await _ in entered.stream { break }
        await session.shutdown()
        release.continuation.yield()
        let result = await prompt.result
        #expect(throws: MiniAppAgentSession.AgentError.self) { try result.get() }
        #expect(spawns.hints.isEmpty, "a shut-down session still spawned hermes acp")
    }
}
