#if canImport(SQLite3)

import Testing
import Foundation
@testable import ScarfCore

/// gh#147, gateway half: from v0.22.3 `hermes acp` (gateway-backed) serves
/// `/undo [N]` and `/retry` itself (`ROUTES`,
/// acp_adapter/gateway_commands.py:288-289 @ v0.22.5), so Scarf must send
/// them instead of answering "Use the Hermes CLI", and the transcript must
/// follow the rewind, which Hermes records only in state.db (`active = 0`,
/// hermes_state_mutation_transcript.py:25-28 @ v0.22.5).
@Suite struct GatewayRewindSlashTests {

    static func caps(_ version: String) -> HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v\(version) (2026.9.24)")
    }

    // MARK: - Classification

    /// v0.22.1 is gateway-backed but refuses both (`slash_mutation` raises
    /// `unsupported_command`, hermes_cli/gateway_mutations.py:136-149 @
    /// v0.22.1), so it keeps the interception with every older host.
    @Test(arguments: ["retry", "undo"])
    func interceptedWhereHermesDoesNotServeThem(name: String) {
        let hosts: [HermesCapabilities] = [
            .empty, Self.caps("0.6.0"), Self.caps("0.21.5"), Self.caps("0.22.1"), Self.caps("0.22.2")
        ]
        for host in hosts {
            #expect(RichChatViewModel.clientSideSlashCommand(for: "/\(name)", capabilities: host)
                    == .cliOnly(name: name), "\(host.versionLine)")
            #expect(RichChatViewModel.clientSideSlashCommand(for: "/\(name) 2", capabilities: host)
                    == .cliOnly(name: name), "\(host.versionLine)")
            #expect(!RichChatViewModel.isGatewayRewindSlash("/\(name)", capabilities: host))
        }
        // The default stays the pre-gateway answer.
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/\(name)") == .cliOnly(name: name))
    }

    @Test(arguments: ["retry", "undo"])
    func sentToHermesWhereItServesThem(name: String) {
        for host in [Self.caps("0.22.3"), Self.caps("0.22.4"), Self.caps("0.22.5")] {
            #expect(RichChatViewModel.clientSideSlashCommand(for: "/\(name)", capabilities: host) == nil)
            #expect(RichChatViewModel.clientSideSlashCommand(for: "/\(name) 2", capabilities: host) == nil)
            #expect(RichChatViewModel.isGatewayRewindSlash("/\(name)", capabilities: host))
        }
    }

    /// The other client-side commands are unchanged on a gateway host.
    @Test func otherClientSideCommandsUnchangedOnGateway() {
        let gw = Self.caps("0.22.5")
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/new", capabilities: gw) == .newSession(name: nil))
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/title X", capabilities: gw) == .renameSession(title: "X"))
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/undone", capabilities: gw) == nil)
        #expect(!RichChatViewModel.isGatewayRewindSlash("/retryx", capabilities: gw))
        #expect(!RichChatViewModel.isGatewayRewindSlash("retry", capabilities: gw))
    }

    /// No "sent as an ordinary prompt" note for either, on any host.
    @Test func noUnhandledNotice() {
        for host in [HermesCapabilities.empty, Self.caps("0.22.5")] {
            #expect(RichChatViewModel.acpUnhandledSlashNotice(name: "undo", capabilities: host) == nil)
            #expect(RichChatViewModel.acpUnhandledSlashNotice(name: "retry", capabilities: host) == nil)
        }
    }

    /// A served `/undo` stores no user row and `/retry`'s row is the resent
    /// text, so neither echo may wait for a "/undo" or "/retry" row.
    @Test func echoesExpectNoSlashRowOnlyWhereServed() {
        let vm = RichChatViewModel(context: .local)
        vm.publishCapabilities(Self.caps("0.22.5"))
        #expect(vm.hermesDispatchedSlashNames.isSuperset(of: ["undo", "retry"]))
        vm.publishCapabilities(Self.caps("0.22.1"))
        #expect(vm.hermesDispatchedSlashNames.isDisjoint(with: ["undo", "retry"]))
    }

    // MARK: - Transcript follows the rewind

    static let seed = """
    INSERT INTO sessions (id, source, started_at) VALUES ('s', 'acp', 1700000000);
    INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
        (1, 's', 'user', 'q1', 1700000001, 1, 0),
        (2, 's', 'assistant', 'a1', 1700000002, 1, 0),
        (3, 's', 'user', 'q2', 1700000003, 1, 0),
        (4, 's', 'assistant', 'a2', 1700000004, 1, 0);
    """

    static func transcript(_ vm: RichChatViewModel) -> [String] {
        vm.messages.filter { $0.isUser || $0.isAssistant }.map(\.content)
    }

    static let done = ACPPromptResult(stopReason: "end_turn", inputTokens: 0, outputTokens: 0,
                                      thoughtTokens: 0, cachedReadTokens: 0)

    /// Send `wire` the way the chat send paths do, stream `reply`, end the turn.
    static func run(_ vm: RichChatViewModel, wire: String, reply: String) {
        vm.addUserMessage(text: wire)
        vm.notePromptWire(displayText: wire, wireText: wire, imageCount: 0)
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: reply))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: done))
    }

    @Test func undoDropsTheRewoundTurnAndHandsBackTheReply() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        await vm.loadSessionHistory(sessionId: "s")
        #expect(Self.transcript(vm) == ["q1", "a1", "q2", "a2"])

        let reply = "Undid 1 turn (2 message(s)).\nRemoved message: q2"
        Self.run(vm, wire: "/undo", reply: reply)
        // What `_rewind` committed before replying.
        try HermesV0215R18bTests.exec("UPDATE messages SET active = 0 WHERE id >= 3;", home: home)

        let hint = await vm.followRewindFromDB(wireText: "/undo")
        #expect(Self.transcript(vm) == ["q1", "a1"])
        #expect(hint == reply)

        // Reopening reads the same rows.
        vm.reset()
        await vm.loadSessionHistory(sessionId: "s")
        #expect(Self.transcript(vm) == ["q1", "a1"])
    }

    @Test func retryLeavesOneFreshAnswer() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        await vm.loadSessionHistory(sessionId: "s")

        Self.run(vm, wire: "/retry", reply: "a2 again")
        // Rewound turn archived; the resent text and its answer stored.
        try HermesV0215R18bTests.exec("""
            UPDATE messages SET active = 0 WHERE id >= 3;
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
                (5, 's', 'user', 'q2', 1700000005, 1, 0),
                (6, 's', 'assistant', 'a2 again', 1700000006, 1, 0);
            """, home: home)

        let hint = await vm.followRewindFromDB(wireText: "/retry")
        #expect(hint == nil)
        #expect(Self.transcript(vm) == ["q1", "a1", "q2", "a2 again"])
        #expect(vm.messages.allSatisfy { $0.id > 0 })
    }

    /// The live-gate failure (v0.22.5): turns typed in this window are local
    /// echoes, never re-read from state.db. The rebuild kept the undone
    /// prompt's echo because its row is rewound (`active = 0`, not read),
    /// so "Reply with exactly: ALPHA" stayed on screen.
    @Test func undoOfATurnTypedInThisWindowDropsItsEcho() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: """
            INSERT INTO sessions (id, source, started_at) VALUES ('s', 'acp', 1700000000);
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        vm.setSessionId("s")
        Self.run(vm, wire: "Reply with exactly: ALPHA", reply: "ALPHA")
        try HermesV0215R18bTests.exec("""
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
                (1, 's', 'user', 'Reply with exactly: ALPHA', 1700000001, 1, 0),
                (2, 's', 'assistant', 'ALPHA', 1700000002, 1, 0);
            """, home: home)
        Self.run(vm, wire: "/undo", reply: "Undid 1 turn (2 message(s)).")
        try HermesV0215R18bTests.exec("UPDATE messages SET active = 0;", home: home)

        let hint = await vm.followRewindFromDB(wireText: "/undo")
        #expect(Self.transcript(vm).isEmpty)
        #expect(hint == "Undid 1 turn (2 message(s)).")

        // Then BRAVO and a successful /retry: one prompt, one fresh answer.
        Self.run(vm, wire: "Reply with exactly: BRAVO", reply: "BRAVO")
        try HermesV0215R18bTests.exec("""
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
                (3, 's', 'user', 'Reply with exactly: BRAVO', 1700000003, 1, 0),
                (4, 's', 'assistant', 'BRAVO', 1700000004, 1, 0);
            """, home: home)
        Self.run(vm, wire: "/retry", reply: "BRAVO!")
        try HermesV0215R18bTests.exec("""
            UPDATE messages SET active = 0 WHERE id >= 3;
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
                (5, 's', 'user', 'Reply with exactly: BRAVO', 1700000005, 1, 0),
                (6, 's', 'assistant', 'BRAVO!', 1700000006, 1, 0);
            """, home: home)
        #expect(await vm.followRewindFromDB(wireText: "/retry") == nil)
        #expect(Self.transcript(vm) == ["Reply with exactly: BRAVO", "BRAVO!"])
    }

    /// The live-gate failure after the first fix (v0.22.5): the retried
    /// answer's last chunk reached the transcript AFTER `promptComplete`
    /// (the chunk and the prompt reply race through separate paths). It
    /// reopened the streaming bubble; the rebuild dropped it, then the
    /// throttled flush put it back — so the stored answer (the old bubble's
    /// place) and a stray streaming copy showed together, with "Ready".
    @Test func lateChunkOfTheRetriedAnswerLeavesNoStrayBubble() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: """
            INSERT INTO sessions (id, source, started_at) VALUES ('s', 'acp', 1700000000);
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        vm.setSessionId("s")
        let bravo = "Reply with exactly: BRAVO"
        Self.run(vm, wire: bravo, reply: "BRAVO")
        try HermesV0215R18bTests.exec("""
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
                (1, 's', 'user', '\(bravo)', 1700000001, 1, 0),
                (2, 's', 'assistant', 'BRAVO', 1700000002, 1, 0);
            """, home: home)

        vm.addUserMessage(text: "/retry")
        vm.notePromptWire(displayText: "/retry", wireText: "/retry", imageCount: 0)
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "BRA"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.done))
        // Late, and close together: the second is held for the throttled flush.
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "V"))
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "O"))
        try HermesV0215R18bTests.exec("""
            UPDATE messages SET active = 0;
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
                (3, 's', 'user', '\(bravo)', 1700000003, 1, 0),
                (4, 's', 'assistant', 'BRAVO', 1700000004, 1, 0);
            """, home: home)

        #expect(await vm.followRewindFromDB(wireText: "/retry") == nil)
        try await Task.sleep(for: .milliseconds(300))  // any throttled flush
        #expect(Self.transcript(vm) == [bravo, "BRAVO"])
        #expect(vm.messages.allSatisfy { $0.id > 0 })
    }

    /// A `/queue C` sent while `/retry` ran is a real FIFO turn on gateway
    /// hosts, which Hermes starts as soon as `/retry` ends — so C may be
    /// streaming when the follow runs. Its buffered text must survive the
    /// rebuild so the next chunk redraws the whole reply.
    @Test func queuedTurnStreamingDuringTheFollowKeepsItsText() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: """
            INSERT INTO sessions (id, source, started_at) VALUES ('s', 'acp', 1700000000);
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        vm.setSessionId("s")
        let bravo = "Reply with exactly: BRAVO"
        Self.run(vm, wire: bravo, reply: "BRAVO")
        Self.run(vm, wire: "/retry", reply: "BRAVO!")
        // C was queued during /retry; Hermes starts it right after.
        vm.addUserMessage(text: "C")
        vm.notePromptWire(displayText: "C", wireText: "/queue C", imageCount: 0)
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "partial C answer"))
        try HermesV0215R18bTests.exec("""
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
                (1, 's', 'user', '\(bravo)', 1700000001, 0, 0),
                (2, 's', 'assistant', 'BRAVO', 1700000002, 0, 0),
                (3, 's', 'user', '\(bravo)', 1700000003, 1, 0),
                (4, 's', 'assistant', 'BRAVO!', 1700000004, 1, 0);
            """, home: home)

        #expect(await vm.followRewindFromDB(wireText: "/retry") == nil)
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: " more"))
        try await Task.sleep(for: .milliseconds(200))  // any throttled flush
        #expect(Self.transcript(vm) == [bravo, "BRAVO!", "C", "partial C answer more"])
    }

    /// A chunk handled WHILE the rebuild reads the database (a late chunk of
    /// the command's own reply) must not leave a stray bubble beside the
    /// stored answer: `discardStreamingRemnant` clears it.
    @Test func chunkDuringTheRebuildLeavesNoStrayBubble() async throws {
        let mock = MockHermesQueryBackend()
        let vm = RichChatViewModel(context: .local,
                                   dataService: HermesDataService(context: .local, backend: mock))
        vm.publishCapabilities(Self.caps("0.22.5"))
        vm.setSessionId("s")
        let bravo = "Reply with exactly: BRAVO"
        Self.run(vm, wire: bravo, reply: "BRAVO")
        Self.run(vm, wire: "/retry", reply: "BRAVO")
        let columns = ["id": 0, "session_id": 1, "role": 2, "content": 3, "tool_call_id": 4,
                       "tool_calls": 5, "tool_name": 6, "timestamp": 7, "token_count": 8, "finish_reason": 9]
        func row(_ id: Int, _ role: String, _ content: String) -> Row {
            Row(values: [.integer(Int64(id)), .text("s"), .text(role), .text(content), .null, .null, .null,
                         .real(1_700_000_000 + Double(id)), .null, role == "assistant" ? .text("stop") : .null],
                columnIndex: columns)
        }
        // Newest first: the data service reads DESC and reverses.
        await mock._seedRows(forSQLPrefix: "SELECT id, session_id, role", [row(4, "assistant", "BRAVO"), row(3, "user", bravo)])
        nonisolated(unsafe) let target = vm
        await mock.setOnQuery { sql in
            guard sql.hasPrefix("SELECT id, session_id, role") else { return }
            await MainActor.run {
                target.handleACPEvent(.messageChunk(sessionId: "s", text: "late"))
                target.handleACPEvent(.messageChunk(sessionId: "s", text: " chunk"))
            }
        }

        #expect(await vm.followRewindFromDB(wireText: "/retry") == nil)
        try await Task.sleep(for: .milliseconds(300))  // any throttled flush
        #expect(Self.transcript(vm) == [bravo, "BRAVO"])
        #expect(vm.messages.allSatisfy { $0.id > 0 })
    }

    /// A refused `/retry` (here: the last turn had an image) changes nothing
    /// in state.db and is answered as the turn's reply; the rebuild drops
    /// that bubble, so the refusal must come back as the hint.
    @Test func refusedRetryHandsBackTheRefusal() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        await vm.loadSessionHistory(sessionId: "s")
        let refusal = "/retry: the last message has an image and cannot be resent as text"
        Self.run(vm, wire: "/retry", reply: refusal)

        #expect(await vm.followRewindFromDB(wireText: "/retry") == refusal)
        #expect(Self.transcript(vm) == ["q1", "a1", "q2", "a2"])
    }

    /// `/undo` with nothing to undo: Hermes's reply is still the hint.
    @Test func undoWithNothingToUndoHandsBackTheReply() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: """
            INSERT INTO sessions (id, source, started_at) VALUES ('s', 'acp', 1700000000);
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        vm.setSessionId("s")
        Self.run(vm, wire: "/undo", reply: "No user message to undo.")

        #expect(await vm.followRewindFromDB(wireText: "/undo") == "No user message to undo.")
        #expect(Self.transcript(vm).isEmpty)
    }

    /// A prompt sent AFTER the command (`/queue C` while `/undo` streams)
    /// has no row yet; the follow must keep its echo and must not take its
    /// text as the command's reply.
    @Test func laterEchoWithNoRowSurvivesTheFollow() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        await vm.loadSessionHistory(sessionId: "s")
        vm.addUserMessage(text: "/undo")
        vm.notePromptWire(displayText: "/undo", wireText: "/undo", imageCount: 0)
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Undid 1 turn (2 message(s))."))
        vm.addUserMessage(text: "C")
        vm.notePromptWire(displayText: "C", wireText: "/queue C", imageCount: 0)
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.done))
        try HermesV0215R18bTests.exec("UPDATE messages SET active = 0 WHERE id >= 3;", home: home)

        let hint = await vm.followRewindFromDB(wireText: "/undo")
        #expect(hint == "Undid 1 turn (2 message(s)).")
        #expect(Self.transcript(vm) == ["q1", "a1", "C"])
    }

    /// A transport failure reads as zero rows; the follow (and the reconnect
    /// rebuild under it) must leave the transcript as it was, not blank it.
    @Test func failedFetchLeavesTheTranscriptUnchanged() async throws {
        let mock = MockHermesQueryBackend()
        let vm = RichChatViewModel(context: .local,
                                   dataService: HermesDataService(context: .local, backend: mock))
        vm.publishCapabilities(Self.caps("0.22.5"))
        vm.setSessionId("s")
        Self.run(vm, wire: "Reply with exactly: ALPHA", reply: "ALPHA")
        Self.run(vm, wire: "/undo", reply: "Undid 1 turn (2 message(s)).")
        await mock._seedFailure(forSQLPrefix: "SELECT id, session_id, role", error: .transport("ssh dropped"))
        let before = vm.messages.map { "\($0.id):\($0.role):\($0.content)" }
        #expect(before.count == 4)

        #expect(await vm.followRewindFromDB(wireText: "/undo") == nil)
        #expect(vm.messages.map { "\($0.id):\($0.role):\($0.content)" } == before)
        #expect(await vm.reconcileWithDB(sessionId: "s") == false)
        #expect(vm.messages.map { "\($0.id):\($0.role):\($0.content)" } == before)
    }

    /// Pre-v0.22.3 hosts never send it, and the follow is a no-op there (C1).
    @Test func followIsANoOpWhereHermesDoesNotServeRewind() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seed)
        defer { try? FileManager.default.removeItem(at: home) }
        for host in [HermesCapabilities.empty, Self.caps("0.22.1"), Self.caps("0.21.5")] {
            let vm = RichChatViewModel(context: .local(home: home))
            vm.publishCapabilities(host)
            await vm.loadSessionHistory(sessionId: "s")
            Self.run(vm, wire: "/undo", reply: "reply")
            let before = Self.transcript(vm)
            #expect(await vm.followRewindFromDB(wireText: "/undo") == nil)
            #expect(Self.transcript(vm) == before)
        }
        // And on a serving host, any other prompt is left alone.
        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.caps("0.22.5"))
        await vm.loadSessionHistory(sessionId: "s")
        Self.run(vm, wire: "hello", reply: "hi")
        #expect(await vm.followRewindFromDB(wireText: "hello") == nil)
        #expect(Self.transcript(vm) == ["q1", "a1", "q2", "a2", "hello", "hi"])
    }
}

#endif
