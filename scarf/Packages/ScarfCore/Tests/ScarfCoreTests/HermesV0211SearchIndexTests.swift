#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Hermes v0.21.1 (`v2026.9.7`) bounded tool-row FTS indexing (A10).
///
/// `messages_fts` now stores only `substr(content, 1, 8192)` for
/// `role='tool'` rows whose id is above
/// `state_meta.fts_tool_full_content_high_water`
/// (`hermes_state_common.py:224-234`), so a term that occurs only deeper
/// than that is invisible to `MATCH`. Scarf tops those up with a bounded
/// LIKE scan — gated purely on the `state_meta` key, never on a version.
///
/// The fixtures below replicate the index Hermes's triggers would have
/// produced, so the "FTS misses it" half is a property of the DB rather
/// than something the test asserts about itself.
@Suite struct HermesV0211SearchIndexTests {

    // MARK: - Fixture

    private static let needle = "zqxwelephant"
    private static let filler = String(repeating: "lorem ipsum dolor ", count: 1_200)  // ≫ 8 KB

    /// `content` whose only occurrence of the needle is far past the
    /// 8 KB prefix Hermes indexes.
    private static func deepContent() -> String { filler + " " + needle + " tail" }

    /// `content` that is just as long, but carries the needle up front
    /// where the truncated index can still see it.
    private static func shallowContent() -> String { needle + " " + filler }

    /// Build `<home>/state.db` with a v0.21.1-shaped `messages_fts`.
    /// `highWater` nil ⇒ the marker row is omitted, i.e. a host that
    /// never ran the bounded-tool migration.
    private func makeFixtureHome(highWater: Int?, rebuild: (progress: Int, high: Int)? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-v0211-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("state.db").path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        // The REAL v0.21.1 DDL, shared with `HermesV0211SchemaTests`, not a
        // hand-stripped 14-column paraphrase: a column Scarf's search SELECT
        // names but the release does not have would otherwise pass here and
        // fail on a user's machine (M9).
        try exec(db, """
        CREATE TABLE state_meta (key TEXT PRIMARY KEY, value TEXT);
        \(HermesV0211SchemaTests.sessionsDDL)
        \(HermesV0211SchemaTests.messagesDDL)
        CREATE VIRTUAL TABLE messages_fts USING fts5(
            content, tool_name, tool_calls, content='messages', content_rowid='id'
        );
        INSERT INTO sessions (id, source, started_at, message_count, tool_call_count,
                              input_tokens, output_tokens, cache_read_tokens,
                              cache_write_tokens, estimated_cost_usd)
        VALUES ('s1', 'acp', 1.0, 6, 5, 0, 0, 0, 0, 0.0);
        """)

        if let highWater {
            try exec(db, "INSERT INTO state_meta VALUES ('\(HermesFTSIndex.toolFullContentHighWaterKey)', '\(highWater)');")
        }
        if let rebuild {
            try exec(db, """
            INSERT INTO state_meta VALUES ('\(HermesFTSIndex.rebuildProgressKey)', '\(rebuild.progress)');
            INSERT INTO state_meta VALUES ('\(HermesFTSIndex.rebuildHighWaterKey)', '\(rebuild.high)');
            """)
        }

        // id, role, content, active
        let rows: [(Int, String, String, Int)] = [
            (5,  "tool",      Self.deepContent(),    1),   // below HW → fully indexed
            (20, "tool",      Self.deepContent(),    1),   // above HW → prefix-truncated, FTS blind
            (21, "tool",      Self.shallowContent(), 1),   // above HW → FTS sees it; must not duplicate
            (22, "assistant", Self.deepContent(),    1),   // non-tool rows are never truncated
            (23, "tool",      "short, no match",     1),
            (24, "tool",      Self.deepContent(),    0)    // rewound → excluded by the active clause
        ]
        for (id, role, content, active) in rows {
            try insertMessage(db, id: id, role: role, content: content, active: active)
            // Replicate `_fts_indexed_content_sql`: prefix-truncate tool
            // rows above the high-water, index everything else whole.
            let bounded = role == "tool" && highWater.map { id > $0 } == true
            let indexed = bounded ? String(content.prefix(HermesFTSIndex.toolContentPrefixChars)) : content
            try insertFTS(db, rowid: id, content: indexed)
        }
        return home
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "exec failed: \(message)")
        }
    }

    private func insertMessage(_ db: OpaquePointer?, id: Int, role: String, content: String, active: Int) throws {
        let sql = "INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES (?, 's1', ?, ?, 1.0, ?, 0)"
        try bindAndStep(db, sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
            sqlite3_bind_text(stmt, 2, role, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 4, Int32(active))
        }
    }

    private func insertFTS(_ db: OpaquePointer?, rowid: Int, content: String) throws {
        let sql = "INSERT INTO messages_fts (rowid, content, tool_name, tool_calls) VALUES (?, ?, NULL, NULL)"
        try bindAndStep(db, sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(rowid))
            sqlite3_bind_text(stmt, 2, content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func bindAndStep(_ db: OpaquePointer?, _ sql: String, _ bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TransportError.other(message: "prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw TransportError.other(message: "step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func cleanup(_ home: URL) { try? FileManager.default.removeItem(at: home) }

    private func service(_ home: URL) async -> HermesDataService {
        let service = HermesDataService(context: .local(home: home))
        _ = await service.open()
        return service
    }

    // MARK: - The fallback recovers what MATCH cannot see

    @Test func deepToolHitIsRecoveredOnABoundedIndex() async throws {
        let home = try makeFixtureHome(highWater: 10)
        defer { cleanup(home) }
        let service = await service(home)
        let ids = Set(await service.searchMessages(query: Self.needle).map(\.id))
        await service.close()

        #expect(ids.contains(20), "the row whose only hit is past the 8 KB prefix must be recovered")
        #expect(ids.contains(5), "a tool row below the high-water is still fully indexed")
        #expect(ids.contains(21))
        #expect(ids.contains(22))
        #expect(!ids.contains(23), "no needle in this row at all")
        #expect(!ids.contains(24), "rewound rows stay hidden — the fallback honours the active clause")
    }

    @Test func resultsAreNotDuplicatedByTheFallback() async throws {
        let home = try makeFixtureHome(highWater: 10)
        defer { cleanup(home) }
        let service = await service(home)
        let ids = await service.searchMessages(query: Self.needle).map(\.id)
        await service.close()
        #expect(ids.count == Set(ids).count, "id 21 matches both passes and must appear once: \(ids)")
    }

    /// The gate is the `state_meta` key, so the SAME database without the
    /// marker under-returns exactly as Scarf did before this change.
    @Test func aHostWithoutTheMarkerRunsTheOldQueryOnly() async throws {
        let home = try makeFixtureHome(highWater: nil)
        defer { cleanup(home) }
        let service = await service(home)
        let ids = Set(await service.searchMessages(query: Self.needle).map(\.id))
        await service.close()
        // Read this as the FIXTURE's property, not Hermes's: with no marker
        // the fixture indexes every row whole (that is what `makeFixtureHome`
        // does when `highWater` is nil), so the FTS pass alone returns id 20
        // and the result set happens to be complete. The assertion is only
        // that this host's answer is unchanged from the release before the
        // fallback existed; that no LIKE pass ran at all is pinned on the
        // SQL by `preV0211HostEmitsOneSearchQueryAndNoLIKE`. A real
        // pre-v0.21.1 host is likewise untruncated because the bounded-tool
        // migration never ran there — but that is upstream's doing, and
        // this test cannot observe it.
        #expect(ids == Set([5, 20, 21, 22]))
    }

    // MARK: - SQL shape (mock backend)

    @Test func preV0211HostEmitsOneSearchQueryAndNoLIKE() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.searchMessages(query: "needle")
        let log = await mock.queryLog
        // FTS pass + the one-time marker probe, and nothing else: no rows
        // came back for the probe, so no fallback is issued.
        #expect(log.filter { $0.sql.contains("LIKE") }.isEmpty)
        #expect(log.first?.sql.contains("messages_fts MATCH ?") == true)
    }

    @Test func theMarkerProbeIsCachedAcrossSearches() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.searchMessages(query: "needle")
        _ = await service.searchMessages(query: "needle")
        let probes = await mock.queryLog.filter { $0.sql.contains("state_meta") }
        #expect(probes.count == 1, "the high-water is stamped once and never moves")
    }

    @Test func fallbackIsBoundedByRowsRead() async throws {
        let mock = MockHermesQueryBackend()
        await mock._seedRow(
            forSQLPrefix: "SELECT CAST(value AS INTEGER) AS v FROM state_meta",
            columns: ["v": 0], values: [.integer(10)]
        )
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.searchMessages(query: "alpha beta", limit: 25)
        let fallback = try #require(await mock.queryLog.last { $0.sql.contains("LIKE") })
        #expect(fallback.sql.contains("role = 'tool' AND id > ? AND length(content) > ?"))
        let compact = fallback.sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(compact.contains("ORDER BY id DESC LIMIT ?"), "the inner LIMIT is the scan bound")
        #expect(fallback.params[0] == .integer(10), "scan starts above the high-water")
        #expect(fallback.params[1] == .integer(Int64(HermesFTSIndex.toolContentPrefixChars)))
        #expect(fallback.params[2] == .integer(Int64(HermesFTSIndex.fallbackScanBudget)))
        // One LIKE per term, and the outer limit is what the FTS pass left.
        #expect(fallback.params.count == 6)
        #expect(fallback.params.last == .integer(25))
    }

    @Test func fallbackIsSkippedWhenTheFTSPassAlreadyFilledTheLimit() async throws {
        let mock = MockHermesQueryBackend()
        await mock._seedRow(
            forSQLPrefix: "SELECT CAST(value AS INTEGER) AS v FROM state_meta",
            columns: ["v": 0], values: [.integer(10)]
        )
        let cols = ["id": 0, "session_id": 1, "role": 2, "content": 3, "tool_call_id": 4,
                    "tool_calls": 5, "tool_name": 6, "timestamp": 7, "token_count": 8, "finish_reason": 9]
        await mock._seedRows(forSQLPrefix: "SELECT m.id", [
            Row(values: [.integer(1), .text("s"), .text("tool"), .text("hit"), .null,
                         .null, .null, .real(1), .null, .null], columnIndex: cols)
        ])
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.searchMessages(query: "hit", limit: 1)
        #expect(await mock.queryLog.filter { $0.sql.contains("LIKE") }.isEmpty)
    }

    @Test func termsAreEscapedForLIKEAndCapped() async throws {
        let mock = MockHermesQueryBackend()
        await mock._seedRow(
            forSQLPrefix: "SELECT CAST(value AS INTEGER) AS v FROM state_meta",
            columns: ["v": 0], values: [.integer(0)]
        )
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.searchMessages(query: "100% snake_case a b c d e f g h i")
        let fallback = try #require(await mock.queryLog.last { $0.sql.contains("LIKE") })
        #expect(fallback.params.contains(.text("%100\\%%")))
        #expect(fallback.params.contains(.text("%snake\\_case%")))
        // 3 bounds + at most `fallbackMaxTerms` LIKE params + the limit.
        #expect(fallback.params.count == 4 + HermesFTSIndex.fallbackMaxTerms)
        #expect(fallback.sql.contains("ESCAPE '\\'"))
    }

    // MARK: - Rebuild affordance (A10b)

    @Test func rebuildMarkersReportAPartialIndex() async throws {
        let home = try makeFixtureHome(highWater: 10, rebuild: (progress: 40, high: 100))
        defer { cleanup(home) }
        let service = await service(home)
        let status = await service.searchIndexStatus()
        await service.close()
        #expect(status.isRebuilding)
        #expect(status.rebuildProgress == 40)
        #expect(status.rebuildHighWater == 100)
        #expect(status.toolPrefixHighWater == 10)
        #expect(status.rebuildFraction == 0.4)
    }

    /// Hermes deletes both markers together when the backfill lands
    /// (`_CLEAR_REBUILD_MARKERS_SQL`), so absence is "index is whole".
    @Test func absentMarkersReportAHealthyIndex() async throws {
        let home = try makeFixtureHome(highWater: 10)
        defer { cleanup(home) }
        let service = await service(home)
        let status = await service.searchIndexStatus()
        await service.close()
        #expect(!status.isRebuilding)
        #expect(status.rebuildFraction == nil)
    }

    @Test func aDBWithoutStateMetaReportsAHealthyIndex() async throws {
        let mock = MockHermesQueryBackend()
        await mock._seedFailure(
            forSQLPrefix: "SELECT",
            error: .sqlite(exitCode: 1, stderr: "no such table: state_meta")
        )
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        let status = await service.searchIndexStatus()
        #expect(!status.isRebuilding)
        #expect(status.toolPrefixHighWater == nil)
    }

    @Test func rebuildFractionRefusesToGuess() {
        #expect(HermesSearchIndexStatus(isRebuilding: true, rebuildProgress: 5).rebuildFraction == nil)
        #expect(HermesSearchIndexStatus(isRebuilding: true, rebuildHighWater: 5).rebuildFraction == nil)
        #expect(HermesSearchIndexStatus(isRebuilding: true, rebuildProgress: 9, rebuildHighWater: 5).rebuildFraction == nil)
        #expect(HermesSearchIndexStatus(isRebuilding: false, rebuildProgress: 1, rebuildHighWater: 5).rebuildFraction == nil)
    }

    /// L2 — both passes derive the active/compacted predicate from ONE
    /// helper instead of the inner pass rewriting the outer one's text with
    /// `replacingOccurrences(of: "m.", …)`, which would also rewrite an
    /// `m.` occurring anywhere else in the clause. The behavioural half is
    /// `deepMatchesAreRecoveredPastThePrefix`'s rewound row (id 24), which
    /// only stays hidden if the INNER query carries the clause too; this
    /// pins the SQL shape.
    @Test func neitherSearchPassEmitsAHalfRewrittenPredicate() async throws {
        let home = try makeFixtureHome(highWater: 10)
        defer { cleanup(home) }
        let service = await service(home)
        _ = await service.searchMessages(query: Self.needle)
        await service.close()

        let mock = MockHermesQueryBackend()
        let probe = HermesDataService(context: .local, backend: mock)
        #expect(await probe.open())
        _ = await probe.searchMessages(query: "needle")
        for entry in await mock.queryLog {
            #expect(!entry.sql.contains("m.m."))
            #expect(!entry.sql.contains("AND .active"))
            #expect(!entry.sql.contains("AND (.active"))
        }
    }
}
#endif
