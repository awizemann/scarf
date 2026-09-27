#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// S02-F1 (Hermes v0.21.5 audit, R09) end to end: Scarf echoes a prompt,
/// the fixture stores the row EXACTLY as Hermes v2026.9.24 stores it for
/// that wire payload, then the chat is reopened (`reset` +
/// `loadSessionHistory`) or reconnected (`reconcileWithDB`). The
/// transcript must show the prompt once — never the typed echo beside
/// Hermes's row, never an orphan for a command Hermes stores no row for.
///
/// Stored strings were produced by the tagged tree's own functions
/// (`agent/session_persistence._durable_content`,
/// `agent/prompt_builder.steer_user_row`). Throwaway `state.db` under a
/// temp Hermes home, never a real one.
@Suite struct ChatEchoReconcileDBTests {

    private final class Fixture {
        let home: URL
        let dbPath: String
        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("scarf-r09-\(UUID().uuidString)", isDirectory: true)
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
            VALUES ('s', 'acp', 1700000000, 0, 0, 0, 0, 0, 0, 0);
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

        /// Insert a row the way Hermes would have stored it (bound, so any
        /// content survives quoting).
        func insert(id: Int, role: String, content: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                throw TransportError.other(message: "sqlite3_open_v2 failed")
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO messages (id, session_id, role, content, timestamp, finish_reason) VALUES (?, 's', ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TransportError.other(message: "prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_int64(stmt, 1, Int64(id))
            sqlite3_bind_text(stmt, 2, role, -1, transient)
            sqlite3_bind_text(stmt, 3, content, -1, transient)
            sqlite3_bind_double(stmt, 4, 1_700_000_000.0 + Double(id))
            if role == "assistant" {
                sqlite3_bind_text(stmt, 5, "stop", -1, transient)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw TransportError.other(message: "insert failed")
            }
        }

        var context: ServerContext { .local(home: home) }
        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    private static func userTexts(_ vm: RichChatViewModel) -> [String] {
        vm.messages.filter(\.isUser).map(\.content)
    }

    /// Echo `typed`, report the wire payload, let Hermes store `stored`
    /// (nil = no row), then switch away and back.
    @MainActor
    private static func sendThenReopen(
        typed: String, wire: String, images: Int = 0, stored: String?,
        capabilities: HermesCapabilities = .empty
    ) async throws -> [String] {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = RichChatViewModel(context: fx.context)
        vm.publishCapabilities(capabilities)
        await vm.loadSessionHistory(sessionId: "s")
        vm.addUserMessage(text: typed)
        vm.notePromptWire(displayText: typed, wireText: wire, imageCount: images)
        if let stored {
            try fx.insert(id: 1, role: "user", content: stored)
            try fx.insert(id: 2, role: "assistant", content: "reply")
        }
        vm.reset()
        await vm.loadSessionHistory(sessionId: "s")
        // A second reopen must not resurrect anything either.
        vm.reset()
        await vm.loadSessionHistory(sessionId: "s")
        return userTexts(vm)
    }

    @Test @MainActor func expandedScarfCommandShowsOnce() async throws {
        let texts = try await Self.sendThenReopen(
            typed: "/scarf-help",
            wire: "Explain what Scarf can do in this project.",
            stored: "Explain what Scarf can do in this project."
        )
        #expect(texts == ["Explain what Scarf can do in this project."])
    }

    @Test @MainActor func imagePromptShowsOnce() async throws {
        let texts = try await Self.sendThenReopen(
            typed: "look at this", wire: "look at this", images: 1,
            stored: "look at this\n[screenshot]"
        )
        #expect(texts == ["look at this\n[screenshot]"])
    }

    /// iOS echoes "[image attached]" for an image-only prompt.
    @Test @MainActor func imageOnlyPromptShowsOnce() async throws {
        let texts = try await Self.sendThenReopen(
            typed: "[image attached]", wire: "", images: 1, stored: "[screenshot]"
        )
        #expect(texts == ["[screenshot]"])
    }

    @Test @MainActor func idleQueueFallbackShowsOnce() async throws {
        let texts = try await Self.sendThenReopen(typed: "/queue foo", wire: "foo", stored: "foo")
        #expect(texts == ["foo"])
    }

    /// `/help` is answered by the adapter without a turn: no row, and its
    /// reply was never stored — the echo must not come back alone.
    @Test @MainActor func acpSlashCommandLeavesNoOrphan() async throws {
        let texts = try await Self.sendThenReopen(typed: "/help", wire: "/help", stored: nil)
        #expect(texts.isEmpty)
    }

    @Test @MainActor func midTurnSteerSettlesOnTheSteerRow() async throws {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")
        let marker = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]\nbe brief\n[/OUT-OF-BAND USER MESSAGE]"
        let texts = try await Self.sendThenReopen(
            typed: "/steer be brief", wire: "/steer be brief", stored: marker, capabilities: caps
        )
        #expect(texts == [marker])
    }

    /// Failure path: Hermes has not written the row yet — the echo must
    /// survive the reopen (issue #63), even though an OLDER row has the
    /// same text.
    @Test @MainActor func unpersistedResendSurvivesBesideAnOlderIdenticalRow() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.insert(id: 1, role: "user", content: "hi")
        try fx.insert(id: 2, role: "assistant", content: "hello")
        let vm = RichChatViewModel(context: fx.context)
        await vm.loadSessionHistory(sessionId: "s")
        vm.addUserMessage(text: "hi")
        vm.notePromptWire(displayText: "hi", wireText: "hi", imageCount: 0)
        vm.reset()
        await vm.loadSessionHistory(sessionId: "s")
        #expect(Self.userTexts(vm) == ["hi", "hi"])
        // Hermes catches up: exactly one of each now.
        try fx.insert(id: 3, role: "user", content: "hi")
        vm.reset()
        await vm.loadSessionHistory(sessionId: "s")
        #expect(Self.userTexts(vm) == ["hi", "hi"])
        #expect(vm.messages.filter(\.isUser).allSatisfy { $0.id > 0 })
    }

    /// Reconnect path: the live transcript still holds the typed echo;
    /// `reconcileWithDB` must replace it with Hermes's row, not keep both.
    @Test @MainActor func reconnectReconcileKeepsOneBubble() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = RichChatViewModel(context: fx.context)
        await vm.loadSessionHistory(sessionId: "s")
        vm.addUserMessage(text: "/scarf-help")
        vm.notePromptWire(displayText: "/scarf-help", wireText: "Expanded body.", imageCount: 0)
        vm.addUserMessage(text: "/help")
        vm.notePromptWire(displayText: "/help", wireText: "/help", imageCount: 0)
        try fx.insert(id: 1, role: "user", content: "Expanded body.")
        try fx.insert(id: 2, role: "assistant", content: "reply")
        await vm.reconcileWithDB(sessionId: "s")
        #expect(Self.userTexts(vm) == ["Expanded body."])
        // The settled echoes left the pending cache too.
        vm.reset()
        await vm.loadSessionHistory(sessionId: "s")
        #expect(Self.userTexts(vm) == ["Expanded body."])
    }

    /// Autostart (typing into a blank Chat screen): the echo is made while
    /// the chat has no session id, so nothing is cached; the wire note must
    /// adopt it once the id is set, or a reconnect keeps it beside the row.
    @Test @MainActor func autostartEchoIsAdoptedByTheWireNote() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = RichChatViewModel(context: fx.context)
        vm.addUserMessage(text: "/scarf-help")
        vm.setSessionId("s")
        vm.notePromptWire(displayText: "/scarf-help", wireText: "Expanded body.", imageCount: 0)
        try fx.insert(id: 1, role: "user", content: "Expanded body.")
        await vm.reconcileWithDB(sessionId: "s")
        #expect(Self.userTexts(vm) == ["Expanded body."])
    }

    /// Autostart whose `session/load` fell back to a NEW session: the echo
    /// was cached under the old id and must move, not be re-injected into
    /// the old session on its next open.
    @Test @MainActor func autostartFallbackMovesTheEchoToTheNewSession() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.exec("""
        INSERT INTO sessions (id, source, started_at, message_count, tool_call_count, input_tokens,
            output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd)
        VALUES ('old', 'acp', 1700000000, 0, 0, 0, 0, 0, 0, 0);
        """)
        let vm = RichChatViewModel(context: fx.context)
        vm.setSessionId("old")
        vm.addUserMessage(text: "hello there")
        vm.setSessionId("s")
        vm.notePromptWire(displayText: "hello there", wireText: "hello there", imageCount: 0)
        vm.reset()
        await vm.loadSessionHistory(sessionId: "old")
        #expect(Self.userTexts(vm).isEmpty, "echo re-injected into the session it was never sent to")
        vm.reset()
        await vm.loadSessionHistory(sessionId: "s")
        #expect(Self.userTexts(vm) == ["hello there"], "unpersisted echo lost from its real session")
    }
}

#endif
