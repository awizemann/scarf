#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Hermes v0.21.4 (`v2026.9.21`, commit 42e97f3808) aligned FTS layout.
///
/// `messages_fts` becomes external-content over the `messages_fts_src`
/// view, which truncates EVERY `role='tool'` row to the 8 KB prefix, and
/// the realign deletes `fts_tool_full_content_high_water`. The v0.21.1
/// rule read that missing marker as "nothing truncated" and skipped the
/// LIKE fallback, so deep tool-output hits silently vanished.
///
/// Unlike `HermesV0211SearchIndexTests`, nothing here hand-replicates the
/// index: the DDL below is `FTS_SQL` rendered verbatim from
/// `hermes_state_common.py:708-789` @ v2026.9.21 (the view, the vtable and
/// the insert trigger), so the triggers themselves decide what `MATCH` can
/// see. Every DB is a temp file (charter C3).
@Suite struct HermesV0214SearchIndexTests {

    private static let needle = "zqxwelephant"
    private static let filler = String(repeating: "lorem ipsum dolor ", count: 1_200)  // ≫ 8 KB
    private static func deepContent() -> String { filler + " " + needle + " tail" }
    private static func shallowContent() -> String { needle + " " + filler }

    /// `messages` at v2026.9.21 (`hermes_state_common.py:402-429`).
    static let messagesDDL = """
    CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        role TEXT NOT NULL,
        content TEXT,
        tool_call_id TEXT,
        tool_calls TEXT,
        tool_name TEXT,
        effect_disposition TEXT,
        timestamp REAL NOT NULL,
        token_count INTEGER,
        finish_reason TEXT,
        reasoning TEXT,
        reasoning_content TEXT,
        reasoning_details TEXT,
        codex_reasoning_items TEXT,
        codex_message_items TEXT,
        platform_message_id TEXT,
        observed INTEGER DEFAULT 0,
        _compressed_summary INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1,
        compacted INTEGER NOT NULL DEFAULT 0,
        api_content TEXT,
        display_kind TEXT,
        display_metadata TEXT,
        display_identity BLOB,
        display_order INTEGER
    );
    """

    /// `FTS_SQL` @ v2026.9.21, rendered (`FTS_TOOL_CONTENT_PREFIX_CHARS`
    /// = 8192 substituted), view + vtable + insert trigger.
    static let alignedFTSDDL = """
    CREATE VIEW IF NOT EXISTS messages_fts_src AS
        SELECT id,
               CASE WHEN role = 'tool'
                    THEN substr(COALESCE(content, ''), 1, 8192)
                    ELSE content END AS content,
               tool_name, tool_calls
        FROM messages;

    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        content,
        tool_name,
        tool_calls,
        content='messages_fts_src',
        content_rowid='id'
    );

    CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages
    WHEN (new.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                             WHERE key = 'fts_rebuild_high_water'), -1)
       OR new.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                              WHERE key = 'fts_rebuild_progress'), -1))
    BEGIN
        INSERT INTO messages_fts(rowid, content, tool_name, tool_calls)
        VALUES (
            new.id,
            CASE WHEN new.role = 'tool'
             THEN substr(COALESCE(new.content, ''), 1, 8192)
             ELSE new.content END,
            new.tool_name,
            new.tool_calls
        );
    END;
    """

    /// id, role, content, active. Id 5 sits where a v0.21.1 high-water of
    /// 10 would have exempted it; under the aligned layout it is truncated
    /// like every other tool row.
    private static let rows: [(Int, String, String, Int)] = [
        (5,  "tool",      deepContent(),    1),
        (20, "tool",      deepContent(),    1),
        (21, "tool",      shallowContent(), 1),   // FTS sees it; must not duplicate
        (22, "assistant", deepContent(),    1),   // never truncated
        (23, "tool",      "short, no match", 1),
        (24, "tool",      deepContent(),    0)    // rewound → excluded
    ]

    // MARK: - Fixture

    private enum Layout {
        /// Born fresh on v0.21.4+: `FTS_SQL` from the start, no marker.
        case alignedFresh
        /// A v0.21.1-era DB (raw-`messages` external content, marker = 10)
        /// put through `_migrate_misaligned_fts_source`'s `do_align`
        /// (`hermes_state_schema.py:357-366` @ v2026.9.21): drop the base
        /// triggers + vtable, run `FTS_SQL`, `'rebuild'` from the view,
        /// delete the retired marker.
        case realignedFromV0211
    }

    private func makeHome(_ layout: Layout) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-v0214-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("state.db").path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        try exec(db, """
        CREATE TABLE state_meta (key TEXT PRIMARY KEY, value TEXT);
        \(HermesV0211SchemaTests.sessionsDDL)
        \(Self.messagesDDL)
        INSERT INTO sessions (id, source, started_at, message_count, tool_call_count,
                              input_tokens, output_tokens, cache_read_tokens,
                              cache_write_tokens, estimated_cost_usd)
        VALUES ('s1', 'acp', 1.0, 6, 5, 0, 0, 0, 0, 0.0);
        """)

        switch layout {
        case .alignedFresh:
            try exec(db, Self.alignedFTSDDL)
            for row in Self.rows { try insertMessage(db, row) }
        case .realignedFromV0211:
            try exec(db, """
            CREATE VIRTUAL TABLE messages_fts USING fts5(
                content, tool_name, tool_calls, content='messages', content_rowid='id'
            );
            INSERT INTO state_meta VALUES ('\(HermesFTSIndex.toolFullContentHighWaterKey)', '10');
            """)
            for row in Self.rows { try insertMessage(db, row) }
            try exec(db, """
            DROP TABLE IF EXISTS messages_fts;
            \(Self.alignedFTSDDL)
            INSERT INTO messages_fts(messages_fts) VALUES('rebuild');
            DELETE FROM state_meta WHERE key IN ('fts_rebuild_high_water', 'fts_rebuild_progress');
            DELETE FROM state_meta WHERE key = 'fts_tool_full_content_high_water';
            """)
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

    private func insertMessage(_ db: OpaquePointer?, _ row: (Int, String, String, Int)) throws {
        let sql = "INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES (?, 's1', ?, ?, 1.0, ?, 0)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TransportError.other(message: "prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int(stmt, 1, Int32(row.0))
        sqlite3_bind_text(stmt, 2, row.1, -1, transient)
        sqlite3_bind_text(stmt, 3, row.2, -1, transient)
        sqlite3_bind_int(stmt, 4, Int32(row.3))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw TransportError.other(message: "step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func service(_ home: URL) async -> HermesDataService {
        let service = HermesDataService(context: .local(home: home))
        _ = await service.open()
        return service
    }

    // MARK: - Real DDL

    /// Precondition, asserted on the DB rather than assumed: Hermes's own
    /// triggers really do hide the deep hits from MATCH.
    @Test(arguments: ["fresh", "realigned"])
    func theTaggedTriggersHideDeepToolHits(_ which: String) async throws {
        let home = try makeHome(which == "fresh" ? .alignedFresh : .realignedFromV0211)
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(home.appendingPathComponent("state.db").path, &db,
                                SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rowid",
                                   -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.needle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var ids: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(Int(sqlite3_column_int(stmt, 0))) }
        #expect(ids == [21, 22], "only the shallow tool row and the untruncated assistant row are indexed")
    }

    @Test(arguments: ["fresh", "realigned"])
    func deepToolHitsAreRecoveredOnTheAlignedLayout(_ which: String) async throws {
        let home = try makeHome(which == "fresh" ? .alignedFresh : .realignedFromV0211)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await service(home)
        let ids = await service.searchMessages(query: Self.needle).map(\.id)
        let status = await service.searchIndexStatus()
        await service.close()

        #expect(Set(ids) == [5, 20, 21, 22], "every truncated tool row is recovered, including id 5 below any old high-water")
        #expect(ids.count == Set(ids).count, "id 21 matches both passes and must appear once")
        #expect(status.toolPrefixHighWater == 0)
        #expect(!status.isRebuilding)
    }

    // MARK: - SQL shape (mock backend)

    @Test func alignedLayoutScansFromIdZeroWithoutReadingTheMarker() async throws {
        let mock = MockHermesQueryBackend()
        await mock._seedRow(
            forSQLPrefix: "SELECT sql FROM sqlite_master",
            columns: ["sql": 0],
            values: [.text("CREATE VIRTUAL TABLE messages_fts USING fts5(\n    content,\n    tool_name,\n    tool_calls,\n    content='messages_fts_src',\n    content_rowid='id'\n)")]
        )
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.searchMessages(query: "needle")
        _ = await service.searchMessages(query: "needle")
        let log = await mock.queryLog
        let fallback = try #require(log.last { $0.sql.contains("LIKE") })
        #expect(fallback.params[0] == .integer(0))
        #expect(log.filter { $0.sql.contains("sqlite_master") }.count == 1, "layout probe is cached per open")
        #expect(log.filter { $0.sql.contains("state_meta WHERE key = ?") }.isEmpty)
    }

    /// A pre-v0.21.4 vtable (`content='messages'`) keeps the v0.21.1 rule
    /// verbatim: the marker decides, and its absence means no fallback.
    @Test func preAlignedVTableStillDefersToTheMarker() async throws {
        let mock = MockHermesQueryBackend()
        await mock._seedRow(
            forSQLPrefix: "SELECT sql FROM sqlite_master",
            columns: ["sql": 0],
            values: [.text("CREATE VIRTUAL TABLE messages_fts USING fts5(\n    content, tool_name, tool_calls, content='messages', content_rowid='id'\n)")]
        )
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.searchMessages(query: "needle")
        let log = await mock.queryLog
        #expect(log.filter { $0.sql.contains("LIKE") }.isEmpty)
        #expect(log.contains { $0.sql.contains("state_meta WHERE key = ?") })
    }
}
#endif
