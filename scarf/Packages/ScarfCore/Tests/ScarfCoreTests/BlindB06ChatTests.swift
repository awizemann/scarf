#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// B06 (blind re-audit, t-4111cb69) — the ScarfCore half of the chat fixes
/// shared by the Mac chat, Bot Chat and ScarfGo:
///  - S01-F2 Stop: a user stop ends the turn quietly but visibly, answers
///    on-screen permission requests, and a poll tick already in flight
///    can't set "working" again after the send is unwound (t-14157321);
///  - t-14157321: a permission request that arrives before the first
///    prompt keeps its close;
///  - S01-F1 / S03-F2: `session/new` / `session/load` responses carry the
///    session's mode and model to the client;
///  - S02-F2 diff-only tool results; S02-F3 the /queue mirror; S02-F4 the
///    header's usage after a rotating compression;
///  - B03 handoff: `~` project paths expanded for the ACP cwd.
@Suite struct BlindB06ChatTests {

    // MARK: - Helpers

    private static func result(_ stopReason: String) -> ACPPromptResult {
        ACPPromptResult(stopReason: stopReason, inputTokens: 0, outputTokens: 0,
                        thoughtTokens: 0, cachedReadTokens: 0)
    }

    @MainActor
    private static func engagedVM() -> RichChatViewModel {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "go")
        return vm
    }

    private static func permission(_ requestId: Int, toolCallId: String) -> ACPEvent {
        .permissionRequest(sessionId: "s", requestId: requestId, request: ACPPermissionRequestEvent(
            toolCallTitle: "rm -rf build", toolCallKind: "execute",
            options: [(optionId: "allow_once", name: "Allow"), (optionId: "deny", name: "Deny")],
            toolCallId: toolCallId
        ))
    }

    private static func parse(_ json: String) throws -> ACPEvent? {
        let raw = try JSONDecoder().decode(ACPRawMessage.self, from: Data(json.utf8))
        return ACPEventParser.parse(notification: raw)
    }

    // MARK: - S01-F2 Stop

    /// Stop → Hermes answers `cancelled`: no failure bubble or banner, but
    /// the transcript says the user stopped the turn, and working ends.
    @Test @MainActor func userStopEndsTheTurnWithAStoppedNoteAndNoBanner() async {
        let vm = Self.engagedVM()
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Partial"))
        vm.noteTurnStopRequestedByUser()
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("cancelled")))
        try? await Task.sleep(nanoseconds: 100_000_000) // let a stray banner task run

        let notes = vm.messages.filter { $0.role == "system" }
        #expect(notes.count == 1)
        #expect(notes.first?.content.contains("You stopped this turn") == true)
        #expect(notes.first?.finishReason == "cancelled")
        #expect(!notes.contains { $0.content.contains("ended without a response") })
        #expect(vm.acpError == nil, "a user stop is not a failure")
        #expect(vm.isAgentWorking == false)
        #expect(vm.messages.contains { $0.isAssistant && $0.content == "Partial" }, "the partial reply was dropped")
    }

    /// B11: from v0.19.1 Hermes prepends the stopped request to the next
    /// plain prompt (`acp_adapter/server.py:721-722` @ v2026.9.24), so the
    /// note says so there; older or undetected hosts keep the plain note.
    @Test @MainActor func stoppedNoteWordingFollowsTheHostBand() {
        let bands: [(String?, Bool)] = [
            ("Hermes Agent v0.21.5 (2026.9.24)", true),
            ("Hermes Agent v0.19.1 (2026.7.30)", true),
            ("Hermes Agent v0.19.0 (2026.7.20)", false),
            (nil, false),
        ]
        for (version, carries) in bands {
            let vm = Self.engagedVM()
            if let version { vm.publishCapabilities(HermesCapabilities.parse(version)) }
            vm.noteTurnStopRequestedByUser()
            vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("cancelled")))
            let note = vm.messages.last { $0.role == "system" }?.content ?? ""
            #expect(note.hasPrefix("You stopped this turn."), "\(version ?? "undetected")")
            #expect(note.contains("follow-up to the stopped request") == carries, "\(version ?? "undetected")")
        }
        // A CLI-driven turn (bot chat) never carries the prompt forward.
        let vm = Self.engagedVM()
        vm.publishCapabilities(HermesCapabilities.parse("Hermes Agent v0.21.5 (2026.9.24)"))
        vm.appendTurnStoppedNote()
        #expect(vm.messages.last?.content.contains("follow-up") == false)
    }

    /// The stop marker belongs to one turn: a stop Hermes raced (the turn
    /// finished anyway) adds no note and does not mark the next turn.
    @Test @MainActor func stopMarkerDoesNotLeakIntoTheNextTurn() async {
        let vm = Self.engagedVM()
        vm.noteTurnStopRequestedByUser()
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Done"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("end_turn")))
        #expect(!vm.messages.contains { $0.role == "system" })

        vm.addUserMessage(text: "again")
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("cancelled")))
        #expect(!vm.messages.contains { $0.content.contains("You stopped this turn") },
                "an unrequested cancel painted the user-stop note")
    }

    /// Stop answers every permission request on screen with `cancelled`
    /// right away — a turn blocked on approval can't end otherwise.
    @Test @MainActor func userStopAnswersQueuedPermissionRequests() {
        let vm = Self.engagedVM()
        var cancelled: [Int] = []
        vm.permissionCanceller = { cancelled.append($0) }
        vm.handleACPEvent(Self.permission(7, toolCallId: "perm-check-1"))
        vm.handleACPEvent(Self.permission(8, toolCallId: "perm-check-2"))
        #expect(vm.pendingPermission != nil)

        vm.noteTurnStopRequestedByUser()
        #expect(vm.pendingPermission == nil)
        #expect(cancelled.sorted() == [7, 8])
    }

    // MARK: - t-14157321: permission close before engagement

    /// A request that lands before the first prompt (a replayed/auto-resumed
    /// turn) is shown; Hermes's close for it must pop it too. Pre-fix the
    /// pre-engagement gate dropped the close and the sheet stayed up.
    @Test @MainActor func permissionCloseBeforeEngagementPopsTheRequest() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.handleACPEvent(Self.permission(3, toolCallId: "perm-check-9"))
        #expect(vm.pendingPermission?.requestId == 3)

        vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: "perm-check-9", kind: "execute", status: "failed", content: "", rawOutput: nil
        )))
        #expect(vm.pendingPermission == nil, "the close was dropped by the pre-engagement gate")
        #expect(vm.transientHint?.contains("stopped waiting") == true)
        #expect(vm.messages.isEmpty, "a pre-engagement close must not add a tool row")
    }

    /// Other pre-engagement tool updates (replay) are still dropped.
    @Test @MainActor func unrelatedPreEngagementToolUpdateStillDropped() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.handleACPEvent(Self.permission(3, toolCallId: "perm-check-9"))
        vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: "tc-replayed", kind: "execute", status: "completed", content: "out", rawOutput: nil
        )))
        #expect(vm.pendingPermission?.requestId == 3)
        #expect(vm.messages.isEmpty)
    }

    // MARK: - S02-F3 queue mirror

    /// Hermes runs every queued prompt before the owning turn answers, so
    /// the mirror is empty once it completes — not one entry shorter.
    @Test @MainActor func queueMirrorClearsWhenTheOwningTurnCompletes() {
        let vm = Self.engagedVM()
        vm.recordQueuedPrompt(text: "A")
        vm.recordQueuedPrompt(text: "B")
        #expect(vm.queuedPrompts.count == 2)
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("end_turn")))
        #expect(vm.queuedPrompts.isEmpty)
    }

    // MARK: - S02-F2 diff-only tool results

    /// A `skill_manage` edit completes with diff blocks only and no
    /// rawOutput; the live result shows the change instead of nothing.
    @Test func diffOnlyToolUpdateRendersTheDiff() throws {
        let json = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{
          "sessionUpdate":"tool_call_update","toolCallId":"tc-1","kind":"edit","status":"completed",
          "content":[{"type":"diff","path":"skills/demo/SKILL.md","oldText":"a\nb\nc","newText":"a\nB\nc"}]
        }}}
        """#
        guard case .toolCallUpdate(_, let update)? = try Self.parse(json) else {
            Issue.record("not parsed as a tool_call_update"); return
        }
        #expect(update.rawOutput == nil)
        #expect(update.content == "--- skills/demo/SKILL.md\n+++ skills/demo/SKILL.md\n a\n-b\n+B\n c")
    }

    /// Text blocks read as before, next to a diff block; start events keep
    /// the text-only reading.
    @Test func mixedContentAndStartEventsKeepTheirReading() throws {
        let update = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{
          "sessionUpdate":"tool_call_update","toolCallId":"tc-1","status":"completed",
          "content":[{"type":"content","content":{"type":"text","text":"ok"}},
                     {"type":"diff","path":"f.txt","newText":"new"}]
        }}}
        """#
        guard case .toolCallUpdate(_, let parsed)? = try Self.parse(update) else {
            Issue.record("not parsed"); return
        }
        #expect(parsed.content == "ok\n--- f.txt\n+++ f.txt\n+new")

        let start = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{
          "sessionUpdate":"tool_call","toolCallId":"tc-2","title":"patch f.txt","kind":"edit","status":"pending",
          "content":[{"type":"diff","path":"f.txt","oldText":"x","newText":"y"}]
        }}}
        """#
        guard case .toolCallStart(_, let call)? = try Self.parse(start) else {
            Issue.record("not parsed"); return
        }
        #expect(call.content == "", "start events changed their content reading")
    }

    // MARK: - S01-F1 / S03-F2 session mode and model

    @Test func sessionStateReadsModeAndModelFromTheResponse() {
        let state = ACPSessionState(response: [
            "modes": ["currentModeId": "default", "availableModes": []] as [String: Any],
            "models": ["currentModelId": "anthropic:claude-opus-4", "availableModels": []] as [String: Any],
        ])
        #expect(state.currentModeId == "default")
        #expect(state.currentModelId == "anthropic:claude-opus-4")
        // Pre-0.15 host: no fields — nothing claimed.
        #expect(ACPSessionState(response: ["sessionId": "x"]) == ACPSessionState())
    }

    @Test func pickerIdSplitsProviderAndModel() {
        #expect(ACPSessionState.modelName(fromPickerId: "openrouter:anthropic/claude-3.5") == "anthropic/claude-3.5")
        #expect(ACPSessionState.providerID(fromPickerId: "openrouter:anthropic/claude-3.5") == "openrouter")
        #expect(ACPSessionState.modelName(fromPickerId: "custom:ollama:llama3:8b") == "llama3:8b")
        #expect(ACPSessionState.providerID(fromPickerId: "custom:ollama:llama3:8b") == "custom:ollama")
        #expect(ACPSessionState.modelName(fromPickerId: "ollama:llama3:8b") == "llama3:8b")
        #expect(ACPSessionState.modelName(fromPickerId: "gpt-5") == "gpt-5")
        #expect(ACPSessionState.providerID(fromPickerId: "gpt-5") == nil)
    }

    /// The client keeps what `session/new` and `session/load` reported.
    @Test @MainActor func clientRecordsSessionStateFromNewAndLoad() async throws {
        let channel = ScriptedChannel()
        let client = ACPClient(context: .local) { _ in channel }
        let startTask = Task { try await client.start() }
        try await Self.waitFor { await channel.sent.count >= 1 }
        await channel.reply(with: #"{"jsonrpc":"2.0","id":\#(await channel.lastSentId() ?? 1),"result":{}}"#)
        try await startTask.value

        let newTask = Task { try await client.newSession(cwd: "/home/u") }
        try await Self.waitFor { await channel.sent.count >= 2 }
        await channel.reply(with: #"{"jsonrpc":"2.0","id":\#(await channel.lastSentId() ?? 2),"result":{"sessionId":"s1","modes":{"currentModeId":"default","availableModes":[]},"models":{"currentModelId":"anthropic:opus","availableModels":[]}}}"#)
        _ = try await newTask.value
        #expect(await client.lastSessionState == ACPSessionState(currentModeId: "default", currentModelId: "anthropic:opus"))

        let loadTask = Task { try await client.loadSessionWithProvenance(cwd: "/home/u", sessionId: "s0") }
        try await Self.waitFor { await channel.sent.count >= 3 }
        await channel.reply(with: #"{"jsonrpc":"2.0","id":\#(await channel.lastSentId() ?? 3),"result":{"modes":{"currentModeId":"dont_ask","availableModes":[]}}}"#)
        _ = try await loadTask.value
        #expect(await client.lastSessionState == ACPSessionState(currentModeId: "dont_ask", currentModelId: nil))
        await client.stop()
    }

    // MARK: - S02-F4 usage across a rotation

    @Test func usageAddsContinuationRows() {
        func row(_ id: String, input: Int, output: Int, cost: Double?) -> HermesSession {
            HermesSession(id: id, source: "acp", userId: nil, model: "m", title: "t", parentSessionId: nil,
                          startedAt: nil, endedAt: nil, endReason: nil, messageCount: 1, toolCallCount: 0,
                          inputTokens: input, outputTokens: output, cacheReadTokens: 1, cacheWriteTokens: 0,
                          estimatedCostUSD: cost, reasoningTokens: 2, actualCostUSD: nil, costStatus: nil,
                          billingProvider: nil, apiCallCount: 3)
        }
        let summed = row("root", input: 100, output: 10, cost: 0.5)
            .addingUsage(of: [row("tip", input: 40, output: 4, cost: nil)])
        #expect(summed.id == "root")
        #expect(summed.inputTokens == 140)
        #expect(summed.outputTokens == 14)
        #expect(summed.cacheReadTokens == 2)
        #expect(summed.reasoningTokens == 4)
        #expect(summed.apiCallCount == 6)
        #expect(summed.estimatedCostUSD == 0.5)
        #expect(summed.actualCostUSD == nil)
    }

    // MARK: - B03 handoff: ACP cwd

    @Test func acpCwdExpandsATildeProjectPath() async {
        let home = await ServerContext.local.resolvedUserHome()
        #expect(await ServerContext.local.acpSessionCwd(projectPath: "~/projects/x") == home + "/projects/x")
        #expect(await ServerContext.local.acpSessionCwd(projectPath: "/abs/p") == "/abs/p")
        #expect(await ServerContext.local.acpSessionCwd(projectPath: nil) == home)
    }

    // MARK: - t-14157321: in-flight poll tick after cancelPendingSend

    private final class Fixture {
        let home: URL
        let dbPath: String
        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("scarf-b06-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            dbPath = home.appendingPathComponent("state.db").path
            try exec("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
                parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
                message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
                output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                estimated_cost_usd REAL
            );
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
                tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
                token_count INTEGER, finish_reason TEXT
            );
            INSERT INTO sessions (id, source, started_at, message_count, tool_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd)
            VALUES ('s', 'cli', 1700000000, 0, 0, 0, 0, 0, 0, 0);
            INSERT INTO messages (id, session_id, role, content, timestamp)
            VALUES (1, 's', 'user', 'hello bot', \(Date().timeIntervalSince1970));
            """)
        }

        func exec(_ sql: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                throw TransportError.other(message: "sqlite3_open_v2 failed")
            }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw TransportError.other(message: "fixture SQL failed")
            }
        }

        var context: ServerContext { .local(home: home) }
        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    /// A tick that was awaiting the database when the send was unwound
    /// shows the rows but must not set "working" again — the poll timer is
    /// gone, so nothing would ever clear it. The DB's last row is the
    /// user's prompt, which on its own derives "working".
    @Test @MainActor func inFlightPollTickCannotRestoreWorkingAfterCancel() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = RichChatViewModel(context: fx.context)
        vm.setSessionId("s")
        vm.addUserMessage(text: "hello bot")
        vm.markAgentWorking()

        // Test-only: the tick and the unwind interleave on the main actor.
        nonisolated(unsafe) let ticking = vm
        let tick = Task { @MainActor in await ticking.refreshMessages() }
        // Let the tick start; it then suspends on the database.
        while vm.pollTicksStarted == 0 { await Task.yield() }
        vm.cancelPendingSend()
        await tick.value

        #expect(vm.isAgentWorking == false, "the in-flight tick set working again after cancelPendingSend")
        #expect(vm.messages.contains { $0.isUser && $0.content == "hello bot" })

        // A tick that starts after the unwind reads the DB as before.
        await vm.refreshMessages()
        #expect(vm.messages.contains { $0.id == 1 })
    }

    // MARK: - ACP scripted channel

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
            incoming = s; incomingCont = c
            let (es, ec) = AsyncThrowingStream<String, Error>.makeStream()
            stderr = es; stderrCont = ec
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
        func lastSentId() -> Int? {
            guard let last = sent.last, let d = last.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return obj["id"] as? Int
        }
    }

    private static func waitFor(
        timeout: TimeInterval = 30.0,
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

#endif
