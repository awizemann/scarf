import Testing
import Foundation
@testable import ScarfCore

/// P7a (t-67f960a6) — ACP client transport fixes:
/// 1. `session/cancel` goes out as a JSON-RPC NOTIFICATION (no `id`).
///    Hermes's acp lib routes it only as a notification; the old
///    request-shaped frame got `-32601` and never cancelled anything.
/// 2. A failed `initialize` tears the channel down, so a retry spawns a
///    fresh one instead of reporting `.running` uninitialised.
/// 3. A request issued after the transport hit EOF fails promptly instead
///    of hanging (`session/prompt` has no watchdog).
@Suite struct ACPClientP7aTests {

    // MARK: - Scripted channel

    /// In-memory channel that records outgoing lines and answers
    /// `initialize` per the script. Everything else is left unanswered.
    actor ScriptedChannel: ACPChannel {
        enum InitReply { case success, rpcError, none }

        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let initReply: InitReply
        private(set) var sent: [String] = []
        private(set) var closed = false

        var diagnosticID: String? { "scripted-p7a" }
        var lastExitCode: Int32? { closed ? 0 : nil }

        init(initReply: InitReply = .success) {
            let (s, c) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = s
            incomingCont = c
            let (es, ec) = AsyncThrowingStream<String, Error>.makeStream()
            stderr = es
            stderrCont = ec
            self.initReply = initReply
        }

        func send(_ line: String) async throws {
            if closed { throw ACPChannelError.writeEndClosed }
            sent.append(line)
            guard let obj = Self.decode(line),
                  obj["method"] as? String == "initialize",
                  let id = obj["id"] as? Int else { return }
            switch initReply {
            case .success:
                yield(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": 1]])
            case .rpcError:
                yield([
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": -32603, "message": "Internal error"] as [String: Any],
                ])
            case .none:
                break
            }
        }

        func close() async {
            guard !closed else { return }
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }

        func simulateEOF() { incomingCont.finish() }

        /// Raw lines (Sendable) sent for `method`; decode at the call site.
        func sentFrames(method: String) -> [String] {
            sent.filter { Self.decode($0)?["method"] as? String == method }
        }

        func lastLine(method: String) -> String? {
            sent.last { Self.decode($0)?["method"] as? String == method }
        }

        private func yield(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }

        static func decode(_ line: String) -> [String: Any]? {
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// Records every channel the client asks for — one per `hermes acp`
    /// spawn in production.
    actor Ledger {
        private(set) var channels: [ScriptedChannel] = []
        func record(_ ch: ScriptedChannel) { channels.append(ch) }
        var count: Int { channels.count }
        func channel(_ i: Int) -> ScriptedChannel { channels[i] }
    }

    // MARK: - Model of the acp lib's dispatch

    /// The frame classification + routing of the acp lib Hermes pins
    /// (agent-client-protocol 0.9.0 at v2026.9.14 and v2026.9.24; 0.8.1
    /// behaves identically at the v0.6.0 floor):
    /// - `Connection._process_message` (acp/connection.py:164-174):
    ///   `has_id = "id" in message` — the KEY's presence, so `"id": null`
    ///   is still a request;
    /// - `MessageRouter.__call__` (acp/router.py:165-184) looks the method
    ///   up ONLY in the table for that kind, else `method_not_found`
    ///   (-32601);
    /// - `build_agent_router` (acp/agent/router.py:112) registers
    ///   `session/cancel` with `route_notification` — it is in no request
    ///   table.
    /// Mirrors a throwaway probe run against the installed 0.9.0 lib: the
    /// request-shaped frame drew `{"id": 7, "error": {"code": -32601}}` and
    /// never reached `Agent.cancel`; the id-less frame reached it with no
    /// reply.
    enum AcpDispatch: Equatable {
        case agentCancel(sessionId: String)
        case methodNotFound
        case other

        static let notificationRoutes: Set<String> = ["session/cancel"]

        static func route(_ line: String) -> AcpDispatch {
            guard let obj = ScriptedChannel.decode(line),
                  let method = obj["method"] as? String else { return .other }
            let isNotification = !obj.keys.contains("id")
            guard isNotification else {
                // Request table: every agent method EXCEPT session/cancel.
                return notificationRoutes.contains(method) ? .methodNotFound : .other
            }
            guard notificationRoutes.contains(method) else { return .methodNotFound }
            let params = obj["params"] as? [String: Any]
            return .agentCancel(sessionId: params?["sessionId"] as? String ?? "")
        }
    }

    // MARK: - Helpers

    /// A hang guard, not a measurement — generous for a loaded machine.
    private static let ceiling: TimeInterval = 20

    struct TimedOut: Error {}

    final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<T, Error>?
        func set(_ r: Result<T, Error>) { lock.withLock { stored = r } }
        var result: Result<T, Error>? { lock.withLock { stored } }
    }

    /// Run `op`, throwing `TimedOut` if it hasn't finished in `seconds`.
    /// Polls a box rather than awaiting the task: an ACP request parks in a
    /// non-cancellable checked continuation, so awaiting it would hang the
    /// guard itself.
    private func within<T: Sendable>(
        _ seconds: TimeInterval = ceiling,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = ResultBox<T>()
        let work = Task {
            let r: Result<T, Error>
            do { r = .success(try await op()) } catch { r = .failure(error) }
            box.set(r)
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let r = box.result { return try r.get() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        work.cancel()
        throw TimedOut()
    }

    private func waitFor(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Self.ceiling)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out waiting for condition")
        throw TimedOut()
    }

    private func startedClient() async throws -> (ACPClient, ScriptedChannel) {
        let ch = ScriptedChannel()
        let client = ACPClient(context: .local) { _ in ch }
        try await within { try await client.start() }
        return (client, ch)
    }

    // MARK: - 1. session/cancel is a notification

    /// The cancel frame carries no `id` key at all (not `null`), keeps its
    /// `sessionId`, and `cancel` returns without any reply from the agent —
    /// the old request-shaped cancel waited for one (the -32601 error, or
    /// the 60 s watchdog when nothing answered).
    @Test func cancelFrameIsANotificationWithoutId() async throws {
        let (client, ch) = try await startedClient()

        try await within { try await client.cancel(sessionId: "sess-42") }

        let frames = await ch.sentFrames(method: "session/cancel")
        #expect(frames.count == 1)
        let frame = try #require(frames.first.flatMap(ScriptedChannel.decode))
        #expect(!frame.keys.contains("id"))
        #expect(frame["jsonrpc"] as? String == "2.0")
        #expect((frame["params"] as? [String: Any])?["sessionId"] as? String == "sess-42")
        await client.stop()
    }

    /// The exact bytes Scarf writes reach the acp lib's `Agent.cancel`
    /// (per the modelled dispatch), while the pre-fix request shape — and an
    /// `"id": null` variant — are rejected with method-not-found.
    @Test func cancelFrameReachesTheAcpNotificationHandler() async throws {
        let (client, ch) = try await startedClient()
        try await within { try await client.cancel(sessionId: "sess-7") }
        let line = try #require(await ch.lastLine(method: "session/cancel"))

        #expect(AcpDispatch.route(line) == .agentCancel(sessionId: "sess-7"))

        // What ACPClient sent before P7a (ACPRequest, with an id).
        let legacy = ACPRequest(id: 7, method: "session/cancel",
                                params: ["sessionId": AnyCodable("sess-7")])
        let legacyLine = try #require(String(data: try JSONEncoder().encode(legacy), encoding: .utf8))
        #expect(AcpDispatch.route(legacyLine) == .methodNotFound)
        #expect(AcpDispatch.route(#"{"jsonrpc":"2.0","id":null,"method":"session/cancel","params":{"sessionId":"sess-7"}}"#) == .methodNotFound)
        await client.stop()
    }

    /// Cancel on a transport that already hit EOF reports the failure
    /// instead of pretending the cancel went out.
    @Test func cancelAfterEOFThrows() async throws {
        let (client, ch) = try await startedClient()
        await ch.simulateEOF()
        try await waitFor { await !client.isConnected }

        do {
            try await within { try await client.cancel(sessionId: "s") }
            Issue.record("cancel on a dead transport should throw")
        } catch is TimedOut {
            Issue.record("cancel hung on a dead transport")
        } catch let error as ACPClientError {
            guard case .processTerminated = error else {
                Issue.record("expected .processTerminated, got \(error)")
                return
            }
        }
        #expect(await ch.sentFrames(method: "session/cancel").isEmpty)
        await client.stop()
    }

    // MARK: - 2. failed initialize tears down

    /// An `initialize` RPC error closes the channel and resets the client;
    /// the retry spawns a FRESH channel and initialises it. Before the fix
    /// the retry hit `channel != nil`, spawned nothing, and reported
    /// `.running` on a connection that never initialised.
    @Test func failedInitializeTearsDownAndRetrySpawnsFreshChannel() async throws {
        let ledger = Ledger()
        let client = ACPClient(context: .local) { _ in
            // First spawn fails initialize; later ones succeed.
            let ch = ScriptedChannel(initReply: await ledger.count == 0 ? .rpcError : .success)
            await ledger.record(ch)
            return ch
        }

        do {
            try await within { try await client.start() }
            Issue.record("start should rethrow the initialize error")
        } catch let error as ACPClientError {
            guard case .rpcError(let code, _, _) = error else {
                Issue.record("expected .rpcError, got \(error)")
                return
            }
            #expect(code == -32603)
        }

        let first = await ledger.channel(0)
        #expect(await first.closed)
        #expect(await client.state == .idle)
        #expect(await client.isConnected == false)
        #expect(await client.isHealthy == false)

        try await within { try await client.start() }
        try #require(await ledger.count == 2)
        #expect(await client.state == .running)
        #expect(await client.isHealthy)
        let second = await ledger.channel(1)
        #expect(await second.sentFrames(method: "initialize").count == 1)
        #expect(await second.closed == false)
        await client.stop()
    }

    /// Same teardown when the process dies before answering `initialize`.
    @Test func initializeLostToEOFClosesChannel() async throws {
        let ch = ScriptedChannel(initReply: .none)
        let client = ACPClient(context: .local) { _ in ch }

        let start = Task { try await client.start() }
        try await waitFor { await !ch.sentFrames(method: "initialize").isEmpty }
        await ch.simulateEOF()

        do {
            try await within { try await start.value }
            Issue.record("start should fail when the process exits mid-initialize")
        } catch is TimedOut {
            Issue.record("start hung after EOF")
        } catch {}
        #expect(await ch.closed)
        #expect(await client.state == .idle)
        #expect(await client.isHealthy == false)
    }

    // MARK: - 3. requests after EOF fail fast

    /// `session/prompt` has no watchdog. After EOF `isConnected` drops but
    /// `channel` stays, and the old `sendRequest` only checked `channel` —
    /// so the prompt was written into the void and parked until `stop()`.
    @Test func promptAfterEOFFailsPromptly() async throws {
        let (client, ch) = try await startedClient()
        await ch.simulateEOF()
        try await waitFor { await !client.isConnected }

        do {
            _ = try await within { try await client.sendPrompt(sessionId: "s", text: "hi") }
            Issue.record("prompt on a dead transport should throw")
        } catch is TimedOut {
            Issue.record("prompt hung after EOF")
        } catch let error as ACPClientError {
            guard case .processTerminated = error else {
                Issue.record("expected .processTerminated, got \(error)")
                return
            }
        }
        #expect(await ch.sentFrames(method: "session/prompt").isEmpty)
        await client.stop()
    }
}
