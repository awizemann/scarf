#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// GitHub #145 — sessions created by Hermes's `/branch` carry
/// `HermesSession.isBranch` (and the parent's title) on every session-LIST
/// shape, decided by the same `_BRANCH_CHILD_SQL` the listing uses
/// (hermes_state_common.py:150-153 @ v0.21.5).
///
/// Real seeded SQLite, shaped like Hermes's `sessions` table, because the
/// finding is about what the SQL selects: a branch by marker, a legacy
/// branch by `end_reason = 'branched'`, a reset continuation and a subagent
/// run — only the first two may be marked.
@Suite struct SessionBranchLineageTests {

    private static let t0: Double = 1_700_000_000

    private func makeHome(modern: Bool) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("state.db").path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        let t = Self.t0
        // `modern`: v0.20.4+ columns (hidden, last_read_at, model_config,
        // session_key) → listable-child support. Otherwise a pre-v0.20.4
        // shape where children are never listed and no lineage is read.
        let extraCols = modern
            ? ", pinned INTEGER NOT NULL DEFAULT 0, last_activity_at REAL, last_activity_description TEXT, model_config TEXT, session_key TEXT, hidden INTEGER NOT NULL DEFAULT 0, last_read_at REAL"
            : ""
        let rows: String
        if modern {
            rows = """
            INSERT INTO sessions (id, source, title, parent_session_id, started_at, ended_at, end_reason, model_config, session_key) VALUES
              ('root',        'cli', 'Trip planning', NULL,         \(t),      \(t + 10), 'branched', NULL, 'k0'),
              ('markerBranch','cli', NULL,            'root',       \(t + 20), NULL,      NULL, '{"_branched_from": "root"}', 'k1'),
              ('legacyParent','cli', NULL,            NULL,         \(t + 30), \(t + 40), 'branched', NULL, 'k2'),
              ('legacyBranch','cli', 'Alt plan',      'legacyParent', \(t + 50), NULL,    NULL, NULL, 'k3'),
              ('resetParent', 'cli', 'Reset me',      NULL,         \(t + 60), \(t + 70), 'session_reset', NULL, 'k4'),
              ('resetChild',  'cli', NULL,            'resetParent', \(t + 80), NULL,     NULL, '{"_reset_from": "resetParent"}', 'k4'),
              ('subagent',    'cli', NULL,            'root',       \(t + 5),  NULL,      NULL, NULL, NULL);
            """
        } else {
            rows = """
            INSERT INTO sessions (id, source, title, parent_session_id, started_at, ended_at, end_reason) VALUES
              ('root',    'cli', 'Trip planning', NULL,   \(t),      \(t + 10), 'branched'),
              ('child',   'cli', NULL,            'root', \(t + 20), NULL,      NULL);
            """
        }
        let schema = """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, source TEXT NOT NULL, user_id TEXT, model TEXT, title TEXT,
                parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL, end_reason TEXT,
                message_count INTEGER DEFAULT 0, tool_call_count INTEGER DEFAULT 0,
                input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
                estimated_cost_usd REAL, reasoning_tokens INTEGER DEFAULT 0, actual_cost_usd REAL,
                cost_status TEXT, billing_provider TEXT, api_call_count INTEGER DEFAULT 0,
                rewind_count INTEGER NOT NULL DEFAULT 0\(extraCols)
            );
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
                tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
                token_count INTEGER, finish_reason TEXT, reasoning TEXT, reasoning_content TEXT
            );
            \(rows)
            """
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, schema, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture failed: \(msg)")
        }
        return home
    }

    private func open(_ home: URL) async throws -> HermesDataService {
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        return service
    }

    private func assertModernMarks(_ sessions: [HermesSession], _ shape: Comment) {
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        #expect(byId["markerBranch"]?.isBranch == true, shape)
        #expect(byId["markerBranch"]?.branchParentTitle == "Trip planning", shape)
        #expect(byId["legacyBranch"]?.isBranch == true, shape)
        // Untitled parent → nil; the UI falls back to a generic phrase.
        #expect(byId["legacyBranch"]?.branchParentTitle == nil, shape)
        #expect(byId["resetChild"]?.isBranch == false, shape)
        #expect(byId["resetChild"]?.branchParentTitle == nil, shape)
        #expect(byId["root"]?.isBranch == false, shape)
        #expect(byId["resetParent"]?.isBranch == false, shape)
        #expect(byId["subagent"] == nil, shape)
    }

    @Test("Every session-list shape marks /branch children and only them")
    func listShapesMarkBranches() async throws {
        let home = try makeHome(modern: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = try await open(home)

        assertModernMarks(await service.fetchSessions(limit: 50), "fetchSessions")
        let withUnread = await service.sessionListSnapshot(limit: 50)
        #expect(withUnread.queryError == nil)
        assertModernMarks(withUnread.sessions, "sessionListSnapshot(unread)")
        let noUnread = await service.sessionListSnapshot(limit: 50, includeUnreadActivity: false)
        #expect(noUnread.queryError == nil)
        assertModernMarks(noUnread.sessions, "sessionListSnapshot(no unread)")
        let dash = await service.dashboardSnapshot(sessionLimit: 50)
        #expect(dash.queryError == nil)
        assertModernMarks(dash.recentSessions, "dashboardSnapshot")
        await service.close()
    }

    @Test("Subagent lookup still excludes branches and never marks a subagent")
    func subagentsUnaffected() async throws {
        let home = try makeHome(modern: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = try await open(home)
        let subs = await service.fetchSubagentSessions(parentId: "root")
        #expect(subs.map(\.id) == ["subagent"])
        #expect(subs.allSatisfy { !$0.isBranch })
        await service.close()
    }

    @Test("A host without lineage support lists and decodes exactly as before")
    func olderHostUnmarked() async throws {
        let home = try makeHome(modern: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = try await open(home)
        let listed = await service.fetchSessions(limit: 50)
        // Pre-v0.20.4 listing: roots only, and no row is ever a branch.
        #expect(listed.map(\.id) == ["root"])
        #expect(listed.allSatisfy { !$0.isBranch && $0.branchParentTitle == nil })
        let snap = await service.sessionListSnapshot(limit: 50, includeUnreadActivity: false)
        #expect(snap.sessions.allSatisfy { !$0.isBranch })
        await service.close()
    }
}

#endif
