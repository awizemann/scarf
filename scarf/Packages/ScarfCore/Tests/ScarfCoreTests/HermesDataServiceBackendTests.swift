#if canImport(SQLite3)

import Testing
import Foundation
@testable import ScarfCore

/// Exercises the `HermesDataService` façade against a `MockHermesQueryBackend`
/// via the `internal init(context:backend:)` test seam. Focus is the SQL
/// the façade emits + how it consumes the rows that come back.
@Suite struct HermesDataServiceBackendTests {

    // MARK: - Helpers

    /// Build a `Row` from `(name, value)` pairs in column order.
    /// Mirrors the shape `LocalSQLiteBackend.executeOne` produces.
    private func makeRow(_ pairs: [(String, SQLValue)]) -> Row {
        var values: [SQLValue] = []
        var columnIndex: [String: Int] = [:]
        values.reserveCapacity(pairs.count)
        for (i, pair) in pairs.enumerated() {
            values.append(pair.1)
            columnIndex[pair.0] = i
        }
        return Row(values: values, columnIndex: columnIndex)
    }

    /// Default 16-column session row matching `sessionColumns` for
    /// the bare base schema. Uses `.text("s1")` for id by default.
    private func makeBaseSessionRow(id: String = "s1") -> Row {
        makeRow([
            ("id", .text(id)),
            ("source", .text("acp")),
            ("user_id", .null),
            ("model", .text("gpt-5")),
            ("title", .text("hello")),
            ("parent_session_id", .null),
            ("started_at", .real(1_700_000_000.0)),
            ("ended_at", .null),
            ("end_reason", .null),
            ("message_count", .integer(5)),
            ("tool_call_count", .integer(2)),
            ("input_tokens", .integer(100)),
            ("output_tokens", .integer(200)),
            ("cache_read_tokens", .integer(0)),
            ("cache_write_tokens", .integer(0)),
            ("estimated_cost_usd", .real(0.05))
        ])
    }

    /// 10-column message row matching `messageColumns` for the bare base schema.
    private func makeBaseMessageRow(id: Int, sessionId: String = "s1", timestamp: Double = 1_700_000_001.0) -> Row {
        makeRow([
            ("id", .integer(Int64(id))),
            ("session_id", .text(sessionId)),
            ("role", .text("user")),
            ("content", .text("hi #\(id)")),
            ("tool_call_id", .null),
            ("tool_calls", .null),
            ("tool_name", .null),
            ("timestamp", .real(timestamp)),
            ("token_count", .integer(10)),
            ("finish_reason", .null)
        ])
    }

    /// Use a real `ServerContext.local` so the data service has a
    /// transport to construct (it's never used by these tests — every
    /// I/O path goes through the injected backend).
    private let context: ServerContext = .local

    // MARK: - fetchSessions

    @Test func fetchSessionsEmitsExpectedSQLPrefixAndDefaultLimit() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchSessions()

        let log = await mock.queryLog
        #expect(log.count == 1)
        let first = log[0]
        #expect(first.sql.hasPrefix("SELECT id, source"))
        #expect(first.sql.contains("FROM sessions WHERE parent_session_id IS NULL ORDER BY"))
        #expect(first.sql.contains("MAX(m.timestamp)"))
        #expect(first.sql.contains("ORDER BY"))
        #expect(first.sql.contains("DESC, started_at DESC LIMIT ?"))
        // QueryDefaults.sessionLimit == 100.
        #expect(first.params == [.integer(100)])
    }

    @Test func fetchSessionsBareSchemaUsesBaseColumnList() async {
        let mock = MockHermesQueryBackend()
        // Both schema flags off — neither v0.7 nor v0.11 columns selected.
        await mock.setHasV07Schema(false)
        await mock.setHasV011Schema(false)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()
        _ = await service.fetchSessions()

        let sql = await mock.queryLog[0].sql
        #expect(!sql.contains("reasoning_tokens"))
        #expect(!sql.contains("api_call_count"))
        // Sanity: base columns are still all there.
        #expect(sql.contains("estimated_cost_usd"))
    }

    @Test func fetchSessionsWithV07SchemaIncludesReasoningTokens() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasV07Schema(true)
        await mock.setHasV011Schema(false)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()
        _ = await service.fetchSessions()

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("reasoning_tokens"))
        #expect(sql.contains("actual_cost_usd"))
        #expect(sql.contains("cost_status"))
        #expect(sql.contains("billing_provider"))
        #expect(!sql.contains("api_call_count"))
    }

    @Test func fetchSessionsWithV011SchemaIncludesApiCallCount() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasV07Schema(true)
        await mock.setHasV011Schema(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()
        _ = await service.fetchSessions()

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("reasoning_tokens"))
        #expect(sql.contains("api_call_count"))
    }

    // MARK: - fetchSession(id:)

    @Test func fetchSessionByIdBindsTextParam() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        await mock._seedRow(
            forSQLPrefix: "SELECT id, source",
            columns: makeBaseSessionRow().columnIndex,
            values: makeBaseSessionRow().values
        )

        let session = await service.fetchSession(id: "abc-123")
        #expect(session?.id == "s1") // From the seeded row.

        let log = await mock.queryLog
        #expect(log.count == 1)
        #expect(log[0].sql.contains("FROM sessions WHERE id = ? LIMIT 1"))
        #expect(log[0].params == [.text("abc-123")])
    }

    // MARK: - fetchMessages

    @Test func fetchMessagesWithoutBeforeBindsSessionAndLimit() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchMessages(sessionId: "s1", limit: 25, before: nil)

        let log = await mock.queryLog
        #expect(log.count == 1)
        #expect(!log[0].sql.contains("id < ?"))
        #expect(log[0].sql.contains("WHERE session_id = ? ORDER BY id DESC LIMIT ?"))
        #expect(log[0].params == [.text("s1"), .integer(25)])
    }

    @Test func fetchMessagesWithBeforeIncludesIdLessThanClause() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchMessages(sessionId: "s1", limit: 25, before: 999)

        let log = await mock.queryLog
        #expect(log.count == 1)
        #expect(log[0].sql.contains("WHERE session_id = ? AND id < ? ORDER BY id DESC LIMIT ?"))
        #expect(log[0].params == [.text("s1"), .integer(999), .integer(25)])
    }

    @Test func fetchMessagesReversesDescResultsToChronological() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        // Backend returns DESC (newest first); service should reverse to
        // chronological (oldest first) for display.
        let row3 = makeBaseMessageRow(id: 3, timestamp: 1_700_000_003.0)
        let row2 = makeBaseMessageRow(id: 2, timestamp: 1_700_000_002.0)
        let row1 = makeBaseMessageRow(id: 1, timestamp: 1_700_000_001.0)
        await mock._seedRows(forSQLPrefix: "SELECT id, session_id", [row3, row2, row1])

        let result = await service.fetchMessages(sessionId: "s1", limit: 10, before: nil)
        #expect(result.count == 3)
        #expect(result.map { $0.id } == [1, 2, 3])
    }

    // MARK: - dashboardSnapshot

    @Test func dashboardSnapshotUsesQueryBatchNotIndividualQueries() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.dashboardSnapshot()

        let queries = await mock.queryLog
        let batches = await mock.batchLog
        #expect(queries.isEmpty)
        #expect(batches.count == 1)
        #expect(batches[0].count == 4)
    }

    @Test func dashboardSnapshotBatchOrderIsStatsRecentSessionsPreviewsToolCalls() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.dashboardSnapshot()

        let batches = await mock.batchLog
        #expect(batches.count == 1)
        let stmts = batches[0]
        // 0: stats — selects COUNT(*), SUM(...) from sessions.
        #expect(stmts[0].sql.contains("COUNT(*)"))
        #expect(stmts[0].sql.contains("FROM sessions"))
        // 1: recent sessions — selects session columns with a LIMIT param.
        #expect(stmts[1].sql.hasPrefix("SELECT id, source"))
        #expect(stmts[1].sql.contains("MAX(m.timestamp)"))
        #expect(stmts[1].sql.contains("DESC, started_at DESC LIMIT ?"))
        // 2: session previews — joins messages with latest user/assistant message.
        #expect(stmts[2].sql.contains("INNER JOIN"))
        #expect(stmts[2].sql.contains("MAX(id)"))
        #expect(stmts[2].sql.contains("role IN ('user', 'assistant')"))
        #expect(!stmts[2].sql.contains("MIN(id)"))
        // 3: recent tool calls — selects messages WHERE tool_calls IS NOT NULL.
        #expect(stmts[3].sql.contains("WHERE tool_calls IS NOT NULL"))
    }

    @Test func dashboardSnapshotAssemblesDataFromFourResultSets() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        // Stats row (6 cols on bare schema).
        let statsRow = makeRow([
            ("c0", .integer(7)),  // totalSessions
            ("c1", .integer(50)), // totalMessages
            ("c2", .integer(12)), // totalToolCalls
            ("c3", .integer(1000)), // totalInputTokens
            ("c4", .integer(2000)), // totalOutputTokens
            ("c5", .real(1.25))   // totalCostUSD
        ])
        await mock._seedRow(forSQLPrefix: "SELECT COUNT(*),", columns: statsRow.columnIndex, values: statsRow.values)

        // Recent sessions: one base session row.
        await mock._seedRows(forSQLPrefix: "SELECT id, source", [makeBaseSessionRow(id: "sess-A")])

        // Previews: two-column rows (session_id, content slice).
        let p1 = makeRow([("session_id", .text("sess-A")), ("preview", .text("first user msg"))])
        await mock._seedRows(forSQLPrefix: "SELECT m.session_id", [p1])

        // Recent tool calls: one message row with non-empty tool_calls.
        var toolRow = makeBaseMessageRow(id: 99, sessionId: "sess-A")
        // Manually rewrite tool_calls column (idx 5) to non-null/non-empty.
        let toolRowValues: [SQLValue] = [
            .integer(99), .text("sess-A"), .text("assistant"), .text("Calling tool"),
            .null, .text("[{\"id\":\"t1\",\"name\":\"bash\"}]"), .text("bash"),
            .real(1_700_000_010.0), .integer(15), .text("stop")
        ]
        toolRow = Row(values: toolRowValues, columnIndex: toolRow.columnIndex)
        // Both `fetchRecentToolCalls` and the dashboard batch slot start
        // with the same `messageColumns` prefix; match on a shorter
        // common substring that's whitespace-stable across the two
        // SQL builders.
        await mock._seedRows(forSQLPrefix: "SELECT id, session_id, role, content, tool_call_id, tool_calls,\ntool_name", [toolRow])

        let snapshot = await service.dashboardSnapshot()
        #expect(snapshot.stats.totalSessions == 7)
        #expect(snapshot.stats.totalMessages == 50)
        #expect(snapshot.recentSessions.map { $0.id } == ["sess-A"])
        #expect(snapshot.sessionPreviews["sess-A"] == "first user msg")
        #expect(snapshot.recentToolCalls.count == 1)
        #expect(snapshot.recentToolCalls[0].id == 99)
    }

    // MARK: - searchMessages

    @Test func searchMessagesEmptyInputReturnsEmptyAndSkipsBackend() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        let result = await service.searchMessages(query: "   ")
        #expect(result.isEmpty)

        let log = await mock.queryLog
        #expect(log.isEmpty)
    }

    @Test func searchMessagesWrapsTokensInDoubleQuotes() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.searchMessages(query: "config.yaml v0.7.0")

        let log = await mock.queryLog
        #expect(log.count == 1)
        // FTS query is the first param.
        guard case .text(let fts) = log[0].params[0] else {
            Issue.record("Expected first FTS search param to be .text")
            return
        }
        // Each whitespace-delimited token gets wrapped in double-quotes
        // and joined with spaces.
        #expect(fts == "\"config.yaml\" \"v0.7.0\"")
    }

    // MARK: - Error swallowing

    @Test func fetchSessionsReturnsEmptyOnBackendTransportError() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()
        await mock._seedFailure(forSQLPrefix: "SELECT id, source", error: .transport("ssh dropped"))

        let result = await service.fetchSessions()
        #expect(result.isEmpty)

        // Sanity: the error reached the backend (the call was made).
        let log = await mock.queryLog
        #expect(log.count == 1)
    }
}

#endif // canImport(SQLite3)
