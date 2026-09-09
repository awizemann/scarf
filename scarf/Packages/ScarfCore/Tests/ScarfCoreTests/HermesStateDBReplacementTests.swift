#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// A12: Hermes v0.21.1 can MOVE a corrupt `state.db` aside
/// (`quarantine_zeroed_state_db`, `hermes_state_dbfile.py:238-278` —
/// `state.db` → `state.db.zeroed-<ts>-<pid>.bak`) and let the next open
/// create a fresh one at the same path.
///
/// A SQLite connection follows the INODE it opened, and
/// `LocalSQLiteBackend.refresh(forceFresh: false)` deliberately keeps
/// its handle across ticks (reopening a multi-GB WAL DB on every
/// FSEvent burst was the dominant cost of gh#102). Without an identity
/// check that pairing serves the quarantined file forever: no error, no
/// empty result, just data that quietly stops changing. Same shape for a
/// restore-from-backup or a `cp` over the DB.
@Suite struct HermesStateDBReplacementTests {

    private func makeDB(at url: URL, title: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "open failed")
        }
        defer { sqlite3_close(db) }
        let ddl = """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, title TEXT, started_at REAL);
        CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL);
        INSERT INTO sessions VALUES ('s1', 'acp', '\(title)', 1.0);
        """
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, ddl, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: message)
        }
    }

    private func title(_ backend: LocalSQLiteBackend) async -> String? {
        let rows = try? await backend.query("SELECT title FROM sessions WHERE id = 's1'", params: [])
        return rows?.first?.optionalString(at: 0)
    }

    @Test func refreshReopensAfterTheDBIsQuarantinedAndReplaced() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("state.db")
        try makeDB(at: path, title: "original")

        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await title(backend) == "original")

        // Exactly what Hermes does: rename aside, then a fresh DB lands
        // at the same path.
        try FileManager.default.moveItem(at: path, to: home.appendingPathComponent("state.db.zeroed-20260907-1.bak"))
        try makeDB(at: path, title: "replacement")

        #expect(await backend.refresh(forceFresh: false))
        #expect(await title(backend) == "replacement",
                "the steady-state refresh must notice the inode changed under it")
        await backend.close()
    }

    /// The identity check must not turn the steady-state refresh into a
    /// reopen: that short-circuit is the fix for gh#102 and reopening a
    /// large WAL DB on every coalesced FSEvent burst is what it avoids.
    @Test func anUntouchedDBIsNotReopened() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("state.db")
        try makeDB(at: path, title: "original")

        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())

        // Mark THIS connection. A TEMP table lives in the connection's own
        // temp database, so it survives exactly as long as the handle does —
        // which makes it the one observable that separates "kept the handle"
        // from "reopened and happened to read the same bytes". The previous
        // version of this test wrote through a second connection and read
        // the value back, which a reopen satisfies just as well: it passed
        // with the gh#102 short-circuit deleted.
        _ = try await backend.query("CREATE TEMP TABLE scarf_handle_probe(x)", params: [])
        _ = try await backend.query("INSERT INTO scarf_handle_probe VALUES (1)", params: [])

        // A write through a SEPARATE connection to the same inode is still
        // visible without any reopen — the WAL does that on its own.
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE sessions SET title = 'edited' WHERE id = 's1'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        for _ in 0..<5 { #expect(await backend.refresh(forceFresh: false)) }
        #expect(await title(backend) == "edited")
        // The probe is still there ⇒ no reopen happened across five ticks.
        let probe = try await backend.query("SELECT x FROM scarf_handle_probe", params: [])
        #expect(probe.count == 1)

        // …and a FORCED refresh does reopen, so the probe goes away. That is
        // the control: without it, a `query` that silently swallowed the
        // missing table would make the assertion above vacuous.
        #expect(await backend.refresh(forceFresh: true))
        await #expect(throws: (any Error).self) {
            _ = try await backend.query("SELECT x FROM scarf_handle_probe", params: [])
        }
        await backend.close()
    }

    /// A DB that vanishes entirely (rename with no replacement) reports
    /// the failure rather than serving a ghost.
    @Test func aDeletedDBSurfacesTheError() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("state.db")
        try makeDB(at: path, title: "original")

        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        try FileManager.default.removeItem(at: path)
        // `stat` fails ⇒ identity unknown ⇒ the handle is kept, which is
        // the same reading a poll on a mid-quarantine path would get.
        // The next FORCED refresh is what reports the truth.
        #expect(await backend.refresh(forceFresh: true) == false)
        #expect(await backend.lastOpenError != nil)
        await backend.close()
    }
}

#endif // canImport(SQLite3)
