#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
import ScarfCore
@testable import ScarfIOS

/// t-00ade623: the iOS Dashboard must not render a failed session query as
/// "No sessions yet", and overlapping loads (`.task` + `.refreshable`) must
/// not close the shared data service under each other.
///
/// Driven through a `.local(home:)` context so the real `HermesDataService`
/// + `LocalSQLiteBackend` run against a scratch state.db — never a real one.
@MainActor
@Suite struct IOSDashboardViewModelLoadTests {

    /// The pre-v0.7 `sessions` shape `HermesDataService`'s list SELECT reads.
    private static let sessionsDDL = """
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
        parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
        message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
        estimated_cost_usd REAL
    );
    CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL);
    INSERT INTO sessions (id, source, title, started_at, message_count) VALUES ('s1', 'cli', 'one', 1.0, 1);
    INSERT INTO sessions (id, source, title, started_at, message_count) VALUES ('s2', 'cli', 'two', 2.0, 1);
    """

    private func makeHome(_ sql: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ios-dash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = home.appendingPathComponent("state.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "fixture open failed")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TransportError.other(message: "fixture exec failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return home
    }

    /// A state.db that OPENS fine (the schema probe only reads
    /// sqlite_master / table_info) but whose `sessions` table lacks the
    /// columns the list SELECT names — so every session query fails after a
    /// good open. Before the fix: no banner, "No sessions yet".
    @Test func sessionQueryFailureAfterGoodOpenRaisesTheBanner() async throws {
        let home = try makeHome("CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT);")
        defer { try? FileManager.default.removeItem(at: home) }

        let vm = IOSDashboardViewModel(context: .local(home: home))
        await vm.load()

        #expect(vm.isLoading == false)
        #expect(vm.allSessions.isEmpty)
        let error = try #require(vm.lastError, "a failed session query must surface, not read as an empty list")
        #expect(error.lowercased().contains("no such column"))
        #expect(vm.lastErrorIsMissingSQLite3 == false)
    }

    @Test func healthyLoadHasNoBanner() async throws {
        let home = try makeHome(Self.sessionsDDL)
        defer { try? FileManager.default.removeItem(at: home) }

        let vm = IOSDashboardViewModel(context: .local(home: home))
        await vm.load()

        #expect(vm.lastError == nil)
        #expect(vm.allSessions.map(\.id) == ["s2", "s1"])
        #expect(vm.recentSessions.count == 2)
    }

    /// `.task` and `.refreshable` firing together: both loads must finish
    /// with the data, neither may leave the other reading a closed service.
    /// The second load starts at a sweep of offsets into the first, so some
    /// iteration lands the first load's closing `dataService.close()` in
    /// the middle of the second's reads — the real pull-to-refresh race.
    @Test func overlappingLoadsBothSeeTheSessions() async throws {
        let home = try makeHome(Self.sessionsDDL)
        defer { try? FileManager.default.removeItem(at: home) }

        let vm = IOSDashboardViewModel(context: .local(home: home))
        var failures: [Int] = []
        for offset in 0..<60 {
            let first = Task { await vm.load() }
            for _ in 0..<offset { await Task.yield() }
            await vm.refresh()
            await first.value
            if vm.lastError != nil || vm.allSessions.count != 2 || vm.recentSessions.count != 2 {
                failures.append(offset)
            }
            #expect(vm.isLoading == false)
        }
        #expect(failures.isEmpty, "overlapping loads lost data at yield offsets \(failures)")
    }
}

#endif
