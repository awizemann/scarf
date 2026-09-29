import Testing
import Foundation
import SwiftUI
import ScarfCore
@testable import scarf_mobile

/// #142 P3 on ScarfGo: a project chat on a v0.16+ host spawns `hermes acp`
/// with the environment hint and strips the managed block; an older host
/// keeps writing the block with no hint (C1). A failed strip is logged, not
/// bannered — the agent still gets its context.
///
/// Fake remote served by LocalTransport (same setup as
/// `ChatControllerP7bTests`). The scripted spawn reads the controller's
/// `environmentHintSlot` inside the channel factory, i.e. at `start()`, the
/// moment the production `makeClient` path would have read it.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ChatControllerEnvironmentHintTests {
    typealias Channel = ChatControllerP7bTests.HoldingChannel

    final class SpawnRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var _hints: [EnvironmentHintRequest?] = []
        var hints: [EnvironmentHintRequest?] { lock.withLock { _hints } }
        func record(_ hint: EnvironmentHintRequest?) { lock.withLock { _hints.append(hint) } }
    }

    static let block = "\(ProjectContextBlock.beginMarker)\nOLD-SCARF-BLOCK\n\(ProjectContextBlock.endMarker)"

    private static func withFakeRemote(_ body: (ServerContext, _ projectPath: String) async throws -> Void) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-envhint-ios-\(UUID().uuidString)", isDirectory: true)
        let project = tmp.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "model:\n  default: test-model\n  provider: test-provider\nagent:\n  environment_hint: remote-user-hint\n"
            .write(to: tmp.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try "# Mine\n\nkeep me\n\n\(block)\n"
            .write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let config = SSHConfig(host: "fake.invalid", remoteHome: tmp.path,
                               hermesBinaryHint: "/nonexistent/scarf-test-hermes")
        let ctx = ServerContext(id: UUID(), displayName: "fake", kind: .ssh(config))
        let priorFactory = ServerContext.sshTransportFactory
        ServerContext.sshTransportFactory = { id, _, _ in LocalTransport(contextID: id) }
        defer { ServerContext.sshTransportFactory = priorFactory }
        try await body(ctx, project.path)
    }

    private static func boot(
        _ ctx: ServerContext, projectPath: String, version: String
    ) async -> (ChatController, SpawnRecord) {
        let controller = ChatController(context: ctx)
        let caps = HermesCapabilities.parseLine("Hermes Agent v\(version)")
        controller.capabilitiesProvider = { _ in caps }
        let spawns = SpawnRecord()
        let slot = controller.environmentHintSlot
        let channel = Channel(sessionId: "sess-HINT")
        controller.clientFactory = { cwd in
            ACPClient(context: ctx) { _ in
                spawns.record(slot.request(forProjectCwd: cwd))
                return channel
            }
        }
        await controller.resetAndStartInProject(ProjectEntry(name: "Demo", path: projectPath))
        return (controller, spawns)
    }

    private static func agents(_ projectPath: String) -> String? {
        try? String(contentsOfFile: projectPath + "/AGENTS.md", encoding: .utf8)
    }

    @Test func v016HostSpawnsWithTheHintAndStripsTheBlock() async throws {
        try await Self.withFakeRemote { ctx, projectPath in
            let (controller, spawns) = await Self.boot(ctx, projectPath: projectPath, version: "0.16.0")

            let hint = try #require(spawns.hints.first ?? nil, "spawn carried no hint")
            #expect(hint.configHint == "remote-user-hint", "config hint comes from the target host's config.yaml")
            #expect(hint.scarfHint.contains("\"Demo\""))
            #expect(hint.scarfHint.contains(projectPath))
            #expect(Self.agents(projectPath) == "# Mine\n\nkeep me\n")
            #expect(controller.vm.acpError == nil)
        }
    }

    @Test func v015HostKeepsTheManagedBlockAndNoHint() async throws {
        try await Self.withFakeRemote { ctx, projectPath in
            let (controller, spawns) = await Self.boot(ctx, projectPath: projectPath, version: "0.15.2")

            #expect(spawns.hints.count == 1)
            #expect(spawns.hints.first! == nil)
            let agents = try #require(Self.agents(projectPath))
            #expect(agents.contains("## Scarf project context"))
            #expect(agents.hasPrefix("# Mine\n\nkeep me"))
            #expect(controller.vm.acpError == nil)
        }
    }

    /// An unreadable context file makes the strip fail. The hint is still
    /// delivered and no "Project context not written" banner appears —
    /// that banner is about the block, which this host doesn't need.
    @Test func failedStripOnAHintHostIsNotBannered() async throws {
        try await Self.withFakeRemote { ctx, projectPath in
            let path = projectPath + "/AGENTS.md"
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

            let (controller, spawns) = await Self.boot(ctx, projectPath: projectPath, version: "0.16.0")

            #expect((spawns.hints.first ?? nil) != nil)
            #expect(controller.vm.acpError == nil)
            // The strip really did fail (this is the path under test).
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            #expect(Self.agents(projectPath)?.contains("OLD-SCARF-BLOCK") == true)
        }
    }
}
