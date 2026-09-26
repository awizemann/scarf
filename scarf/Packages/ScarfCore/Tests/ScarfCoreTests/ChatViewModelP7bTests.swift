#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// P7b (t-409ec2da) — `RichChatViewModel` fixes shared by the Mac chat and
/// ScarfGo:
///  - `reconcileWithDB` keeps the pagination cursor consistent with the
///    rows it installs (no duplicated or skipped history on "Load
///    earlier"), and never installs rows into a transcript that moved on;
///  - a mid-turn user message finalizes the streaming bubble first;
///  - `openToolCallIds` is cleared at every turn end;
///  - a deliberately cancelled turn ends without a failure bubble/banner;
///  - `workingSince` for a turn found running in the DB is the prompt
///    row's time, stable across poll flicker.
///
/// DB-backed cases run against a throwaway `state.db` under a temp Hermes
/// home (`ServerContext.local(home:)`), never a real one.
@Suite struct ChatViewModelP7bTests {

    // MARK: - Fixture DB

    private static let baseTime = 1_700_000_000.0

    private final class Fixture {
        let home: URL
        let dbPath: String
        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("scarf-p7b-\(UUID().uuidString)", isDirectory: true)
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
            VALUES ('s', 'acp', \(ChatViewModelP7bTests.baseTime), 0, 0, 0, 0, 0, 0, 0);
            """)
        }

        func exec(_ sql: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                throw TransportError.other(message: "sqlite3_open_v2 failed")
            }
            defer { sqlite3_close(db) }
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw TransportError.other(message: "fixture SQL failed: \(msg)")
            }
        }

        /// `count` alternating user/assistant rows with ids 1...count and
        /// timestamps ascending with the id.
        func insertConversation(count: Int) throws {
            var sql = "BEGIN;"
            for id in 1...count {
                let role = id % 2 == 1 ? "user" : "assistant"
                let finish = role == "assistant" ? "'stop'" : "NULL"
                sql += "INSERT INTO messages (id, session_id, role, content, timestamp, finish_reason) VALUES (\(id), 's', '\(role)', 'row \(id)', \(ChatViewModelP7bTests.baseTime + Double(id)), \(finish));"
            }
            sql += "COMMIT;"
            try exec(sql)
        }

        var context: ServerContext { .local(home: home) }

        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    private static func dbIds(_ vm: RichChatViewModel) -> [Int] {
        vm.messages.map(\.id).filter { $0 > 0 }
    }

    // MARK: - (2) reconcileWithDB cursor

    /// The session opened with its 25-row window (ids 36...60); a reconnect
    /// reconciles the 200-row tail, which reaches ids 1...60. Pre-fix the
    /// cursor stayed at 36 with `hasMoreHistory` true, so "Load earlier"
    /// re-fetched ids 11...35 — rows the reconcile had already installed.
    @Test func reconcileWindowLargerThanTheOpenWindowMovesTheCursor() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.insertConversation(count: 60)
        let vm = RichChatViewModel(context: fx.context)
        await vm.loadSessionHistory(sessionId: "s")
        #expect(vm.oldestLoadedMessageID == 36)
        #expect(vm.hasMoreHistory)

        await vm.reconcileWithDB(sessionId: "s")
        #expect(Self.dbIds(vm) == Array(1...60))
        #expect(vm.oldestLoadedMessageID == 1)
        #expect(vm.hasMoreHistory == false)

        await vm.loadEarlier()
        let ids = Self.dbIds(vm)
        #expect(ids.count == Set(ids).count, "Load earlier duplicated rows the reconcile installed")
        #expect(ids == Array(1...60))
    }

    /// The user paged back to id 76 (window 276...300 + one 200-row page),
    /// then a reconnect reconciles the 200-row tail (101...300). Pre-fix
    /// ids 76...100 were dropped while the cursor stayed at 76 — a gap no
    /// later "Load earlier" ever re-fetches.
    @Test func reconcileKeepsHistoryPagedInBelowItsWindow() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.insertConversation(count: 300)
        let vm = RichChatViewModel(context: fx.context)
        await vm.loadSessionHistory(sessionId: "s")
        await vm.loadEarlier(pageSize: 200)
        #expect(vm.oldestLoadedMessageID == 76)
        #expect(vm.earlierHistoryCutoffId == 276)

        await vm.reconcileWithDB(sessionId: "s")
        #expect(Self.dbIds(vm) == Array(76...300), "reconcile dropped paged-in history")
        #expect(vm.oldestLoadedMessageID == 76)
        #expect(vm.hasMoreHistory)
        #expect(vm.earlierHistoryCutoffId == 276)

        await vm.loadEarlier(pageSize: 200)
        #expect(Self.dbIds(vm) == Array(1...300), "history skipped or duplicated after reconcile")
        #expect(vm.hasMoreHistory == false)
    }

    /// A reconcile for a session the transcript is no longer attached to
    /// must not install that session's rows.
    @Test func reconcileForADetachedSessionInstallsNothing() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.insertConversation(count: 10)
        let vm = RichChatViewModel(context: fx.context)
        vm.setSessionId("other")

        await vm.reconcileWithDB(sessionId: "s")
        #expect(vm.messages.isEmpty, "reconcile painted session s into a transcript attached to another session")
    }

    // MARK: - (7) workingSince on attach

    /// Attaching to a turn the DB shows running: the elapsed clock starts
    /// at the prompt row, not at attach — and a working → idle → working
    /// flicker between poll ticks doesn't restart it.
    @Test func workingSinceForARunningTurnIsThePromptRowAndSurvivesFlicker() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let promptTime = Date().addingTimeInterval(-300).timeIntervalSince1970
        try fx.exec("INSERT INTO messages (id, session_id, role, content, timestamp) VALUES (1, 's', 'user', 'go', \(promptTime));")
        let vm = RichChatViewModel(context: fx.context)
        vm.setSessionId("s")

        await vm.refreshMessages()
        #expect(vm.isAgentWorking)
        let seeded = try #require(vm.workingSince)
        #expect(abs(seeded.timeIntervalSince1970 - promptTime) < 1,
                "clock started at attach time, not at the prompt")

        // Flicker: an intermediate assistant row reads as idle…
        try fx.exec("INSERT INTO messages (id, session_id, role, content, timestamp, finish_reason) VALUES (2, 's', 'assistant', 'step', \(promptTime + 10), 'stop');")
        await vm.refreshMessages()
        #expect(vm.isAgentWorking == false)
        // …then the turn reads as running again.
        try fx.exec("INSERT INTO messages (id, session_id, role, content, timestamp) VALUES (3, 's', 'assistant', 'more', \(promptTime + 20));")
        await vm.refreshMessages()
        #expect(vm.isAgentWorking)
        let again = try #require(vm.workingSince)
        #expect(abs(again.timeIntervalSince1970 - promptTime) < 1, "poll flicker restarted the clock")
    }

    // MARK: - Event-driven helpers

    @MainActor
    private static func engagedVM() -> RichChatViewModel {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "go")
        return vm
    }

    private static func result(_ stopReason: String) -> ACPPromptResult {
        ACPPromptResult(stopReason: stopReason, inputTokens: 0, outputTokens: 0,
                        thoughtTokens: 0, cachedReadTokens: 0)
    }

    private static func toolStart(_ id: String) -> ACPEvent {
        .toolCallStart(sessionId: "s", call: ACPToolCallEvent(
            toolCallId: id, title: "terminal: ls", kind: "execute",
            status: "pending", content: "", rawInput: nil
        ))
    }

    private static func toolUpdate(_ id: String) -> ACPEvent {
        .toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: id, kind: "execute", status: "completed", content: "late output", rawOutput: nil
        ))
    }

    // MARK: - (3) mid-turn send

    /// `/steer` while a reply streams: the streamed text so far is
    /// finalized ahead of the steer message, and the turn's later text
    /// lands after it. Pre-fix the id-0 bubble was stranded with its
    /// buffers wiped, and the next chunk replaced "Partial answer".
    @Test @MainActor func midTurnSendFinalizesTheStreamingReplyFirst() {
        let vm = Self.engagedVM()
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Partial answer"))
        vm.addUserMessage(text: "/steer be brief")
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "More"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("end_turn")))

        let transcript = vm.messages.filter { $0.isUser || $0.isAssistant }.map(\.content)
        #expect(transcript == ["go", "Partial answer", "/steer be brief", "More"])
        #expect(!vm.messages.contains { $0.id == 0 }, "a streaming placeholder was left behind")
    }

    /// P9 (t-d6384e2e item 4): the mid-turn finalize above locks a still-
    /// OPEN tool call into a permanent message. Its later `tool_call_update`
    /// must patch that message by callId — pre-fix it only looked in the
    /// (now empty) streaming buffer, so the call kept no duration, no exit
    /// code and the "{}" argument placeholder forever.
    @Test @MainActor func lateUpdatePatchesACallFinalizedByAMidTurnSend() throws {
        let vm = Self.engagedVM()
        vm.handleACPEvent(Self.toolStart("tc-1"))
        vm.addUserMessage(text: "/steer be brief")
        vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: "tc-1", kind: "execute", status: "failed", content: "boom",
            rawOutput: nil, rawInput: ["command": "ls"]
        )))

        let owner = try #require(vm.messages.first { msg in
            msg.isAssistant && msg.toolCalls.contains { $0.callId == "tc-1" }
        })
        let call = try #require(owner.toolCalls.first { $0.callId == "tc-1" })
        #expect(call.exitCode == 1)
        #expect(call.duration != nil)
        #expect(call.arguments == #"{"command":"ls"}"#)
        // Still ahead of the steer message, and the result row still lands.
        let ownerIdx = try #require(vm.messages.firstIndex { $0.id == owner.id })
        let steerIdx = try #require(vm.messages.firstIndex { $0.content == "/steer be brief" })
        #expect(ownerIdx < steerIdx)
        #expect(vm.messages.contains { $0.role == "tool" && $0.toolCallId == "tc-1" })
    }

    // MARK: - (4) open tool calls end with the turn

    /// A tool call left open when its turn ended (no turn-end flush below
    /// v0.21.4) must not be closed by a late update during the NEXT turn:
    /// pre-fix that update finalized the new turn's streaming reply
    /// mid-stream and appended a stray tool row.
    @Test @MainActor func openToolCallDoesNotSurviveTheTurnEnd() {
        let vm = Self.engagedVM()
        vm.handleACPEvent(Self.toolStart("tc-1"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("end_turn")))

        vm.addUserMessage(text: "next")
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Hello "))
        vm.handleACPEvent(Self.toolUpdate("tc-1"))
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "there"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("end_turn")))

        #expect(!vm.messages.contains { $0.role == "tool" }, "a previous turn's late update appended a tool row")
        let replies = vm.messages.filter { $0.isAssistant && !$0.content.isEmpty }.map(\.content)
        #expect(replies.last == "Hello there", "the late update split the new turn's reply")
    }

    /// Same for a turn that ended with the connection.
    @Test @MainActor func openToolCallDoesNotSurviveADisconnect() {
        for disconnect in [0, 1] {
            let vm = Self.engagedVM()
            vm.handleACPEvent(Self.toolStart("tc-1"))
            if disconnect == 0 {
                vm.finalizeOnDisconnect()
            } else {
                vm.handleACPEvent(.connectionLost(reason: "gone"))
            }
            vm.addUserMessage(text: "next")
            vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Hello "))
            vm.handleACPEvent(Self.toolUpdate("tc-1"))
            #expect(!vm.messages.contains { $0.role == "tool" },
                    "path \(disconnect): a dead turn's update closed a call in the next turn")
        }
    }

    // MARK: - (6) deliberate cancel

    /// A barge-in cancel Scarf asked for ends quietly: no "ended without a
    /// response" bubble and no error banner.
    @Test @MainActor func requestedCancelEndsWithoutFailure() async {
        let vm = Self.engagedVM()
        vm.noteTurnCancelRequested()
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("cancelled")))
        try? await Task.sleep(nanoseconds: 100_000_000) // let a stray banner task run

        #expect(!vm.messages.contains { $0.role == "system" }, "deliberate cancel painted a failure bubble")
        #expect(vm.acpError == nil, "deliberate cancel raised an error banner")
        #expect(vm.isAgentWorking == false)
    }

    /// A cancel nobody asked for here (teardown's synthesized one) still
    /// says so in the transcript — but never as an error banner. And the
    /// marker belongs to one turn: it doesn't silence the next.
    @Test @MainActor func unrequestedCancelKeepsItsBubbleButNoBanner() async {
        let vm = Self.engagedVM()
        vm.noteTurnCancelRequested()
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("end_turn")))

        vm.addUserMessage(text: "again")
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("cancelled")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(vm.messages.contains { $0.role == "system" && $0.content.contains("cancelled") })
        #expect(vm.acpError == nil, "a cancel is not a failure — no banner")

        // Failures still raise the banner.
        vm.addUserMessage(text: "third")
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: Self.result("refusal")))
        let banner = await Self.waitUntil { vm.acpError != nil }
        #expect(banner)
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

#endif
