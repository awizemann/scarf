import Testing
import Foundation
@testable import ScarfCore

/// M4's new iOS-facing wiring is in `ScarfIOS`, not ScarfCore — so
/// most M4 tests naturally live in `ScarfIOSTests`. But the line-
/// framing / partial-chunk handling that `SSHExecACPChannel` does
/// is identical in shape to what `ProcessACPChannel` does on Mac,
/// and it's important enough that I want coverage on Linux CI too.
///
/// Strategy: pin the expected behaviour using `MockACPChannel` (from
/// M1 tests) to prove that chunked-JSON-line transport feeds
/// `ACPClient`'s read loop correctly. This lets a future refactor of
/// either transport (iOS Citadel or Mac Process) detect line-framing
/// regressions before smoke-testing on a device.
@Suite struct M4ACPIOSTests {

    /// Reused from M1ACPTests — minimal scripted channel. Copied here
    /// rather than imported so this suite stays standalone.
    actor ScriptedChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private(set) var sent: [String] = []
        private(set) var closed = false

        public var diagnosticID: String? { "scripted" }

        init() {
            let (s, c) = AsyncThrowingStream<String, Error>.makeStream()
            self.incoming = s
            self.incomingCont = c
            let (es, ec) = AsyncThrowingStream<String, Error>.makeStream()
            self.stderr = es
            self.stderrCont = ec
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

        func reply(with line: String) { incomingCont.yield(line) }
        func emitStderr(_ line: String) { stderrCont.yield(line) }
        func lastSentId() -> Int? {
            guard let last = sent.last,
                  let d = last.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return nil }
            return obj["id"] as? Int
        }
    }

    // MARK: - Streaming session/prompt flow

    /// The crown jewel of the iOS Chat path: user sends a prompt →
    /// ACP streams agent_message_chunk notifications → ACPClient
    /// dispatches them as `.messageChunk` events → Chat view
    /// appends text. Verify the full handshake + prompt + stream +
    /// complete cycle runs end-to-end through the state machine.
    @Test @MainActor func streamingPromptDeliversChunksAndCompletes() async throws {
        let channel = ScriptedChannel()
        let client = ACPClient(context: .local) { _ in channel }

        // 1. Start — sends `initialize`, blocks on our reply.
        let startTask = Task { try await client.start() }
        try await waitFor { await channel.sent.count >= 1 }
        let initId = await channel.lastSentId() ?? 1
        await channel.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await startTask.value

        // 2. Create session.
        let newSessionTask = Task { try await client.newSession(cwd: "/home/user") }
        try await waitFor { await channel.sent.count >= 2 }
        let newId = await channel.lastSentId() ?? 2
        await channel.reply(with: #"{"jsonrpc":"2.0","id":\#(newId),"result":{"sessionId":"s-test-1"}}"#)
        let sessionId = try await newSessionTask.value
        #expect(sessionId == "s-test-1")

        // 3. Start consuming events BEFORE prompt so we don't miss
        // the streamed chunks.
        let eventsCollected = ArrayBox<ACPEvent>()
        let eventTask = Task { () -> Void in
            var it = await client.events.makeAsyncIterator()
            while let e = await it.next() {
                await eventsCollected.append(e)
                if case .promptComplete = e { return }
                // Safety cap so a broken impl doesn't hang the test
                if await eventsCollected.count > 50 { return }
            }
        }

        // 4. Send a prompt.
        let promptTask = Task { try await client.sendPrompt(sessionId: sessionId, text: "hi") }
        try await waitFor { await channel.sent.count >= 3 }
        let promptId = await channel.lastSentId() ?? 3

        // 5. Stream two agent_message_chunk notifications then the
        // session/prompt response.
        await channel.reply(with: #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-test-1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"Hel"}}}}"#)
        await channel.reply(with: #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-test-1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"lo!"}}}}"#)
        await channel.reply(with: #"{"jsonrpc":"2.0","id":\#(promptId),"result":{"stopReason":"end_turn","usage":{"inputTokens":3,"outputTokens":2}}}"#)

        let result = try await promptTask.value
        #expect(result.stopReason == "end_turn")
        #expect(result.inputTokens == 3)
        #expect(result.outputTokens == 2)

        // Let the event task drain the two chunk events.
        try await Task.sleep(nanoseconds: 50_000_000)
        eventTask.cancel()

        let events = await eventsCollected.value
        let chunks = events.compactMap { e -> String? in
            if case .messageChunk(_, let text) = e { return text }
            return nil
        }
        #expect(chunks == ["Hel", "lo!"])

        await client.stop()
    }

    // MARK: - Permission request round-trip

    @Test @MainActor func permissionRequestYieldsEventAndRespondSends() async throws {
        let channel = ScriptedChannel()
        let client = ACPClient(context: .local) { _ in channel }
        let startTask = Task { try await client.start() }
        try await waitFor { await channel.sent.count >= 1 }
        let initId = await channel.lastSentId() ?? 1
        await channel.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await startTask.value

        let eventCollector = ArrayBox<ACPEvent>()
        let eventTask = Task { () -> Void in
            var it = await client.events.makeAsyncIterator()
            while let e = await it.next() {
                await eventCollector.append(e)
                if case .permissionRequest = e { return }
                if await eventCollector.count > 20 { return }
            }
        }

        // Remote asks permission (comes in as a request, not a
        // notification). `id` is the request's own id, not an answer.
        let requestPayload = #"""
        {"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"title":"write_file: /etc/hosts","kind":"edit"},"options":[{"optionId":"allow_once","name":"Allow once"},{"optionId":"deny","name":"Deny"}]}}
        """#
        await channel.reply(with: requestPayload)

        try await waitFor { await eventCollector.count >= 1 }
        eventTask.cancel()

        let events = await eventCollector.value
        guard case .permissionRequest(_, let reqId, let req) = events.first(where: {
            if case .permissionRequest = $0 { return true } else { return false }
        }) ?? events.first else {
            Issue.record("No permission request event")
            return
        }
        #expect(reqId == 42)
        #expect(req.toolCallTitle == "write_file: /etc/hosts")
        #expect(req.options.count == 2)

        // Respond → we send a response JSON back over the channel.
        let prevSentCount = await channel.sent.count
        await client.respondToPermission(requestId: reqId, optionId: "allow_once")
        try await waitFor { await channel.sent.count > prevSentCount }
        let response = await channel.sent.last ?? ""
        #expect(response.contains("\"id\":42"))
        #expect(response.contains("allow_once") || response.contains("allowed"))

        await client.stop()
    }

    // MARK: - Helpers

    /// Mutable actor-protected Array used for collecting events
    /// off the MainActor event loop without racing.
    actor ArrayBox<T: Sendable> {
        private var items: [T] = []
        func append(_ x: T) { items.append(x) }
        var value: [T] { items }
        var count: Int { items.count }
    }

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
}
