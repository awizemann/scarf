import Testing
import Foundation
import ScarfCore
@testable import scarf_mobile

/// #146 / t-238d2ab3 on ScarfGo: `startResuming` no longer catches every
/// `session/load` error into a silent new session. Driven through the real
/// `ChatController` over an in-memory ACP channel and a fake remote served
/// by `LocalTransport` (same setup as `ChatControllerP7bTests`).
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ChatControllerResume146Tests {

    enum LoadAnswer: Sendable {
        case restores
        /// Hermes's not-restorable wire answer: `result: {}`.
        case notRestorable
        /// A real failure — never a fallback.
        case rpcError
    }

    actor Channel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let load: LoadAnswer
        private let newId: String
        private(set) var sentMethods: [String] = []
        private(set) var loadedIds: [String] = []

        var diagnosticID: String? { "146-ios-channel" }

        init(load: LoadAnswer, newId: String = "acp-new") {
            self.load = load
            self.newId = newId
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = inStream
            incomingCont = inCont
            stderr = errStream
            stderrCont = errCont
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            sentMethods.append(method)
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/load":
                let requested = (obj["params"] as? [String: Any])?["sessionId"] as? String ?? ""
                loadedIds.append(requested)
                switch load {
                case .restores:
                    yield(["jsonrpc": "2.0", "id": id,
                           "result": ["sessionId": requested, "modes": ["currentModeId": "default"]]])
                case .notRestorable:
                    yield(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
                case .rpcError:
                    yield(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "Internal error"]])
                }
            case "session/new":
                yield(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": newId, "modes": ["currentModeId": "default"]]])
            case "session/prompt":
                break
            default:
                yield(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        func close() async {
            incomingCont.finish()
            stderrCont.finish()
        }

        private func yield(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }
    }

    final class Counter: @unchecked Sendable {
        private var n = 0
        private let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    /// A fake remote whose config passes the model preflight. (The
    /// non-ACP source gate needs the sqlite3 CLI, which the simulator
    /// lacks — ScarfCore and the Mac suites cover it.)
    static func withFakeRemote(
        _ body: (ServerContext) async throws -> Void
    ) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-146-\(UUID().uuidString)", isDirectory: true)
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

    static func isReady(_ c: ChatController) -> Bool {
        if case .ready = c.state { return true }
        return false
    }

    private static func isFailed(_ c: ChatController) -> Bool {
        if case .failed = c.state { return true }
        return false
    }

    @Test func aRealLoadErrorFailsAndRetryReopensTheSameSession() async throws {
        try await Self.withFakeRemote { ctx in
            let failing = Channel(load: .rpcError)
            let healthy = Channel(load: .restores)
            let calls = Counter()
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in
                let first = calls.next() == 1
                return ACPClient(context: ctx) { _ in first ? failing : healthy }
            }

            await controller.startResuming(sessionID: "acp-old")

            #expect(Self.isFailed(controller), "a JSON-RPC load error must surface, got \(controller.state)")
            let methods = await failing.sentMethods
            #expect(methods.contains("session/load"))
            #expect(!methods.contains("session/new"), "the load error minted a silent new session: \(methods)")
            #expect(controller.vm.resumeContinuityNotice == nil)

            // Retry reopens THAT session — not a blank `start()`.
            await controller.retryAfterFailure()
            #expect(Self.isReady(controller))
            #expect(await healthy.loadedIds == ["acp-old"])
            #expect(!(await healthy.sentMethods).contains("session/new"))
            #expect(controller.vm.sessionId == "acp-old")
        }
    }

    @Test func notRestorableFallsBackWithANotice() async throws {
        try await Self.withFakeRemote { ctx in
            let ch = Channel(load: .notRestorable)
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in ACPClient(context: ctx) { _ in ch } }

            await controller.startResuming(sessionID: "acp-gone")

            #expect(Self.isReady(controller))
            #expect(await ch.sentMethods.contains("session/new"))
            #expect(controller.vm.sessionId == "acp-new")
            let notice = try #require(controller.vm.resumeContinuityNotice)
            #expect(notice.text.contains("couldn’t reopen"))
            // ScarfGo shows no Kanban badge, so no Kanban sentence.
            #expect(!notice.text.contains("Kanban"))
        }
    }

    /// Retry after a LATER failure in a fallback chat reopens the session
    /// the user opened, not the continuation: reopening the continuation
    /// (no turn yet, so not restorable) fell back a second time over a
    /// blank transcript, and with turns it dropped the original history.
    @Test func retryAfterAFallbackReopensTheOriginSession() async throws {
        try await Self.withFakeRemote { ctx in
            let first = Channel(load: .notRestorable, newId: "acp-new")
            let second = Channel(load: .notRestorable, newId: "acp-new-2")
            let calls = Counter()
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in
                let isFirst = calls.next() == 1
                return ACPClient(context: ctx) { _ in isFirst ? first : second }
            }

            await controller.startResuming(sessionID: "acp-gone")
            #expect(Self.isReady(controller))
            #expect(controller.vm.sessionId == "acp-new")

            // The connection later dies and the ladder gives up; Retry.
            await controller.retryAfterFailure()

            #expect(Self.isReady(controller))
            #expect(await second.loadedIds == ["acp-gone"],
                    "Retry reopened the continuation instead of the origin")
            #expect(controller.vm.sessionId == "acp-new-2")
            let notice = try #require(controller.vm.resumeContinuityNotice)
            #expect(notice.text.contains("couldn’t reopen"))

            // And again: the origin sticks across repeated fallbacks.
            let third = Channel(load: .restores)
            controller.clientFactory = { _ in ACPClient(context: ctx) { _ in third } }
            await controller.retryAfterFailure()
            #expect(await third.loadedIds == ["acp-gone"])
            #expect(controller.vm.sessionId == "acp-gone")
            #expect(controller.vm.resumeContinuityNotice == nil)
        }
    }
}
