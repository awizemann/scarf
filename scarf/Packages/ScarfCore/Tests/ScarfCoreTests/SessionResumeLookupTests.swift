#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// gh#150 S3 — one state.db lookup per chat reopen.
///
/// `SessionResume.withSessionLookup` answers both `sessions.source` and
/// `sessions.cwd` from ONE private, lazily opened data service, and
/// `fetchSessionCwd` reads the column flag the preflight already set
/// instead of running its own `PRAGMA table_info(sessions)`.
@Suite struct SessionResumeLookupTests {

    // MARK: - Lookup lifecycle (mock backend)

    @Test func askingSourceAndCwdOpensTheBackendOnce() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasSessionsCwdColumn(true)
        await mock._seedRow(forSQLPrefix: "SELECT cwd FROM sessions",
                            columns: ["cwd": 0], values: [.text("/srv/work")])
        let cwd = await SessionResume.withSessionLookup(
            makeService: { HermesDataService(context: .local, backend: mock) }
        ) { lookup in
            _ = await lookup.source("s1")
            return await lookup.cwd("s1")
        }
        #expect(cwd == "/srv/work")
        #expect(await mock.openCallCount == 1)
        #expect(await mock.closeCallCount == 1)
        // No separate schema probe for the cwd column.
        #expect(await mock.queryLog.contains { $0.sql.hasPrefix("PRAGMA") } == false)
    }

    @Test func askingNothingNeverOpens() async {
        let mock = MockHermesQueryBackend()
        let made = Counter()
        let value = await SessionResume.withSessionLookup(
            makeService: { made.bump(); return HermesDataService(context: .local, backend: mock) }
        ) { _ in 42 }
        #expect(value == 42)
        #expect(made.value == 0)
        #expect(await mock.openCallCount == 0)
        #expect(await mock.closeCallCount == 0)
    }

    @Test func aFailedOpenAnswersNilWithoutRetrying() async {
        let mock = MockHermesQueryBackend()
        await mock.setOpenShouldSucceed(false)
        await mock.setHasSessionsCwdColumn(true)
        let (source, cwd) = await SessionResume.withSessionLookup(
            makeService: { HermesDataService(context: .local, backend: mock) }
        ) { lookup in
            (await lookup.source("s1"), await lookup.cwd("s1"))
        }
        #expect(source == nil)
        #expect(cwd == nil)
        #expect(await mock.openCallCount == 1)
        #expect(await mock.queryLog.isEmpty)
        // Like the one-shot lookups: nothing opened, nothing closed.
        #expect(await mock.closeCallCount == 0)
    }

    @Test func aThrowingBodyStillCloses() async {
        struct Boom: Error {}
        let mock = MockHermesQueryBackend()
        await #expect(throws: Boom.self) {
            try await SessionResume.withSessionLookup(
                makeService: { HermesDataService(context: .local, backend: mock) }
            ) { lookup in
                _ = await lookup.source("s1")
                throw Boom()
            }
        }
        #expect(await mock.openCallCount == 1)
        #expect(await mock.closeCallCount == 1)
    }

    // MARK: - fetchSessionCwd column flag (mock backend)

    @Test func fetchSessionCwdIsNilWithoutTheColumn() async {
        let mock = MockHermesQueryBackend()
        await mock._seedRow(forSQLPrefix: "SELECT cwd FROM sessions",
                            columns: ["cwd": 0], values: [.text("/srv/work")])
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        #expect(await service.fetchSessionCwd(id: "s1") == nil)
        #expect(await mock.queryLog.isEmpty)
    }

    @Test func fetchSessionCwdReadsTheValueWithTheColumn() async {
        let mock = MockHermesQueryBackend()
        await mock.setHasSessionsCwdColumn(true)
        await mock._seedRow(forSQLPrefix: "SELECT cwd FROM sessions",
                            columns: ["cwd": 0], values: [.text("/srv/work")])
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        #expect(await service.fetchSessionCwd(id: "s1") == "/srv/work")
        #expect(await mock.queryLog.map(\.sql) == ["SELECT cwd FROM sessions WHERE id = ? LIMIT 1"])
    }

    // MARK: - Real state.db (local backend preflight)

    private func makeHome(cwdColumn: Bool) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-s3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = home.appendingPathComponent("state.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        // Hermes's v0.21.5 DDL has `sessions.cwd`; the "without" host drops
        // that one line from it.
        var schema = HermesV0215StateDDL.schemaSQL
        if !cwdColumn {
            precondition(schema.contains("    cwd TEXT,\n"))
            schema = schema.replacingOccurrences(of: "    cwd TEXT,\n", with: "")
        }
        let seed = cwdColumn
            ? "INSERT INTO sessions (id, source, cwd, started_at, message_count) VALUES ('s1', 'cli', '/srv/work', 1700000000, 1);"
            : "INSERT INTO sessions (id, source, started_at, message_count) VALUES ('s1', 'cli', 1700000000, 1);"
        var err: UnsafeMutablePointer<CChar>?
        let sql = schema + HermesV0215StateDDL.ftsSQL + seed
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture failed: \(msg)")
        }
        return home
    }

    @Test func localPreflightDetectsTheCwdColumn() async throws {
        let home = try makeHome(cwdColumn: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasSessionsCwdColumn)
        await backend.close()

        let context = ServerContext.local(home: home)
        let (source, cwd) = await SessionResume.withSessionLookup(context: context) { lookup in
            (await lookup.source("s1"), await lookup.cwd("s1"))
        }
        #expect(source == "cli")
        #expect(cwd == "/srv/work")
        #expect(await SessionResume.fetchCwd(context: context, sessionId: "s1") == "/srv/work")
        #expect(await SessionResume.fetchSource(context: context, sessionId: "s1") == "cli")
    }

    @Test func localHostWithoutTheColumnAnswersNilCwd() async throws {
        let home = try makeHome(cwdColumn: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasSessionsCwdColumn == false)
        await backend.close()

        let context = ServerContext.local(home: home)
        #expect(await SessionResume.fetchCwd(context: context, sessionId: "s1") == nil)
        #expect(await SessionResume.fetchSource(context: context, sessionId: "s1") == "cli")
    }
}

/// Thread-safe call counter for the `@Sendable` service factory.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

#endif // canImport(SQLite3)
