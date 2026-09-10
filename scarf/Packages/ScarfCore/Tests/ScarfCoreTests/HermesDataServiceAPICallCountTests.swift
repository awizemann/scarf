#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// `sessions.api_call_count` must be resolved by column NAME, not by a
/// hardcoded index (whole-surface audit, P14).
///
/// `HermesDataService.sessionColumns` appends the v0.7 block
/// (`reasoning_tokens, actual_cost_usd, cost_status, billing_provider`) only
/// when that schema is present, and `api_call_count` after it. The old
/// `row.int(at: 20)` read assumed BOTH blocks were present, so a host with
/// `api_call_count` but no `reasoning_tokens` — Hermes adds columns without
/// bumping `SCHEMA_VERSION` (charter C4), and the two probes are independent
/// PRAGMA checks — read index 20 off a 17-column row and silently reported 0.
///
/// The fixture below is exactly that shape: v0.11 column present, v0.7
/// columns absent. `api_call_count` then sits at index 16, not 20.
@Suite struct HermesDataServiceAPICallCountTests {

    /// `<tempHome>/state.db` with `api_call_count` but WITHOUT the v0.7
    /// columns, so the two schema probes disagree.
    private func makeFixtureHome(addV07: Bool) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-apicount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dbPath = home.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        let v07Columns = addV07
            ? ", reasoning_tokens INTEGER, actual_cost_usd REAL, cost_status TEXT, billing_provider TEXT"
            : ""
        let v07Names = addV07 ? ", reasoning_tokens, actual_cost_usd, cost_status, billing_provider" : ""
        let v07Values = addV07 ? ", 7, 0.5, 'final', 'anthropic'" : ""

        let schema = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
            parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
            message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
            output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
            estimated_cost_usd REAL\(v07Columns),
            api_call_count INTEGER
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
            tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
            token_count INTEGER, finish_reason TEXT, reasoning TEXT,
            reasoning_content TEXT, active INTEGER NOT NULL DEFAULT 1,
            compacted INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO sessions (
            id, source, started_at, message_count, tool_call_count,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
            estimated_cost_usd\(v07Names), api_call_count
        ) VALUES ('s1', 'acp', 1700000000.0, 2, 0, 10, 10, 0, 0, 0.01\(v07Values), 42);
        """

        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, schema, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture schema failed: \(msg)")
        }
        return home
    }

    private func cleanup(_ home: URL) {
        try? FileManager.default.removeItem(at: home)
    }

    @Test func apiCallCountResolvesWithoutTheV07Block() async throws {
        // The regression case: index 20 does not exist on this row shape,
        // and `Row.int(at:)` is bounds-safe, so the old code returned 0.
        let home = try makeFixtureHome(addV07: false)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let session = try #require(await service.fetchSessions().first)
        #expect(session.id == "s1")
        #expect(session.apiCallCount == 42)
    }

    @Test func apiCallCountStillResolvesWithTheV07Block() async throws {
        // The shape the hardcoded index happened to be right for — must
        // stay right after the by-name fix.
        let home = try makeFixtureHome(addV07: true)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let session = try #require(await service.fetchSessions().first)
        #expect(session.apiCallCount == 42)
    }
}

#endif
