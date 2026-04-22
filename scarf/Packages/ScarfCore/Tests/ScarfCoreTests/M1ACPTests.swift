import Testing
import Foundation
@testable import ScarfCore

/// Exercises M1's `ACPChannel` abstraction and the refactored
/// `ACPClient`. Uses a `MockACPChannel` to script JSON-RPC responses
/// deterministically — no subprocess, no SSH, no timing flakiness.
///
/// `ProcessACPChannel` itself isn't exercised here because spawning a
/// real `hermes acp` subprocess in CI would be brittle; the channel's
/// POSIX-write / pipe-framing behaviour is covered on the Mac side
/// during smoke-run testing.
@Suite struct M1ACPTests {

    // MARK: - Mock

    /// In-memory `ACPChannel` for tests. Send queue captures outgoing
    /// lines so tests can assert what ACPClient wrote; `reply(with:)`
    /// / `emit(event:)` script incoming JSON-RPC responses /
    /// notifications; `simulateClose()` closes both streams.
    actor MockACPChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation

        private(set) var sent: [String] = []
        private(set) var closed = false

        public var diagnosticID: String? { "mock-channel" }

        init() {
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            self.incoming = inStream
            self.incomingCont = inCont
            self.stderr = errStream
            self.stderrCont = errCont
        }

        func send(_ line: String) async throws {
            if closed { throw ACPChannelError.writeEndClosed }
            sent.append(line)
        }

        func close() async {
            guard !closed else { return }
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }

        // Test-only scripting entry points.
        func reply(with line: String) {
            incomingCont.yield(line)
        }

        func emitStderr(_ line: String) {
            stderrCont.yield(line)
        }

        func simulateEOF() {
            incomingCont.finish()
        }

        func simulateError(_ error: Error) {
            incomingCont.finish(throwing: error)
        }

        func lastSentRequestId() -> Int? {
            // Pull the last sent line, decode as JSON-RPC, return id.
            guard let last = sent.last,
                  let data = last.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj["id"] as? Int
        }
    }

    // MARK: - ACPChannel protocol basics

    @Test func channelMockBasicSendReceive() async throws {
        let ch = MockACPChannel()
        try await ch.send(#"{"jsonrpc":"2.0","method":"ping"}"#)
        let sent = await ch.sent
        #expect(sent.count == 1)
        await ch.reply(with: #"{"jsonrpc":"2.0","result":{}}"#)

        // Drain one incoming line to prove the stream works.
        var iterator = ch.incoming.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == #"{"jsonrpc":"2.0","result":{}}"#)
    }

    @Test func channelWriteFailsAfterClose() async {
        let ch = MockACPChannel()
        await ch.close()
        do {
            try await ch.send("should fail")
            Issue.record("expected writeEndClosed error")
        } catch let error as ACPChannelError {
            if case .writeEndClosed = error {} else {
                Issue.record("expected .writeEndClosed, got \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func channelErrorDescriptions() {
        #expect(ACPChannelError.closed(exitCode: 2).errorDescription?.contains("exit 2") == true)
        #expect(ACPChannelError.writeEndClosed.errorDescription?.contains("closed") == true)
        #expect(ACPChannelError.invalidEncoding.errorDescription?.contains("UTF-8") == true)
        #expect(ACPChannelError.launchFailed("nope").errorDescription?.contains("nope") == true)
        #expect(ACPChannelError.other("x").errorDescription == "x")
    }

    // MARK: - ACPClient state machine

    /// Build an ACPClient wired to the mock and kick off `start()`.
    /// Returns `(client, mock, startTask)` — `startTask` is pending
    /// until the mock replies to the initialize request.
    @MainActor
    private func buildClientWithMock() async -> (ACPClient, MockACPChannel, Task<Void, Error>) {
        let mock = MockACPChannel()
        let client = ACPClient(context: .local) { _ in mock }

        let startTask = Task {
            try await client.start()
        }
        return (client, mock, startTask)
    }

    @Test @MainActor func clientInitiallyDisconnected() async {
        let mock = MockACPChannel()
        let client = ACPClient(context: .local) { _ in mock }
        let connected = await client.isConnected
        let healthy = await client.isHealthy
        #expect(connected == false)
        #expect(healthy == false)
    }

    @Test @MainActor func clientStartSendsInitializeAndSetsConnected() async throws {
        let (client, mock, startTask) = await buildClientWithMock()

        // Wait until the client has sent the initialize request.
        try await waitFor { await mock.sent.count >= 1 }
        let first = await mock.sent[0]
        #expect(first.contains(#""method":"initialize""#))

        // Reply to that initialize.
        let id = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)

        try await startTask.value
        let connected = await client.isConnected
        #expect(connected == true)
        let status = await client.statusMessage
        #expect(status == "Connected")

        await client.stop()
    }

    @Test @MainActor func clientRpcErrorIsSurfaced() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let id = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"method not found"}}"#)

        do {
            try await startTask.value
            Issue.record("expected start() to throw")
        } catch let error as ACPClientError {
            if case .rpcError(let code, let msg) = error {
                #expect(code == -32601)
                #expect(msg.contains("method not found"))
            } else {
                Issue.record("expected .rpcError, got \(error)")
            }
        }
        await client.stop()
    }

    @Test @MainActor func clientChannelCloseSurfacesAsProcessTerminated() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let id = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        try await startTask.value

        // Client is connected. Issue a session/new; before the mock
        // replies, close the channel. The pending request should
        // resolve with `.processTerminated`.
        let sessionTask = Task {
            try await client.newSession(cwd: "/tmp")
        }
        try await waitFor { await mock.sent.count >= 2 }
        await mock.simulateEOF()

        do {
            _ = try await sessionTask.value
            Issue.record("expected session/new to throw")
        } catch let error as ACPClientError {
            if case .processTerminated = error {} else {
                Issue.record("expected .processTerminated, got \(error)")
            }
        }

        let connected = await client.isConnected
        #expect(connected == false)
        await client.stop()
    }

    @Test @MainActor func clientRoutesSessionUpdateNotificationToEventStream() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let id = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        try await startTask.value

        // Start event consumption.
        let eventTask = Task { () -> ACPEvent? in
            var it = await client.events.makeAsyncIterator()
            return await it.next()
        }

        // Emit a session/update notification for an agent_message_chunk.
        let notification = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"hello"}}}}"#
        await mock.reply(with: notification)

        let event = try await withTimeout(seconds: 2) {
            await eventTask.value
        }
        guard case .messageChunk(let sid, let text) = event else {
            Issue.record("expected .messageChunk, got \(String(describing: event))")
            return
        }
        #expect(sid == "s1")
        #expect(text == "hello")
        await client.stop()
    }

    @Test @MainActor func clientStderrFeedsRecentStderrRingBuffer() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let id = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        try await startTask.value

        await mock.emitStderr("WARNING: something")
        await mock.emitStderr("ERROR: boom")

        // Wait for the read loop to drain.
        try await waitFor { await client.recentStderr.contains("boom") }
        let tail = await client.recentStderr
        #expect(tail.contains("WARNING: something"))
        #expect(tail.contains("ERROR: boom"))
        await client.stop()
    }

    // MARK: - ACPErrorHint

    @Test func errorHintsClassifyCommonFailures() {
        let noCreds = ACPErrorHint.classify(
            errorMessage: "No Anthropic credentials found",
            stderrTail: ""
        )
        #expect(noCreds?.contains("ANTHROPIC_API_KEY") == true)

        let missingBinary = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "No such file or directory: 'npx'"
        )
        #expect(missingBinary?.contains("npx") == true)

        let rateLimit = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "HTTP 429 Too Many Requests: rate limit"
        )
        #expect(rateLimit?.contains("rate-limit") == true)

        let unknown = ACPErrorHint.classify(
            errorMessage: "weird thing",
            stderrTail: "other weird thing"
        )
        #expect(unknown == nil)
    }

    // MARK: - Helpers

    /// Poll `predicate` every ~20ms up to `timeout` seconds. Fails if
    /// the condition never becomes true. Used to bridge between
    /// ACPClient's detached tasks (send loops, read loop, etc.) and
    /// the synchronous test assertions without leaning on Thread.sleep.
    private func waitFor(
        timeout: TimeInterval = 2.0,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("waitFor timed out after \(timeout)s")
    }

    /// Run `op` with an awaited timeout — if it doesn't finish in time,
    /// record an Issue and return `op`'s pending value (cancellation
    /// lets the test fail cleanly rather than hang CI).
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            guard let result = first, let value = result else {
                throw ACPChannelError.other("withTimeout timed out after \(seconds)s")
            }
            return value
        }
    }
}
