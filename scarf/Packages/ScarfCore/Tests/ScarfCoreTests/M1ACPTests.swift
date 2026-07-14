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

    // MARK: - processTerminated summary line
    //
    // Regression coverage for TestFlight feedback AGTvQ (2026-05-10):
    // the error card surfaced "[INFO] acp_adapter.entry: Loaded env from
    // /home/exedev/.hermes/.env" as if it were the failure reason —
    // because the buffer was entirely INFO startup chatter and the old
    // `firstNonEmptyLine` picked the first match. The fix skips
    // INFO/DEBUG/NOTICE and prefers the LAST signal line.

    @Test func summaryLineSkipsInfoAndDebugChatter() {
        let tail = """
        2026-05-10 23:54:32 [INFO] acp_adapter.entry: Loaded env from /home/exedev/.hermes/.env
        2026-05-10 23:54:32 [INFO] acp_adapter.entry: Starting hermes-agent ACP adapter
        2026-05-10 23:54:33 [ERROR] hermes_cli.acp: ModuleNotFoundError: No module named 'hermes_agent'
        """
        let summary = ACPClientError.summaryLine(fromStderrTail: tail)
        #expect(summary?.contains("ModuleNotFoundError") == true)
        #expect(summary?.contains("[INFO]") == false)
    }

    @Test func summaryLineReturnsNilWhenAllLinesAreInfo() {
        // The exact scenario from AGTvQ: process dies right after
        // startup logs, so the buffer holds nothing useful.
        let tail = """
        2026-05-10 23:54:32 [INFO] acp_adapter.entry: Loaded env from /home/exedev/.hermes/.env
        2026-05-10 23:54:32 [INFO] acp_adapter.entry: Starting hermes-agent ACP adapter
        """
        let summary = ACPClientError.summaryLine(fromStderrTail: tail)
        #expect(summary == nil)
    }

    @Test func summaryLinePicksLastUnprefixedLine() {
        // Python traceback — last line is the exception type + message.
        let tail = """
        Traceback (most recent call last):
          File "/opt/hermes/cli.py", line 42, in <module>
            from hermes_agent import run
        ImportError: cannot import name 'run' from 'hermes_agent'
        """
        let summary = ACPClientError.summaryLine(fromStderrTail: tail)
        #expect(summary?.contains("ImportError") == true)
    }

    @Test func summaryLineHandlesEmptyBuffer() {
        #expect(ACPClientError.summaryLine(fromStderrTail: "") == nil)
        #expect(ACPClientError.summaryLine(fromStderrTail: "\n\n  \n") == nil)
    }

    @Test func processTerminatedDescriptionOmitsTailWhenOnlyInfoChatter() {
        // End-to-end: the visible string in the error banner must NOT
        // include the misleading INFO line.
        let err = ACPClientError.processTerminated(
            exitCode: nil,
            stderrTail: "[INFO] acp_adapter.entry: Loaded env from /home/exedev/.hermes/.env"
        )
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("terminated unexpectedly"))
        #expect(desc.contains("no exit code"))
        #expect(!desc.contains("[INFO]"))
        #expect(!desc.contains("Loaded env"))
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

    // MARK: - session/load not-restorable detection (issue #99 + t-891c321a)
    //
    // Hermes's `load_session` returns a `LoadSessionResponse` dict on a
    // successful restore, but `None` (NOT an error) when the session
    // can't be restored into the ACP runtime. Depending on the framework
    // path that `None` reaches the wire either as `result: null` or —
    // on the acp lib Hermes 0.17/0.18 actually ships, via
    // `normalize_result` — as an EMPTY dict `result: {}` (live-probed
    // against hermes-agent 0.17.0, 2026-07-13). The old code treated any
    // non-throwing response as success and silently returned the
    // requested id — so the chat ran against a phantom session and every
    // prompt came back stopReason=refusal. loadSession must throw on
    // BOTH the null and the empty-dict shape so the caller falls back to
    // a fresh session; a real success always carries `modes` (and
    // usually `models` + `_meta`), so a non-empty dict is the success
    // marker.

    @Test @MainActor func loadSessionThrowsOnNullResult() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let initId = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await startTask.value

        let loadTask = Task {
            try await client.loadSession(cwd: "/tmp", sessionId: "abc-123")
        }
        try await waitFor { await mock.sent.count >= 2 }
        let loadId = await mock.lastSentRequestId() ?? 2
        // Hermes returns `result: null` when the session isn't restorable.
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(loadId),"result":null}"#)

        do {
            _ = try await loadTask.value
            Issue.record("expected loadSession to throw on null result")
        } catch let error as ACPClientError {
            if case .invalidResponse(let msg) = error {
                #expect(msg.contains("abc-123"))
            } else {
                Issue.record("expected .invalidResponse, got \(error)")
            }
        }
        await client.stop()
    }

    @Test @MainActor func loadSessionThrowsOnEmptyDictResult() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let initId = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await startTask.value

        let loadTask = Task {
            try await client.loadSession(cwd: "/tmp", sessionId: "abc-123")
        }
        try await waitFor { await mock.sent.count >= 2 }
        let loadId = await mock.lastSentRequestId() ?? 2
        // The shape Hermes 0.17/0.18 actually emits for a not-restorable
        // session: `normalize_result` turns the handler's None into an
        // empty dict. Verbatim wire frame from the 2026-07-13 live probe:
        //   {"jsonrpc":"2.0","id":2,"result":{}}
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(loadId),"result":{}}"#)

        do {
            _ = try await loadTask.value
            Issue.record("expected loadSession to throw on empty-dict result")
        } catch let error as ACPClientError {
            if case .invalidResponse(let msg) = error {
                #expect(msg.contains("abc-123"))
                #expect(msg.contains("not restorable"))
            } else {
                Issue.record("expected .invalidResponse, got \(error)")
            }
        }
        await client.stop()
    }

    @Test @MainActor func loadSessionSucceedsOnDictResult() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let initId = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await startTask.value

        let loadTask = Task {
            try await client.loadSession(cwd: "/tmp", sessionId: "abc-123")
        }
        try await waitFor { await mock.sent.count >= 2 }
        let loadId = await mock.lastSentRequestId() ?? 2
        // A restorable session returns a LoadSessionResponse dict with
        // `_meta` + `models` + `modes` — condensed from the verbatim
        // success frame captured in the 2026-07-13 live probe against
        // hermes-agent 0.17.0 (the 0.18.2 source builds the identical
        // shape). loadSession returns the requested id since Hermes
        // doesn't echo sessionId in the load response.
        await mock.reply(with: #"""
            {"jsonrpc":"2.0","id":\#(loadId),"result":{"_meta":{"hermes":{"sessionProvenance":{"acpSessionId":"abc-123","sessionKind":"root"}}},"models":{"availableModels":[{"modelId":"custom:llama3.1:8b","name":"llama3.1:8b","description":"Provider: Custom endpoint • current"}],"currentModelId":"custom:llama3.1:8b"},"modes":{"availableModes":[{"id":"default","name":"Default","description":"Ask before edits."}],"currentModeId":"default"}}}
            """#)

        let resolved = try await loadTask.value
        #expect(resolved == "abc-123")
        await client.stop()
    }

    @Test @MainActor func loadSessionSucceedsOnMinimalNonEmptyDictResult() async throws {
        // Pin the exact guard boundary: any NON-empty dict counts as a
        // load — the guard must not demand any specific key, only
        // non-emptiness. The fixture is the pre-0.15 success shape
        // (v2026.5.16 built `LoadSessionResponse(models=…)` with no
        // `modes` at all), so this test deliberately carries NO `modes`
        // key: a "tightened" guard that keys on `modes` — the marker the
        // 0.15+ reasoning leans on — must fail here, because pre-0.15
        // hosts never send it.
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let initId = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await startTask.value

        let loadTask = Task {
            try await client.loadSession(cwd: "/tmp", sessionId: "abc-123")
        }
        try await waitFor { await mock.sent.count >= 2 }
        let loadId = await mock.lastSentRequestId() ?? 2
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(loadId),"result":{"models":{"currentModelId":"anthropic:claude"}}}"#)

        let resolved = try await loadTask.value
        #expect(resolved == "abc-123")
        await client.stop()
    }

    // MARK: - Read-side liveness (stall detection)
    //
    // Regression coverage for TestFlight feedback AObiv7 (2026-05-07):
    // "streaming from chats stop, and I have to either force close or
    // at least go back to the dashboard to get updates again." Cause:
    // SSH socket over Tailscale silently stops carrying bytes; Citadel
    // doesn't EOF the exec stream; iOS health monitor sees `isHealthy
    // == true` and never routes to the reconnect path. Fix: expose
    // `secondsSinceLastIncoming` so the iOS monitor can layer stall
    // detection on top.

    @Test @MainActor func lastIncomingIsInfinityBeforeStart() async {
        let mock = MockACPChannel()
        let client = ACPClient(context: .local) { _ in mock }
        let idle = await client.secondsSinceLastIncoming
        #expect(idle == .infinity)
    }

    @Test @MainActor func lastIncomingIsFreshImmediatelyAfterStart() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let id = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        try await startTask.value

        // The initialize response itself counts as channel activity,
        // so the idle clock should be sub-second right after start.
        let idle = await client.secondsSinceLastIncoming
        #expect(idle.isFinite)
        #expect(idle < 2.0)

        await client.stop()
    }

    @Test @MainActor func lastIncomingResetsOnAnyIncomingLine() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let id = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        try await startTask.value

        // Brief pause so the idle clock has visibly advanced.
        try await Task.sleep(nanoseconds: 60_000_000)   // 60ms

        let before = await client.secondsSinceLastIncoming
        // A session/update notification — pure incoming activity, no
        // protocol-level meaning required to refresh the clock.
        await mock.reply(with: #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"hi"}}}}"#)
        try await waitFor { await client.secondsSinceLastIncoming < before }
        let after = await client.secondsSinceLastIncoming
        #expect(after < before)

        await client.stop()
    }

    @Test @MainActor func lastIncomingResetsOnStderr() async throws {
        let (client, mock, startTask) = await buildClientWithMock()
        try await waitFor { await mock.sent.count >= 1 }
        let id = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        try await startTask.value

        try await Task.sleep(nanoseconds: 60_000_000)
        let before = await client.secondsSinceLastIncoming
        await mock.emitStderr("[INFO] heartbeat")
        try await waitFor { await client.secondsSinceLastIncoming < before }

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

    // MARK: - session/set_model encoding (issue #97)
    //
    // Hermes's ACP adapter expects the `model_id` parameter on
    // `session/set_model` to be colon-encoded as `<provider>:<model>`
    // when the client knows the provider. Pre-2.9.1 Scarf sent only
    // the bare model name; Hermes then fell into `parse_model_input`
    // → `detect_provider_for_model` and inferred the provider from
    // the model name string alone, which routed less-obvious IDs
    // (like `inclusionai/ring-2.6-1t`) to the wrong provider.

    @Test func encodeModelChoiceBareModelWhenProviderNil() {
        #expect(
            ACPClient.encodeModelChoice(modelID: "claude-opus-4-7", providerID: nil)
                == "claude-opus-4-7"
        )
    }

    @Test func encodeModelChoiceBareModelWhenProviderEmpty() {
        #expect(
            ACPClient.encodeModelChoice(modelID: "claude-opus-4-7", providerID: "")
                == "claude-opus-4-7"
        )
        #expect(
            ACPClient.encodeModelChoice(modelID: "claude-opus-4-7", providerID: "   ")
                == "claude-opus-4-7"
        )
    }

    @Test func encodeModelChoiceWithProviderPrefixesWithColon() {
        // The bug-report case from issue #97 — slash-format model IDs
        // need the provider prefix so Hermes routes through openrouter
        // instead of guessing via detect_provider_for_model.
        #expect(
            ACPClient.encodeModelChoice(
                modelID: "inclusionai/ring-2.6-1t",
                providerID: "openrouter"
            ) == "openrouter:inclusionai/ring-2.6-1t"
        )
    }

    @Test func encodeModelChoiceLowercasesProvider() {
        // Hermes's `_encode_model_choice` lower-cases the provider half;
        // Scarf matches so a preset saved with "Anthropic" still resolves.
        #expect(
            ACPClient.encodeModelChoice(modelID: "claude-opus-4-7", providerID: "Anthropic")
                == "anthropic:claude-opus-4-7"
        )
    }

    @Test func encodeModelChoiceTrimsWhitespace() {
        #expect(
            ACPClient.encodeModelChoice(
                modelID: "  claude-opus-4-7  ",
                providerID: "  anthropic  "
            ) == "anthropic:claude-opus-4-7"
        )
    }

    @Test func encodeModelChoiceEmptyModelReturnsEmpty() {
        // Hermes treats empty as "leave alone" — keep that property so
        // a `nil` ModelPreset.global-default path that falls through to
        // an empty config.yaml model is a safe no-op.
        #expect(
            ACPClient.encodeModelChoice(modelID: "", providerID: "anthropic") == ""
        )
        #expect(
            ACPClient.encodeModelChoice(modelID: "   ", providerID: "anthropic") == ""
        )
    }

    @Test func approvalModeRawValuesMatchHermesWireIDs() {
        // Wire IDs verified against Hermes v2026.5.28 ACP `modes`.
        #expect(ACPApprovalMode.default.rawValue == "default")
        #expect(ACPApprovalMode.acceptEdits.rawValue == "accept_edits")
        #expect(ACPApprovalMode.dontAsk.rawValue == "dont_ask")
        // Round-trip from the wire ID back into the enum.
        #expect(ACPApprovalMode(rawValue: "default") == .default)
        #expect(ACPApprovalMode(rawValue: "accept_edits") == .acceptEdits)
        #expect(ACPApprovalMode(rawValue: "dont_ask") == .dontAsk)
        // All three modes are enumerable for the header picker.
        #expect(ACPApprovalMode.allCases.count == 3)
    }

    @Test func approvalModeDisplayAndSummaryAreNonEmpty() {
        for mode in ACPApprovalMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.summary.isEmpty)
        }
    }

    @Test func errorHintsClassifyCommonFailures() {
        let noCreds = ACPErrorHint.classify(
            errorMessage: "No Anthropic credentials found",
            stderrTail: ""
        )
        #expect(noCreds?.hint.contains("ANTHROPIC_API_KEY") == true)
        #expect(noCreds?.oauthProvider == nil)

        let missingBinary = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "No such file or directory: 'npx'"
        )
        #expect(missingBinary?.hint.contains("npx") == true)

        let rateLimit = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "HTTP 429 Too Many Requests: rate limit"
        )
        #expect(rateLimit?.hint.contains("rate-limit") == true)

        let unknown = ACPErrorHint.classify(
            errorMessage: "weird thing",
            stderrTail: "other weird thing"
        )
        #expect(unknown == nil)
    }

    @Test func errorHintsClassifyOAuthRefreshRevoked() {
        // Primary trigger — Hermes's verbatim message when an OAuth
        // refresh token can't mint a new access token. Provider name
        // appears alongside; classifier should extract it.
        let revoked = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "Refresh session has been revoked. Run `hermes model` to re-authenticate."
        )
        #expect(revoked?.hint.contains("Re-authenticate") == true)

        // With provider context — surfaces the affected provider name
        // so the chat banner can offer a one-click re-auth that targets
        // the right OAuth flow.
        let revokedWithProvider = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "Provider claude: Refresh session has been revoked. Run `hermes model` to re-authenticate."
        )
        #expect(revokedWithProvider?.oauthProvider == "claude")

        // 401 + OAuth provider name — broader catchall for providers
        // that don't print the verbatim "revoked" string.
        let unauthorized = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "HTTP 401 Unauthorized from nous portal"
        )
        #expect(unauthorized?.oauthProvider == "nous")
        #expect(unauthorized?.hint.contains("OAuth") == true)

        // Unauthorized on a non-OAuth provider (API-key based) should
        // NOT classify as OAuth revocation — no `oauthProvider` known
        // to dispatch the re-auth flow against.
        let unauthorizedNonOAuth = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "HTTP 401 Unauthorized for groq"
        )
        #expect(unauthorizedNonOAuth?.oauthProvider == nil)

        // Word-boundary check — "anthropicapi" must not false-trigger
        // on "anthropic". Without word boundaries this catches the
        // wrong cases.
        let substringNoMatch = ACPErrorHint.classify(
            errorMessage: "",
            stderrTail: "401 unauthorized: anthropicapi.example.com"
        )
        #expect(substringNoMatch?.oauthProvider != "anthropic")
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
