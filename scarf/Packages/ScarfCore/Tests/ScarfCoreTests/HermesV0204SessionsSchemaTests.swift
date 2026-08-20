#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Hermes v0.20.4 (v2026.8.18) sessions additions: `sessions.hidden`
/// and `sessions.last_read_at`, plus Hermes's listable-child predicate
/// (`_LISTABLE_CHILD_SQL`) now surfacing reset continuations in its own
/// session listing.
///
/// All three are SCHEMA-detected via column probes, never version
/// flags. These tests pin down (a) probe detection with the columns
/// present and absent, (b) `hidden = 0` filtering, (c) unread
/// derivation from the read watermark, (d) reset-child listing
/// including the pre-marker legacy fallback and the matching
/// subagent-fetch exclusion, and (e) byte-identical SQL on pre-v0.20.4
/// DBs.
@Suite struct HermesV0204SessionsSchemaTests {

    // MARK: - Fixture DB

    /// Build an isolated `<tempHome>/state.db`. `addV0204` layers the
    /// two new sessions columns on the v0.20 shape; everything the
    /// listable-child predicate reads (`model_config`, `session_key`,
    /// `end_reason`, `started_at`, `ended_at`) is present either way,
    /// so the "absent" fixture proves the gate is the v0.20.4 marker
    /// columns and not merely those.
    private func makeFixtureHome(addV0204: Bool) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-v0204-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dbPath = home.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        let v0204Columns = addV0204
            ? ", hidden INTEGER NOT NULL DEFAULT 0, last_read_at REAL"
            : ""
        var schema = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
            parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
            message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
            output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
            estimated_cost_usd REAL,
            reasoning_tokens INTEGER, actual_cost_usd REAL, cost_status TEXT, billing_provider TEXT,
            api_call_count INTEGER, rewind_count INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0, last_activity_at REAL, last_activity_description TEXT,
            model_config TEXT, session_key TEXT\(v0204Columns)
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
            tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
            token_count INTEGER, finish_reason TEXT, reasoning TEXT,
            reasoning_content TEXT, active INTEGER NOT NULL DEFAULT 1,
            compacted INTEGER NOT NULL DEFAULT 0
        );
        """

        // Row cast, shared by both fixtures:
        //   root        — plain root session
        //   hiddenRoot  — root Hermes hid (only filterable on v0.20.4)
        //   resetParent — ended at a reset boundary, session_key 'k1'
        //   resetChild  — marker-stamped continuation of resetParent
        //   legacyChild — pre-marker continuation: same non-empty
        //                 session_key as its parent, parent ended
        //                 at a reset boundary
        //   subagent    — ordinary child run of `root` (never listable)
        let common = "message_count, tool_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd"
        let cols = "id, source, started_at, ended_at, end_reason, parent_session_id, model_config, session_key, last_activity_at, \(common)"
        let v0204Values = addV0204 ? ", hidden, last_read_at" : ""
        func row(_ id: String, _ started: Double, _ ended: String, _ endReason: String,
                 _ parent: String, _ modelConfig: String, _ key: String,
                 _ lastActivity: String, hidden: Int, lastRead: String) -> String {
            var base = "('\(id)', 'acp', \(started), \(ended), \(endReason), \(parent), \(modelConfig), \(key), \(lastActivity), 1, 0, 10, 10, 0, 0, 0.01"
            if addV0204 { base += ", \(hidden), \(lastRead)" }
            return base + ")"
        }
        let rows = [
            row("root", 1_700_000_000, "NULL", "NULL", "NULL", "NULL", "'k0'", "1700000100.0", hidden: 0, lastRead: "NULL"),
            row("hiddenRoot", 1_700_000_010, "NULL", "NULL", "NULL", "NULL", "NULL", "NULL", hidden: 1, lastRead: "NULL"),
            row("resetParent", 1_700_000_020, "1700000030.0", "'session_reset'", "NULL", "NULL", "'k1'", "NULL", hidden: 0, lastRead: "NULL"),
            row("resetChild", 1_700_000_040, "NULL", "NULL", "'resetParent'", "'{\"_reset_from\": \"resetParent\"}'", "'k2'", "1700000200.0", hidden: 0, lastRead: "1700000100.0"),
            row("legacyChild", 1_700_000_050, "NULL", "NULL", "'resetParent'", "NULL", "'k1'", "1700000060.0", hidden: 0, lastRead: "1700000090.0"),
            row("subagent", 1_700_000_060, "NULL", "NULL", "'root'", "NULL", "NULL", "NULL", hidden: 0, lastRead: "NULL")
        ]
        schema += "INSERT INTO sessions (\(cols)\(v0204Values)) VALUES \(rows.joined(separator: ", "));"

        // Messages exist so the session-list query's `last_active` term
        // (Hermes's `_sql_session_last_active`) has something to MAX over.
        //
        //   legacyChild — heartbeat 1700000060 LAGS its newest message
        //                 (1700000095), which itself postdates the
        //                 watermark (1700000090). The durable heartbeat is
        //                 rate-limited (~60 s), so this is the ordinary
        //                 shape right after a turn — and the case the
        //                 heartbeat-only derivation got wrong.
        //   resetChild  — heartbeat 1700000200 is FRESHER than its newest
        //                 message (1700000110); the MAX must keep the
        //                 heartbeat, so this stays unread either way.
        //   resetParent — messages but no heartbeat at all.
        schema += """
        INSERT INTO messages (session_id, role, content, timestamp) VALUES
            ('legacyChild', 'user', 'hi', 1700000095.0),
            ('legacyChild', 'user', 'older', 1700000055.0),
            ('resetChild', 'assistant', 'hey', 1700000110.0),
            ('resetParent', 'user', 'x', 1700000025.0),
            ('root', 'user', 'x', 1700000005.0);
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

    // MARK: - Probe detection

    @Test func localBackendDetectsV0204ColumnsWhenPresent() async throws {
        let home = try makeFixtureHome(addV0204: true)
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasHiddenColumn)
        #expect(await backend.hasLastReadAtColumn)
        #expect(await backend.hasListableChildSupport)
        await backend.close()
    }

    @Test func localBackendReportsAbsentV0204ColumnsOnOlderDB() async throws {
        let home = try makeFixtureHome(addV0204: false)
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasHiddenColumn == false)
        #expect(await backend.hasLastReadAtColumn == false)
        // `model_config` / `session_key` exist here, so this proves the
        // listable-child gate keys off the v0.20.4 marker columns.
        #expect(await backend.hasListableChildSupport == false)
        // Pre-existing detection unaffected.
        #expect(await backend.hasV07Schema)
        #expect(await backend.hasSessionActivityColumns)
        await backend.close()
    }

    @Test func remoteJSON1GateFollowsSQLiteVersion() {
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "3.43.2 2023-10-10 abcdef"))
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "3.38.0 2022-02-22 abcdef"))
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "3.37.2 2022-01-06 abcdef") == false)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "4.0.1 2030-01-01"))
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: nil) == false)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "sqlite3: command not found") == false)
    }

    // MARK: - hidden filtering + reset-child listing (local fixture)

    @Test func sessionListHidesHiddenAndSurfacesResetChildren() async throws {
        let home = try makeFixtureHome(addV0204: true)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let ids = Set(await service.fetchSessions().map(\.id))
        // Roots, minus the hidden one.
        #expect(ids.contains("root"))
        #expect(ids.contains("resetParent"))
        #expect(!ids.contains("hiddenRoot"))
        // Reset continuations: marker-stamped AND pre-marker legacy.
        #expect(ids.contains("resetChild"))
        #expect(ids.contains("legacyChild"))
        // Ordinary subagent runs stay out.
        #expect(!ids.contains("subagent"))
        await service.close()
    }

    @Test func periodListAppliesTheSamePredicate() async throws {
        let home = try makeFixtureHome(addV0204: true)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let ids = Set(
            await service.fetchSessionsInPeriod(since: Date(timeIntervalSince1970: 1_699_000_000))
                .map(\.id)
        )
        #expect(!ids.contains("hiddenRoot"))
        #expect(!ids.contains("subagent"))
        #expect(ids.contains("resetChild"))
        await service.close()
    }

    @Test func sessionListSnapshotAppliesTheSamePredicate() async throws {
        let home = try makeFixtureHome(addV0204: true)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let ids = Set(await service.sessionListSnapshot().sessions.map(\.id))
        #expect(!ids.contains("hiddenRoot"))
        #expect(ids.contains("legacyChild"))
        let dashIds = Set(await service.dashboardSnapshot(sessionLimit: 20).recentSessions.map(\.id))
        #expect(!dashIds.contains("hiddenRoot"))
        #expect(!dashIds.contains("subagent"))
        await service.close()
    }

    @Test func preV0204DBListsRootsOnlyAndKeepsHiddenRow() async throws {
        let home = try makeFixtureHome(addV0204: false)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let ids = Set(await service.fetchSessions().map(\.id))
        // Byte-identical behaviour to today: roots only, no filtering
        // (the `hidden` column doesn't exist to filter on).
        #expect(ids == ["root", "hiddenRoot", "resetParent"])
        for session in await service.fetchSessions() {
            #expect(session.lastReadAt == nil)
            #expect(session.isUnread == false)
        }
        await service.close()
    }

    // MARK: - Subagent fetch (ephemeral-child semantics)

    @Test func subagentFetchExcludesResetContinuations() async throws {
        let home = try makeFixtureHome(addV0204: true)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        // resetParent's children are BOTH reset continuations — neither
        // is a subagent run, so the runs list is empty.
        let resetChildren = await service.fetchSubagentSessions(parentId: "resetParent")
        #expect(resetChildren.isEmpty)
        // An ordinary child run still renders as a subagent run.
        let rootChildren = await service.fetchSubagentSessions(parentId: "root").map(\.id)
        #expect(rootChildren == ["subagent"])
        await service.close()
    }

    @Test func subagentFetchOnOlderDBReturnsEveryChild() async throws {
        let home = try makeFixtureHome(addV0204: false)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let ids = await service.fetchSubagentSessions(parentId: "resetParent").map(\.id)
        // Unchanged pre-v0.20.4 behaviour.
        #expect(ids == ["resetChild", "legacyChild"])
        await service.close()
    }

    // MARK: - Unread derivation

    @Test func unreadDerivesFromTheReadWatermark() async throws {
        let home = try makeFixtureHome(addV0204: true)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let sessions = await service.fetchSessions()
        // `last_active` is the freshest of the heartbeat and the newest
        // message. Here the heartbeat (1700000200) wins over the message
        // max (1700000110), and both postdate the watermark (1700000100).
        let resetChild = try #require(sessions.first { $0.id == "resetChild" })
        #expect(resetChild.lastReadAt?.timeIntervalSince1970 == 1_700_000_100.0)
        #expect(resetChild.lastActive?.timeIntervalSince1970 == 1_700_000_200.0)
        #expect(resetChild.isUnread)
        // THE FIX. legacyChild's heartbeat (1700000060) predates the
        // watermark (1700000090), so the old heartbeat-only derivation
        // called it read — but its newest message (1700000095) postdates
        // the watermark, and that is Hermes's dominant term
        // (`_sql_session_last_active`, hermes_state_common.py:169-191).
        // The durable heartbeat is rate-limited (~60 s) and best-effort,
        // so it routinely lags the messages a turn just wrote.
        let legacyChild = try #require(sessions.first { $0.id == "legacyChild" })
        #expect(legacyChild.lastActivityAt?.timeIntervalSince1970 == 1_700_000_060.0)
        #expect(legacyChild.lastActive?.timeIntervalSince1970 == 1_700_000_095.0)
        #expect(legacyChild.isUnread)
        // NULL watermark = never tracked = read, even with activity.
        let root = try #require(sessions.first { $0.id == "root" })
        #expect(root.lastReadAt == nil)
        #expect(root.isUnread == false)
        // No heartbeat at all → the message max still populates
        // `last_active` (started_at is only the last-resort fallback).
        let resetParent = try #require(sessions.first { $0.id == "resetParent" })
        #expect(resetParent.lastActivityAt == nil)
        #expect(resetParent.lastActive?.timeIntervalSince1970 == 1_700_000_025.0)
        // hiddenRoot has neither heartbeat nor messages → started_at.
        let noActivity = await service.fetchSubagentSessions(parentId: "root")
        #expect(noActivity.allSatisfy { $0.lastActive == nil })  // not a LIST query
        await service.close()
    }

    /// The correlated `last_active` subquery rides only on the list
    /// queries whose rows feed the unread badge — it costs one subquery
    /// per row, so the single-session, subagent, and analytics shapes
    /// must stay on the cheap SELECT.
    @Test func lastActiveRidesOnlyOnTheListQueries() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasHiddenColumn(true)
        await mock.setHasLastReadAtColumn(true)
        await mock.setHasListableChildSupport(true)
        await mock.setHasSessionActivityColumns(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())

        _ = await service.fetchSessions()
        let listSQL = try #require(await mock.queryLog.last?.sql)
        #expect(listSQL.contains("AS last_active"))
        #expect(listSQL.contains("MAX(_act_m.timestamp) FROM messages _act_m"))

        _ = await service.fetchSubagentSessions(parentId: "p")
        #expect(try #require(await mock.queryLog.last?.sql).contains("last_active") == false)

        _ = await service.fetchSessionsInPeriod(since: Date(timeIntervalSince1970: 0))
        #expect(try #require(await mock.queryLog.last?.sql).contains("last_active") == false)
    }

    /// The UNALIASED spelling of the `last_active` expression — emitted
    /// when `last_read_at` exists but the listable-child predicate is off,
    /// which is exactly what an old-sqlite3 (<3.38, no JSON1) host running
    /// a current Hermes looks like. That branch qualifies its correlated
    /// references with the bare table name instead of the `s` alias, and it
    /// is never executed by the other tests here, so run the emitted SQL
    /// against a real fixture DB to prove SQLite accepts it.
    @Test func unaliasedLastActiveExpressionExecutes() async throws {
        let home = try makeFixtureHome(addV0204: true)
        defer { cleanup(home) }

        // Capture the exact SQL the un-aliased branch emits.
        let mock = MockHermesQueryBackend()
        await mock.setHasLastReadAtColumn(true)
        await mock.setHasSessionActivityColumns(true)
        // hasListableChildSupport deliberately left FALSE.
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains("FROM sessions WHERE"))
        #expect(sql.contains("sessions.last_activity_at AS v"))
        #expect(sql.contains("_act_m.session_id = sessions.id"))

        // Now execute it for real.
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        let rows = try await backend.query(sql, params: [.integer(200)])
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Double?)? in
            guard let idIdx = row.columnIndex["id"],
                  let activeIdx = row.columnIndex["last_active"] else { return nil }
            return (row.string(at: idIdx), row.date(at: activeIdx)?.timeIntervalSince1970)
        })
        // This branch's predicate is roots-only, so the reset children
        // aren't in the result — the roots are, with the same
        // freshest-of values the aliased branch produces.
        #expect(byID["legacyChild"] == nil)
        // Heartbeat (1700000100) beats the newest message (1700000005).
        #expect(byID["root"] == 1_700_000_100.0)
        // No heartbeat → the message max carries it.
        #expect(byID["resetParent"] == 1_700_000_025.0)
        // Neither heartbeat nor messages → started_at fallback.
        #expect(byID["hiddenRoot"] == 1_700_000_010.0)
        await backend.close()
    }

    /// Without `last_read_at` the unread badge is unconditionally off, so
    /// the per-row subquery would buy nothing — and the emitted SQL stays
    /// byte-identical to the pre-v0.20.4 shape.
    @Test func lastActiveIsNotSelectedWithoutTheWatermarkColumn() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains("last_active") == false)
        #expect(sql.contains("_act_m") == false)
    }

    @Test func unreadSemanticsAtTheModelLevel() {
        func session(lastRead: Date?, activity: Date?, started: Date?, lastActive: Date? = nil) -> HermesSession {
            HermesSession(
                id: "s", source: "acp", userId: nil, model: nil, title: nil,
                parentSessionId: nil, startedAt: started, endedAt: nil, endReason: nil,
                messageCount: 0, toolCallCount: 0, inputTokens: 0, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUSD: nil,
                reasoningTokens: 0, actualCostUSD: nil, costStatus: nil, billingProvider: nil,
                lastActivityAt: activity, lastReadAt: lastRead, lastActive: lastActive
            )
        }
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let t2 = Date(timeIntervalSince1970: 3_000)
        // Never tracked → read.
        #expect(session(lastRead: nil, activity: t1, started: t0).isUnread == false)
        // Activity after the watermark → unread.
        #expect(session(lastRead: t0, activity: t1, started: t0).isUnread)
        // Watermark after the activity → read.
        #expect(session(lastRead: t1, activity: t0, started: t0).isUnread == false)
        // Equal → read (strictly-newer, matching Hermes's `>`).
        #expect(session(lastRead: t1, activity: t1, started: t0).isUnread == false)
        // Hermes's explicit "mark unread" writes 0 — any activity beats it.
        #expect(session(lastRead: Date(timeIntervalSince1970: 0), activity: t0, started: t0).isUnread)
        // No activity heartbeat → falls back to started_at.
        #expect(session(lastRead: t0, activity: nil, started: t1).isUnread)

        // `lastActive` — the list query's port of Hermes's
        // `_sql_session_last_active` — WINS over the heartbeat when
        // present, in both directions. This is the whole point: the
        // heartbeat is rate-limited and lags the message max.
        #expect(session(lastRead: t0, activity: nil, started: nil, lastActive: t1).isUnread)
        // Heartbeat says read, the message-inclusive term says unread.
        #expect(session(lastRead: t1, activity: t0, started: t0, lastActive: t2).isUnread)
        // …and the reverse: `lastActive` is authoritative, so a stale
        // heartbeat can't fabricate unread past it.
        #expect(session(lastRead: t2, activity: t1, started: t0, lastActive: t1).isUnread == false)
        // A NULL watermark still short-circuits regardless.
        #expect(session(lastRead: nil, activity: nil, started: nil, lastActive: t2).isUnread == false)
    }

    // MARK: - Query gating (mock backend — assert the emitted SQL)

    @Test func sessionQueriesAreUnchangedWhenColumnsAbsent() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let listSQL = try #require(await mock.queryLog.last?.sql)
        #expect(listSQL.contains("FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT ?"))
        #expect(!listSQL.contains("hidden"))
        #expect(!listSQL.contains("last_read_at"))
        #expect(!listSQL.contains("json_extract"))
        _ = await service.fetchSubagentSessions(parentId: "p")
        let childSQL = try #require(await mock.queryLog.last?.sql)
        #expect(childSQL.contains("WHERE parent_session_id = ? ORDER BY started_at ASC"))
        #expect(!childSQL.contains("json_extract"))
    }

    @Test func sessionQueriesAddHiddenFilterWhenColumnPresent() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasHiddenColumn(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains("parent_session_id IS NULL AND hidden = 0"))
        // `hidden` alone doesn't unlock the listable-child predicate.
        #expect(!sql.contains("json_extract"))
    }

    @Test func sessionSelectCarriesLastReadAtWhenColumnPresent() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasLastReadAtColumn(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains(", last_read_at"))
    }

    @Test func listablePredicateMirrorsHermesWhenSupported() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasHiddenColumn(true)
        await mock.setHasLastReadAtColumn(true)
        await mock.setHasListableChildSupport(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains("FROM sessions s WHERE"))
        #expect(sql.contains("s.parent_session_id IS NULL"))
        #expect(sql.contains("'$._branched_from'"))
        #expect(sql.contains("'$._reset_from'"))
        #expect(sql.contains("'session_reset'"))
        #expect(sql.contains("s.session_key = p.session_key"))
        #expect(sql.contains("s.hidden = 0"))
        // Portable JSON1 spelling, not the `->>` operator.
        #expect(!sql.contains("->>"))
        _ = await service.fetchSubagentSessions(parentId: "p")
        let childSQL = try #require(await mock.queryLog.last?.sql)
        #expect(childSQL.contains("s.parent_session_id = ?"))
        #expect(childSQL.contains("'$._reset_from'"))
        #expect(childSQL.contains("p.end_reason = 'compression'"))
    }
}

#endif
