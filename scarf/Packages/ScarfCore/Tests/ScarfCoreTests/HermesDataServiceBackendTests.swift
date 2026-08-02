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
        #expect(first.sql.contains("FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT ?"))
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

    @Test func fetchSessionsWithRewindCountColumnIncludesRewindCount() async {
        // v0.16+ DBs have the sessions.rewind_count column; the SELECT
        // must append it so sessionFromRow can read it.
        let mock = MockHermesQueryBackend()
        await mock.setHasRewindCountColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()
        _ = await service.fetchSessions()

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("rewind_count"))
    }

    @Test func fetchSessionsWithoutRewindCountColumnOmitsRewindCount() async {
        // Pre-v0.16 DBs lack the column; the SELECT must NOT reference it
        // or the query fails with "no such column".
        let mock = MockHermesQueryBackend()
        await mock.setHasRewindCountColumn(false)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()
        _ = await service.fetchSessions()

        let sql = await mock.queryLog[0].sql
        #expect(!sql.contains("rewind_count"))
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

    // MARK: - fetchSkeletonMessages (t-aud01 regression)

    @Test func fetchSkeletonMessagesSelectsReasoningButExcludesReasoningContent() async {
        // Regression (t-aud01): the v2.8 skeleton loader used to emit
        // `NULL AS reasoning`, which hid the REASONING disclosure on
        // every resumed thinking-model chat. It must now select the real
        // `reasoning` column (matching messageColumnsLight) while still
        // NULLing `tool_calls` and excluding the heavy `reasoning_content`.
        let mock = MockHermesQueryBackend()
        await mock.setHasV07Schema(true)
        await mock.setHasV011Schema(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchSkeletonMessages(sessionId: "s1", limit: 200)

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("NULL AS tool_calls"))        // tool_calls still NULLed
        #expect(sql.contains(", reasoning,"))              // real reasoning column selected, not NULLed (t-aud01)
        // t-aud27: the heavy reasoning_content BLOB is still NOT fetched — we
        // select a NULL placeholder (keeps index 11 == reasoning_content) plus a
        // cheap `hasReasoningContent` boolean so the disclosure can render on
        // resume for reasoning_content-only messages.
        #expect(sql.contains("NULL AS reasoning_content")) // blob not fetched (placeholder)
        #expect(sql.contains("hasReasoningContent"))       // cheap availability boolean
        #expect(sql.contains("role IN ('user','assistant')"))
    }

    @Test func fetchSkeletonMessagesBareSchemaOmitsReasoningContentFlag() async {
        // No v0.11 schema → no reasoning_content column exists, so neither the
        // placeholder nor the availability boolean may be referenced (it would
        // be a "no such column" SQL error).
        let mock = MockHermesQueryBackend()
        await mock.setHasV07Schema(true)
        await mock.setHasV011Schema(false)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchSkeletonMessages(sessionId: "s1", limit: 200)

        let sql = await mock.queryLog[0].sql
        #expect(!sql.contains("reasoning_content"))    // column doesn't exist pre-v0.11
        #expect(!sql.contains("hasReasoningContent"))
        #expect(sql.contains(", reasoning"))           // legacy reasoning still selected (last column here, no trailing comma)
    }

    // MARK: - reasoning_content availability flag (t-aud27)

    @Test func fetchMessagesLightAddsReasoningContentAvailabilityFlag() async {
        // The light fetch must NOT pull the heavy reasoning_content blob, but it
        // SHOULD select the cheap `hasReasoningContent` boolean so the REASONING
        // disclosure shows on resume for reasoning_content-only messages.
        let mock = MockHermesQueryBackend()
        await mock.setHasV07Schema(true)
        await mock.setHasV011Schema(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchMessages(sessionId: "s1", limit: 10, before: nil)

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("NULL AS reasoning_content")) // blob excluded (placeholder)
        #expect(sql.contains("hasReasoningContent"))       // availability flag present
    }

    @Test func messageFromRowSurfacesReasoningContentAvailability() async {
        // A reasoning_content-only row (legacy `reasoning` NULL, blob not loaded,
        // `hasReasoningContent` = 1) must parse to a message whose `hasReasoning`
        // is true via `reasoningContentAvailable` — so the disclosure renders and
        // t-aud21's on-open lazy fetch has something to trigger. (t-aud27)
        let mock = MockHermesQueryBackend()
        await mock.setHasV07Schema(true)
        await mock.setHasV011Schema(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        let available = makeRow([
            ("id", .integer(7)), ("session_id", .text("s1")), ("role", .text("assistant")),
            ("content", .text("answer")), ("tool_call_id", .null), ("tool_calls", .null),
            ("tool_name", .null), ("timestamp", .real(1_700_000_005.0)), ("token_count", .integer(20)),
            ("finish_reason", .text("stop")),
            ("reasoning", .null),               // index 10 — v0.16 thinking model leaves this NULL
            ("reasoning_content", .null),       // index 11 — light/skeleton placeholder (blob not loaded)
            ("hasReasoningContent", .integer(1)) // cheap flag: blob EXISTS on disk
        ])
        let notAvailable = makeRow([
            ("id", .integer(8)), ("session_id", .text("s1")), ("role", .text("assistant")),
            ("content", .text("plain")), ("tool_call_id", .null), ("tool_calls", .null),
            ("tool_name", .null), ("timestamp", .real(1_700_000_006.0)), ("token_count", .integer(5)),
            ("finish_reason", .text("stop")),
            ("reasoning", .null), ("reasoning_content", .null), ("hasReasoningContent", .integer(0))
        ])
        await mock._seedRows(forSQLPrefix: "SELECT id, session_id", [notAvailable, available])

        let result = await service.fetchMessages(sessionId: "s1", limit: 10, before: nil)
        #expect(result.count == 2)
        // Reversed to chronological: [available (id 7), notAvailable (id 8)].
        let avail = result.first { $0.id == 7 }
        #expect(avail?.reasoningContentAvailable == true)
        #expect(avail?.reasoningContent == nil)       // blob NOT loaded by the light fetch
        #expect(avail?.hasReasoning == true)          // disclosure shows via the flag
        let plain = result.first { $0.id == 8 }
        #expect(plain?.reasoningContentAvailable == false)
        #expect(plain?.hasReasoning == false)
    }

    @Test func fetchSkeletonMessagesBareSchemaOmitsReasoning() async {
        // No v0.7 schema → no reasoning column selected at all.
        let mock = MockHermesQueryBackend()
        await mock.setHasV07Schema(false)
        await mock.setHasV011Schema(false)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchSkeletonMessages(sessionId: "s1", limit: 200)

        let sql = await mock.queryLog[0].sql
        #expect(!sql.contains("reasoning"))            // "finish_reason" doesn't match "reasoning"
        #expect(sql.contains("NULL AS tool_calls"))
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
        #expect(stmts[1].sql.contains("ORDER BY started_at DESC LIMIT ?"))
        // 2: session previews — joins messages with first user message.
        #expect(stmts[2].sql.contains("INNER JOIN"))
        #expect(stmts[2].sql.contains("MIN(id)"))
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

    // MARK: - messages.active filtering (v0.16)

    @Test func fetchMessagesOutcomeWithActiveColumnIncludesActiveFilter() async {
        // v0.16+ DBs have the active column; queries must add "AND active = 1".
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchMessagesOutcome(sessionId: "s1", limit: 25, before: nil)

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND active = 1"))
    }

    @Test func fetchMessagesOutcomeWithoutActiveColumnOmitsFilter() async {
        // Pre-v0.16 DBs lack the active column; queries must NOT reference it.
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(false)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchMessagesOutcome(sessionId: "s1", limit: 25, before: nil)

        let sql = await mock.queryLog[0].sql
        #expect(!sql.contains("AND active = 1"))
    }

    @Test func fetchSkeletonMessagesWithActiveColumnIncludesFilter() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchSkeletonMessages(sessionId: "s1", limit: 200)

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND active = 1"))
    }

    @Test func fetchToolResultsInRangeWithActiveColumnIncludesFilter() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchToolResultsInRange(sessionId: "s1", minId: 1, maxId: 100)

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND active = 1"))
    }

    @Test func fetchRecentToolCallSkeletonWithActiveColumnIncludesFilter() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchRecentToolCallSkeleton(limit: 50)

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND active = 1"))
    }

    @Test func searchMessagesWithActiveColumnIncludesFilter() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.searchMessages(query: "test")

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND m.active = 1"))
    }

    @Test func searchMessagesWithoutActiveColumnOmitsFilter() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(false)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.searchMessages(query: "test")

        let sql = await mock.queryLog[0].sql
        #expect(!sql.contains("AND m.active = 1"))
    }

    @Test func fetchRecentToolCallsOutcomeWithActiveColumnIncludesFilter() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchRecentToolCallsOutcome(limit: 50)

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND active = 1"))
    }

    // MARK: - messages.compacted search widening (v0.18)

    @Test func searchMessagesWithCompactedColumnIncludesCompactedRows() async {
        // v0.18 in-place compaction marks summarized-away rows
        // active=0/compacted=1 and Hermes search includes them — Scarf
        // search must match on the same DB.
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        await mock.setHasCompactedColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.searchMessages(query: "test")

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND (m.active = 1 OR m.compacted = 1)"))
        #expect(!sql.contains("AND m.active = 1 "))
    }

    @Test func searchMessagesWithoutCompactedColumnKeepsNarrowFilter() async {
        // v0.16–v0.17 DBs have active but not compacted — referencing
        // m.compacted there would be a "no such column" error.
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        await mock.setHasCompactedColumn(false)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.searchMessages(query: "test")

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND m.active = 1"))
        #expect(!sql.contains("compacted"))
    }

    @Test func transcriptFetchesStayActiveOnlyWithCompactedColumn() async {
        // Hermes reloads only the active set for transcripts — compacted
        // rows are summarized away and must NOT resurface in the chat
        // view, only in search.
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        await mock.setHasCompactedColumn(true)
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        _ = await service.fetchMessagesOutcome(sessionId: "s1", limit: 25, before: nil)

        let sql = await mock.queryLog[0].sql
        #expect(sql.contains("AND active = 1"))
        #expect(!sql.contains("compacted"))
    }

    // MARK: - hydrateAssistantToolCalls batching (v2.18)

    /// v2.18 perf: `hydrateAssistantToolCalls` must fold every 5-id
    /// page into ONE `queryBatch` round-trip instead of N sequential
    /// `query` calls (each an SSH exec on remote backends). The mock's
    /// `batchLog` records the batch; `queryLog` must stay empty.
    @Test func hydrateToolCallsUsesQueryBatch() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        // 12 ids -> 3 pages of 5, 5, 2. Seed via placeholder form
        // (HermesDataService emits ?-bound SQL; the mock matches on
        // the raw SQL prefix).
        let ids = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        // Seed tool_calls JSON for ids 1 and 12 so we can assert the
        // spliced map contents, not just the call shape.
        let callsJSON = #"[{"id":"c1","type":"function","function":{"name":"search","arguments":"{}"}}]"#
        await mock._seedRow(forSQLPrefix: "SELECT id, tool_calls FROM messages WHERE id IN (?,?,?,?,?)",
                            columns: ["id": 0, "tool_calls": 1],
                            values: [.integer(1), .text(callsJSON)])
        await mock._seedRow(forSQLPrefix: "SELECT id, tool_calls FROM messages WHERE id IN (?,?)",
                            columns: ["id": 0, "tool_calls": 1],
                            values: [.integer(12), .text(callsJSON)])

        let map = await service.hydrateAssistantToolCalls(messageIds: ids)

        let batchLog = await mock.batchLog
        #expect(batchLog.count == 1)
        #expect(batchLog[0].count == 3)  // three pages in one batch
        // Pages are iterated newest-first (reversed), so the 2-id page
        // [11,12] is slot 0 and the 5-id page [1..5] is slot 2.
        #expect(batchLog[0][0].sql.hasPrefix("SELECT id, tool_calls FROM messages WHERE id IN (?,?)"))
        #expect(batchLog[0][2].sql.hasPrefix("SELECT id, tool_calls FROM messages WHERE id IN (?,?,?,?,?)"))
        let queryLog = await mock.queryLog
        #expect(queryLog.isEmpty)  // no per-page fallback queries

        #expect(map.count == 2)
        #expect(map[1]?.first?.functionName == "search")
        #expect(map[12]?.first?.functionName == "search")
    }

    /// The batch path must degrade to the legacy per-page loop when the
    /// backend rejects the batch (transport timeout on an oversized
    /// tool_calls blob). Regression guard so the whale-isolation
    /// behaviour isn't lost.
    @Test func hydrateToolCallsFallsBackToPerPageOnBatchFailure() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: context, backend: mock)
        _ = await service.open()

        let ids = [1, 2, 3, 4, 5, 6]
        await mock._seedFailure(forSQLPrefix: "SELECT id, tool_calls FROM messages WHERE id IN (?,?,?,?,?)",
                                error: .transport("simulated timeout"))
        let callsJSON = #"[{"id":"c1","type":"function","function":{"name":"search","arguments":"{}"}}]"#
        await mock._seedRow(forSQLPrefix: "SELECT id, tool_calls FROM messages WHERE id IN (?)",
                            columns: ["id": 0, "tool_calls": 1],
                            values: [.integer(6), .text(callsJSON)])

        let map = await service.hydrateAssistantToolCalls(messageIds: ids)

        // Batch was attempted, failed, then per-page fallback ran.
        let batchLog = await mock.batchLog
        #expect(batchLog.count == 1)
        let queryLog = await mock.queryLog
        // page [6] query + failed page [1-5] query + 5 single-id retries.
        #expect(queryLog.count == 7)
        #expect(map[6]?.first?.functionName == "search")
    }
}

#endif // canImport(SQLite3)
