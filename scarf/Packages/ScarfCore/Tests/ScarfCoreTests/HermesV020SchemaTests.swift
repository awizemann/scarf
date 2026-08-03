#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Hermes v0.20 schema additions (SCHEMA_VERSION 25): sessions gains
/// `pinned`, `last_activity_at`, `last_activity_description`; new
/// `session_model_usage` table. All additive — these tests pin down
/// (a) detection on both local fixture DBs and the façade flags,
/// (b) query gating (new columns/table only referenced when present),
/// (c) byte-identical pre-0.20 behaviour when they're absent.
@Suite struct HermesV020SchemaTests {

    // MARK: - Fixture DB

    /// Build an isolated `<tempHome>/state.db` fixture. Base shape
    /// matches the modern (v0.16/v0.18) schema; `addV020` layers on
    /// the v0.20 sessions columns + `session_model_usage` table.
    private func makeFixtureHome(addV020: Bool, partialV020: Bool = false) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-v020-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dbPath = home.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        var sessionsExtra = """
        , reasoning_tokens INTEGER, actual_cost_usd REAL, cost_status TEXT, billing_provider TEXT,
          api_call_count INTEGER, rewind_count INTEGER NOT NULL DEFAULT 0
        """
        if addV020 {
            sessionsExtra += ", pinned INTEGER NOT NULL DEFAULT 0, last_activity_at REAL, last_activity_description TEXT"
        } else if partialV020 {
            // Partially-migrated DB: `pinned` only. Detection must
            // stay false (belt-and-braces).
            sessionsExtra += ", pinned INTEGER NOT NULL DEFAULT 0"
        }
        var schema = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
            parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
            message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
            output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
            estimated_cost_usd REAL\(sessionsExtra)
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
            tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
            token_count INTEGER, finish_reason TEXT, reasoning TEXT,
            reasoning_content TEXT, active INTEGER NOT NULL DEFAULT 1,
            compacted INTEGER NOT NULL DEFAULT 0
        );
        """
        if addV020 {
            schema += """
            CREATE TABLE session_model_usage (
                session_id TEXT NOT NULL, model TEXT NOT NULL,
                billing_provider TEXT NOT NULL DEFAULT '', billing_base_url TEXT NOT NULL DEFAULT '',
                billing_mode TEXT NOT NULL DEFAULT '', task TEXT NOT NULL DEFAULT '',
                api_call_count INTEGER NOT NULL DEFAULT 0,
                input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0, cache_write_tokens INTEGER NOT NULL DEFAULT 0,
                reasoning_tokens INTEGER NOT NULL DEFAULT 0,
                estimated_cost_usd REAL NOT NULL DEFAULT 0, actual_cost_usd REAL NOT NULL DEFAULT 0,
                cost_status TEXT, cost_source TEXT, first_seen REAL, last_seen REAL,
                PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task)
            );
            INSERT INTO session_model_usage (session_id, model, api_call_count, input_tokens, output_tokens, reasoning_tokens, estimated_cost_usd, actual_cost_usd)
            VALUES ('s1', 'claude-fable-5', 3, 1000, 500, 100, 0.10, 0.12),
                   ('s2', 'claude-fable-5', 2, 500, 250, 0, 0.05, 0.0),
                   ('s2', 'gpt-5', 1, 200, 100, 0, 0.02, 0.0);
            INSERT INTO sessions (id, source, started_at, message_count, tool_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd, pinned, last_activity_at, last_activity_description)
            VALUES ('s1', 'acp', 1700000000.0, 5, 2, 100, 200, 0, 0, 0.05, 0, 1700000500.0, 'Editing HermesDataService.swift'),
                   ('s2', 'acp', 1700000100.0, 3, 1, 50, 80, 0, 0, 0.02, 1, NULL, NULL);
            """
        } else {
            schema += """
            INSERT INTO sessions (id, source, started_at, message_count, tool_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd)
            VALUES ('s1', 'acp', 1700000000.0, 5, 2, 100, 200, 0, 0, 0.05),
                   ('s2', 'acp', 1700000100.0, 3, 1, 50, 80, 0, 0, 0.02);
            """
        }
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

    // MARK: - Local backend detection

    @Test func localBackendDetectsV020SchemaWhenPresent() async throws {
        let home = try makeFixtureHome(addV020: true)
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasSessionActivityColumns)
        #expect(await backend.hasSessionModelUsageTable)
        await backend.close()
    }

    @Test func localBackendReportsAbsentV020SchemaOnOlderDB() async throws {
        let home = try makeFixtureHome(addV020: false)
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasSessionActivityColumns == false)
        #expect(await backend.hasSessionModelUsageTable == false)
        // Pre-existing detection unaffected.
        #expect(await backend.hasV07Schema)
        #expect(await backend.hasRewindCountColumn)
        await backend.close()
    }

    @Test func partiallyMigratedSessionsTableStaysOnOldShape() async throws {
        let home = try makeFixtureHome(addV020: false, partialV020: true)
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        // `pinned` alone must NOT flip the flag.
        #expect(await backend.hasSessionActivityColumns == false)
        await backend.close()
    }

    // MARK: - End-to-end through the façade (local fixture)

    @Test func fetchSessionsSurfacesPinnedAndLastActivity() async throws {
        let home = try makeFixtureHome(addV020: true)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let sessions = await service.fetchSessions()
        #expect(sessions.count == 2)
        let s1 = try #require(sessions.first { $0.id == "s1" })
        let s2 = try #require(sessions.first { $0.id == "s2" })
        #expect(s1.pinned == false)
        #expect(s1.lastActivityAt?.timeIntervalSince1970 == 1_700_000_500.0)
        #expect(s1.lastActivityDescription == "Editing HermesDataService.swift")
        #expect(s2.pinned == true)
        #expect(s2.lastActivityAt == nil)
        #expect(s2.lastActivityDescription == nil)
        await service.close()
    }

    @Test func fetchSessionsOnOlderDBYieldsDefaults() async throws {
        let home = try makeFixtureHome(addV020: false)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let sessions = await service.fetchSessions()
        #expect(sessions.count == 2)
        for s in sessions {
            #expect(s.pinned == false)
            #expect(s.lastActivityAt == nil)
            #expect(s.lastActivityDescription == nil)
        }
        await service.close()
    }

    @Test func dashboardSnapshotAggregatesModelUsageWhenTablePresent() async throws {
        let home = try makeFixtureHome(addV020: true)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let snapshot = await service.dashboardSnapshot()
        #expect(snapshot.modelUsage.count == 2)
        let fable = try #require(snapshot.modelUsage.first { $0.model == "claude-fable-5" })
        // Aggregated across s1 + s2 rows.
        #expect(fable.inputTokens == 1500)
        #expect(fable.outputTokens == 750)
        #expect(fable.reasoningTokens == 100)
        #expect(fable.apiCallCount == 5)
        #expect(abs(fable.estimatedCostUSD - 0.15) < 0.0001)
        #expect(abs(fable.actualCostUSD - 0.12) < 0.0001)
        let gpt = try #require(snapshot.modelUsage.first { $0.model == "gpt-5" })
        #expect(gpt.inputTokens == 200)
        // Cost-ordered: the pricier model first.
        #expect(snapshot.modelUsage.first?.model == "claude-fable-5")
        await service.close()
    }

    @Test func dashboardSnapshotOnOlderDBHasEmptyModelUsage() async throws {
        let home = try makeFixtureHome(addV020: false)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let snapshot = await service.dashboardSnapshot()
        #expect(snapshot.modelUsage.isEmpty)
        // The rest of the snapshot is unaffected.
        #expect(snapshot.stats.totalSessions == 2)
        await service.close()
    }

    // MARK: - Query gating (mock backend — assert the emitted SQL)

    @Test func sessionSelectOmitsV020ColumnsWhenAbsent() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(!sql.contains("pinned"))
        #expect(!sql.contains("last_activity_at"))
        #expect(!sql.contains("last_activity_description"))
    }

    @Test func sessionSelectIncludesV020ColumnsWhenPresent() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasSessionActivityColumns(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains("pinned"))
        #expect(sql.contains("last_activity_at"))
        #expect(sql.contains("last_activity_description"))
    }

    @Test func dashboardBatchShapeIsUnchangedWithoutUsageTable() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.dashboardSnapshot()
        let batch = try #require(await mock.batchLog.last)
        // Byte-identical pre-0.20 shape: exactly the four legacy
        // statements, none touching session_model_usage.
        #expect(batch.count == 4)
        #expect(!batch.contains { $0.sql.contains("session_model_usage") })
    }

    @Test func dashboardBatchAppendsUsageQueryWhenTablePresent() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasSessionModelUsageTable(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.dashboardSnapshot()
        let batch = try #require(await mock.batchLog.last)
        // One extra statement in the SAME batch — no added round-trip.
        #expect(batch.count == 5)
        #expect(batch.last?.sql.contains("session_model_usage") == true)
        #expect(batch.last?.sql.contains("GROUP BY model") == true)
        // Still exactly one queryBatch call and zero standalone queries.
        #expect(await mock.batchLog.count == 1)
        #expect(await mock.queryLog.isEmpty)
    }
}

#endif // canImport(SQLite3)
