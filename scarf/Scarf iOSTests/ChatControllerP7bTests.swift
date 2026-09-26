import Testing
import Foundation
import ScarfCore
@testable import scarf_mobile

/// P7b (t-409ec2da) — ScarfGo `ChatController` lifecycle fixes, driven over
/// an in-memory ACP channel through the real start/send/reconnect paths
/// (same fake-remote setup as `ChatControllerPromptCompleteTests`):
///  - a reconnect ladder whose `start()`/`loadSession` outlives "New chat"
///    must not install the dead session over the new one;
///  - an old turn's `CancellationError` (its client torn down by "New
///    chat") must not land a failure on the fresh chat.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ChatControllerP7bTests {

    /// Answers the handshake; `session/new` / `session/load` resolve to
    /// `sessionId`; `session/prompt` is held until the channel closes.
    actor HoldingChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let sessionId: String
        private(set) var closed = false
        private(set) var sentMethods: [String] = []

        var diagnosticID: String? { "p7b-ios-channel" }

        init(sessionId: String) {
            self.sessionId = sessionId
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = inStream
            incomingCont = inCont
            stderr = errStream
            stderrCont = errCont
        }

        func send(_ line: String) async throws {
            guard !closed,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            sentMethods.append(method)
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/new", "session/load":
                yieldJSON(["jsonrpc": "2.0", "id": id,
                           "result": ["sessionId": sessionId, "modes": ["currentModeId": "default"]]])
            case "session/prompt":
                break // held — the turn stays in flight
            default:
                yieldJSON(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        func close() async {
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }

        private func yieldJSON(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }
    }

    final class Counter: @unchecked Sendable {
        private var n = 0
        private let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A fake remote whose config.yaml passes the model preflight, served
    /// by LocalTransport (see `ChatControllerPromptCompleteTests`).
    private static func withFakeRemote(_ body: (ServerContext) async throws -> Void) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-p7b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "model:\n  default: test-model\n  provider: test-provider\n"
            .write(to: tmp.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let config = SSHConfig(host: "fake.invalid", remoteHome: tmp.path,
                               hermesBinaryHint: "/nonexistent/scarf-test-hermes")
        let ctx = ServerContext(id: UUID(), displayName: "fake", kind: .ssh(config))
        let priorFactory = ServerContext.sshTransportFactory
        ServerContext.sshTransportFactory = { id, _, _ in LocalTransport(contextID: id) }
        defer { ServerContext.sshTransportFactory = priorFactory }
        try await body(ctx)
    }

    private static func waitUntil(
        timeoutSeconds: Double = 5,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private static func isReady(_ controller: ChatController) -> Bool {
        if case .ready = controller.state { return true }
        return false
    }

    // MARK: - (1) Reconnect currency

    @Test func staleReconnectDoesNotReplaceANewChat() async throws {
        try await Self.withFakeRemote { ctx in
            let chA = HoldingChannel(sessionId: "sess-A")
            let chReconnect = HoldingChannel(sessionId: "sess-A")
            let chB = HoldingChannel(sessionId: "sess-B")
            let (gate, gateCont) = AsyncStream<Void>.makeStream()
            let calls = Counter()
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in
                switch calls.next() {
                case 1: return ACPClient(context: ctx) { _ in chA }
                case 2: return ACPClient(context: ctx) { _ in
                    for await _ in gate { break } // wedged spawn
                    return chReconnect
                }
                default: return ACPClient(context: ctx) { _ in chB }
                }
            }

            await controller.start()
            #expect(Self.isReady(controller))
            #expect(controller.vm.sessionId == "sess-A")

            await chA.close() // transport dies → reconnect ladder
            let spawning = await Self.waitUntil { calls.count >= 2 }
            #expect(spawning, "reconnect never reached its spawn")

            await controller.resetAndStartNewSession()
            #expect(Self.isReady(controller))
            #expect(controller.vm.sessionId == "sess-B")

            gateCont.yield(())
            gateCont.finish()
            let loaded = await Self.waitUntil { await chReconnect.sentMethods.contains("session/load") }
            #expect(loaded, "the wedged attempt never resumed")
            let stopped = await Self.waitUntil { await chReconnect.closed }
            #expect(stopped, "the stale reconnect's client was installed instead of stopped")
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(controller.vm.sessionId == "sess-B", "stale reconnect re-attached the dead session")
            #expect(Self.isReady(controller))
            #expect(await chB.closed == false)
        }
    }

    // MARK: - (5) Stale turn after New chat

    @Test func oldTurnsCancellationDoesNotFailTheNewChat() async throws {
        try await Self.withFakeRemote { ctx in
            let chA = HoldingChannel(sessionId: "sess-A")
            let chB = HoldingChannel(sessionId: "sess-B")
            let calls = Counter()
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in
                let first = calls.next() == 1
                return ACPClient(context: ctx) { _ in first ? chA : chB }
            }

            await controller.start()
            #expect(Self.isReady(controller))
            controller.draft = "long job"
            let sendTask = Task { await controller.send() }
            let inFlight = await Self.waitUntil { await chA.sentMethods.contains("session/prompt") }
            #expect(inFlight)

            // "New chat": stop() tears down A, resuming its held prompt
            // with CancellationError while B boots.
            await controller.resetAndStartNewSession()
            await sendTask.value
            try? await Task.sleep(nanoseconds: 200_000_000)

            #expect(controller.vm.sessionId == "sess-B")
            #expect(Self.isReady(controller), "the old turn's failure flipped the new chat to \(controller.state)")
            #expect(!controller.vm.messages.contains { $0.role == "system" },
                    "the old turn's failure bubble landed on the new chat")
            #expect(controller.vm.acpError == nil, "the old turn's error banner landed on the new chat")
        }
    }
}
