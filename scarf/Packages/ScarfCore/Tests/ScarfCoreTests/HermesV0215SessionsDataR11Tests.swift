#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Remediation R11 (Hermes v0.21.5 audit, S04 sessions data, task
/// t-e5c479d1).
///
/// Every test here runs against a state.db built from Hermes's OWN v0.21.5
/// DDL (`HermesV0215StateDDL`, copied verbatim from
/// hermes_state_common.py @ v2026.9.24), so schema detection sees exactly
/// the columns a real host has. The seed below was also loaded into Hermes's
/// own `SessionDB` / `InsightsEngine` from the reference worktree and the
/// expected values checked against what Hermes itself lists and sums (see
/// the R11 report) — the numbers asserted here are Hermes's answers.
///
/// The seed, at `now` = 1_700_000_000:
///
/// | id             | shape                                         | listed? |
/// |----------------|-----------------------------------------------|---------|
/// | live           | root; hidden scaffolding rows; aux usage rows | yes     |
/// | archivedRoot   | root, `archived = 1`                          | no      |
/// | orphanDelegate | parentless, `_delegate_from='__orphaned__'`   | no      |
/// | delegateChild  | delegate subagent of `live`                   | no      |
/// | chainRoot      | rotated compression root                      | as tip  |
/// | chainMid       | continuation, itself compressed               | no      |
/// | chainTip       | live continuation                             | no      |
/// | malformed      | root whose model_config is not JSON           | yes     |
@Suite struct HermesV0215SessionsDataR11Tests {

    static let nowTs: Double = 1_700_000_000
    static let day: Double = 86_400

    // BEGIN R11 SEED (the Hermes cross-check script reads between these markers)
    static let seedSQL = """
    INSERT INTO sessions (id, source, model, title, parent_session_id, model_config, session_key,
        started_at, ended_at, end_reason, message_count, tool_call_count,
        input_tokens, output_tokens, estimated_cost_usd, cost_status, archived)
    VALUES
        ('live', 'cli', 'm-live', 'Live', NULL, NULL, 'k-live',
         1699913600, NULL, NULL, 10, 1, 100, 10, 0.01, 'estimated', 0),
        ('archivedRoot', 'cli', 'm', 'Archived', NULL, NULL, 'k-arch',
         1699913600, NULL, NULL, 5, 0, 50, 5, 0.05, 'estimated', 1),
        ('orphanDelegate', 'cli', 'm', NULL, NULL, '{"_delegate_from": "__orphaned__"}', NULL,
         1699913600, NULL, NULL, 3, 1, 30, 3, 0.03, 'estimated', 0),
        ('delegateChild', 'cli', 'm', NULL, 'live', '{"_delegate_from": "live"}', NULL,
         1699913600, NULL, NULL, 20, 2, 200, 20, 0.2, 'estimated', 0),
        ('chainRoot', 'cli', 'm-root', 'Chain Title', NULL, NULL, 'k-chain',
         1699827200, 1699827300, 'compression', 8, 0, 80, 8, 0.08, 'estimated', 0),
        ('chainMid', 'cli', 'm-mid', NULL, 'chainRoot', NULL, 'k-chain',
         1699827300, 1699827400, 'compression', 6, 0, 60, 6, 0.06, 'estimated', 0),
        ('chainTip', 'cli', 'tip-model', NULL, 'chainMid', NULL, 'k-chain',
         1699827400, NULL, NULL, 4, 0, 40, 4, 0.04, 'estimated', 0),
        ('malformed', 'cli', 'm', NULL, NULL, 'not json', NULL,
         1699740800, NULL, NULL, 1, 0, 0, 0, 0.0, 'estimated', 0);

    INSERT INTO messages (id, session_id, role, content, tool_name, timestamp, display_kind)
    VALUES
        (1, 'live', 'user', 'scaffold zebra', NULL, 1699913601, 'hidden'),
        (2, 'live', 'user', 'real opening zebra', NULL, 1699913602, NULL),
        (3, 'live', 'assistant', '', NULL, 1699913603, 'hidden'),
        (4, 'live', 'assistant', 'visible reply', NULL, 1699913604, NULL),
        (5, 'chainRoot', 'user', 'chain opening', NULL, 1699827201, NULL),
        (6, 'chainRoot', 'assistant', 'chain early reply', NULL, 1699827202, NULL),
        (7, 'chainMid', 'user', 'mid turn', NULL, 1699827301, NULL),
        (8, 'chainTip', 'user', 'tip turn', NULL, 1699827401, NULL),
        (9, 'chainTip', 'assistant', 'tip reply', NULL, 1699827402, NULL),
        (10, 'delegateChild', 'user', 'delegate task', NULL, 1699913605, NULL),
        (11, 'delegateChild', 'tool', 'ok', 'bash', 1699913606, NULL),
        (12, 'orphanDelegate', 'tool', 'ok', 'grep', 1699913607, NULL),
        (13, 'archivedRoot', 'user', 'archived hello', NULL, 1699913608, NULL),
        (14, 'malformed', 'user', 'malformed opening', NULL, 1699740801, NULL);

    INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens,
        estimated_cost_usd, cost_status)
    VALUES
        ('live', 'm-live', 100, 10, 0.01, 'estimated'),
        ('live', 'aux-vision', 50, 5, 0.005, 'estimated'),
        ('chainRoot', 'm-root', 10, 1, 0.001, 'estimated');
    """
    // END R11 SEED

    // MARK: - Fixture

    private func makeHome(schema: String = HermesV0215StateDDL.schemaSQL + HermesV0215StateDDL.ftsSQL,
                          seed: String = Self.seedSQL) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = home.appendingPathComponent("state.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, schema + seed, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture failed: \(msg)")
        }
        return home
    }

    private func open(_ home: URL) async -> HermesDataService {
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        return service
    }

    // MARK: - S04-F1: archived + orphaned-delegate rows leave the lists

    @Test func listHidesArchivedAndOrphanedDelegateRows() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)

        let ids = Set(try await service.fetchSessionsChecked(limit: 100).map(\.id))
        // Hermes's `list_sessions_rich()` on the same seed lists exactly
        // these three (the chain under its tip id).
        #expect(ids == ["live", "chainTip", "malformed"])

        let snapshot = await service.sessionListSnapshot(limit: 100)
        #expect(Set(snapshot.sessions.map(\.id)) == ids)
        let dashboard = await service.dashboardSnapshot(sessionLimit: 100)
        #expect(Set(dashboard.recentSessions.map(\.id)) == ids)
        let period = await service.fetchSessionsInPeriod(since: Date(timeIntervalSince1970: 0))
        #expect(!period.contains { $0.id == "archivedRoot" || $0.id == "orphanDelegate" })
        await service.close()
    }

    @Test func malformedModelConfigDoesNotFailTheList() async throws {
        // Hermes guards every JSON marker lookup with json_valid; a bare
        // json_extract over 'not json' is a hard SQL error that would turn
        // the whole list into "No sessions".
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)
        let listed = try await service.fetchSessionsChecked(limit: 100)
        #expect(listed.contains { $0.id == "malformed" })
        await service.close()
    }

    @Test func listSQLGainsArchivedClauseOnlyWhenTheColumnExists() async throws {
        let absent = MockHermesQueryBackend()
        let old = HermesDataService(context: .local, backend: absent)
        #expect(await old.open())
        _ = await old.fetchSessions()
        let oldSQL = try #require(await absent.queryLog.last?.sql)
        #expect(!oldSQL.contains("archived"))
        #expect(!oldSQL.contains("_delegate_from"))

        let present = MockHermesQueryBackend()
        await present.setHasArchivedColumn(true)
        let v016 = HermesDataService(context: .local, backend: present)
        #expect(await v016.open())
        _ = await v016.fetchSessions()
        let sql = try #require(await present.queryLog.last?.sql)
        #expect(sql.contains("parent_session_id IS NULL AND archived = 0"))

        let full = MockHermesQueryBackend()
        await full.setHasArchivedColumn(true)
        await full.setHasHiddenColumn(true)
        await full.setHasLastReadAtColumn(true)
        await full.setHasListableChildSupport(true)
        let current = HermesDataService(context: .local, backend: full)
        #expect(await current.open())
        _ = await current.fetchSessions()
        let fullSQL = try #require(await full.queryLog.last?.sql)
        #expect(fullSQL.contains("'$._delegate_from') IS NULL"))
        #expect(fullSQL.contains("json_valid(s.model_config)"))
        #expect(fullSQL.contains("s.archived = 0 AND s.hidden = 0"))
    }

    // MARK: - S04-F2: usage totals include every session row

    @Test func statsCountConversationsButSumAllUsage() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)
        let since = Date(timeIntervalSince1970: Self.nowTs - 7 * Self.day)

        let stats = await service.fetchStats(since: since)
        // Count: the three listed conversations (chainRoot is the row the
        // list predicate admits for the chain).
        #expect(stats.totalSessions == 3)
        // Sums: every session row in the window, like `hermes insights`
        // (total_messages 57, total_input_tokens 610 on this seed). `live`
        // counts max(100, 100 + 50 aux) = 150 input tokens; `chainRoot`
        // keeps its 80 over its smaller per-model row.
        #expect(stats.totalMessages == 57)
        #expect(stats.totalToolCalls == 4)
        #expect(stats.totalInputTokens == 610)
        #expect(abs(stats.totalCostUSD - 0.475) < 1e-9)

        let dashboard = await service.dashboardSnapshot(statsSince: since)
        #expect(dashboard.stats.totalSessions == 3)
        #expect(dashboard.stats.totalInputTokens == 610)
        #expect(dashboard.queryError == nil)
        await service.close()
    }

    @Test func insightsUsagePopulationMatchesHermesInsights() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)
        let since = Date(timeIntervalSince1970: 0)

        let usage = await service.fetchUsageSessionsInPeriod(since: since)
        #expect(usage.count == 8)
        #expect(usage.reduce(0) { $0 + $1.inputTokens } == 610)
        let live = try #require(usage.first { $0.id == "live" })
        #expect(live.inputTokens == 150)
        #expect(live.outputTokens == 15)

        let snapshot = await service.insightsSnapshot(since: since)
        // Hermes's message stats: user rows across every session (hidden
        // display rows included — Hermes counts rows, not bubbles).
        #expect(snapshot.userMessageCount == 8)
        let tools = Dictionary(uniqueKeysWithValues: snapshot.toolUsage.map { ($0.name, $0.count) })
        #expect(tools == ["bash": 1, "grep": 1])
        // The start-time histogram still counts conversations.
        let listed = await service.fetchSessionsInPeriod(since: since)
        #expect(snapshot.startHours.values.reduce(0, +) == listed.count)
        await service.close()
    }

    @Test func usageSourceIsPlainSessionsWithoutTheModelUsageTable() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchStats(since: Date(timeIntervalSince1970: 0))
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(!sql.contains("session_model_usage"))
        #expect(sql.contains("FROM sessions WHERE started_at >= ?"))
        #expect(await mock.queryLog.last?.params.count == 2)
    }

    // MARK: - S04-F3: rotated compression chains list as their tip

    @Test func compressionChainListsAsItsTipWithTheWholeLineage() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)

        let snapshot = await service.sessionListSnapshot(limit: 100)
        let chain = try #require(snapshot.sessions.first { $0.id == "chainTip" })
        #expect(chain.lineageIds == ["chainRoot", "chainMid", "chainTip"])
        // Hermes's projection: tip id and live fields, root title carried
        // when the tip has none, root started_at kept for ordering.
        #expect(chain.title == "Chain Title")
        #expect(chain.messageCount == 4)
        #expect(chain.model == "tip-model")
        #expect(chain.endReason == nil)
        #expect(chain.startedAt == Date(timeIntervalSince1970: 1_699_827_200))
        #expect(chain.covers("chainRoot"))
        // The tip's preview, not the ended root's.
        #expect(snapshot.previews["chainTip"] == "tip turn")

        let transcript = await service.fetchMessages(sessionIds: chain.allSessionIds, limit: 100)
        #expect(transcript.map(\.id) == [5, 6, 7, 8, 9])
        await service.close()
    }

    @Test func chainWalkStopsAtACycle() async throws {
        // Two compression-ended rows parented on each other: a corrupt
        // lineage the walk must survive, not follow forever.
        let seed = """
        INSERT INTO sessions (id, source, parent_session_id, started_at, ended_at, end_reason)
        VALUES ('a', 'cli', 'b', 1, 2, 'compression'),
               ('b', 'cli', 'a', 2, 3, 'compression');
        """
        let home = try makeHome(seed: seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)
        // a → b → a: cut at the repeat, as the per-hop walk's seen-set does.
        let chains = try await service.compressionChains(for: ["a"])
        #expect(chains["a"] == ["a", "b"])
        #expect(await service.compressionTip(for: "a") == "b")
        await service.close()
    }

    @Test func liveChildOutranksAStaleClosedSibling() async throws {
        let seed = """
        INSERT INTO sessions (id, source, parent_session_id, started_at, ended_at, end_reason)
        VALUES ('r', 'cli', NULL, 0, 1, 'compression'),
               ('stale', 'cli', 'r', 1, 5, 'ws_orphan_reap'),
               ('live', 'cli', 'r', 1, NULL, NULL);
        """
        let home = try makeHome(seed: seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)
        #expect(try await service.compressionChains(for: ["r"])["r"] == ["r", "live"])
        await service.close()
    }

    @Test func resetForkIsNotAContinuation() async throws {
        // Hermes excludes a reset fork of a compression-ended parent from
        // the chain walk (#114271).
        let seed = """
        INSERT INTO sessions (id, source, session_key, parent_session_id, model_config, started_at, ended_at, end_reason)
        VALUES ('root', 'cli', 'k', NULL, NULL, 1, 2, 'compression'),
               ('fork', 'cli', 'k', 'root', '{"_reset_from": "root"}', 3, NULL, NULL);
        """
        let home = try makeHome(seed: seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)
        #expect(await service.compressionTip(for: "root") == "root")
        #expect(try await service.compressionChains(for: ["root"]).isEmpty)
        await service.close()
    }

    @Test func projectionIsSkippedOnPreV0204Hosts() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let log = await mock.queryLog
        #expect(log.count == 1)
        #expect(!log.contains { $0.sql.contains("WITH RECURSIVE") })
    }

    @Test func lineageLabelsFollowTheChain() {
        func session(_ id: String, lineage: [String] = []) -> HermesSession {
            HermesSession(
                id: id, source: "cli", userId: nil, model: nil, title: nil, parentSessionId: nil,
                startedAt: nil, endedAt: nil, endReason: nil, messageCount: 0, toolCallCount: 0,
                inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                estimatedCostUSD: nil, reasoningTokens: 0, actualCostUSD: nil, costStatus: nil,
                billingProvider: nil, lineageIds: lineage
            )
        }
        let labels = HermesSession.carryingLineageLabels(
            ["root": "Project A", "plain": "Project B", "tip2": "Own"],
            onto: [session("tip", lineage: ["root", "tip"]), session("plain"),
                   session("tip2", lineage: ["root2", "tip2"])]
        )
        #expect(labels["tip"] == "Project A")
        #expect(labels["plain"] == "Project B")
        #expect(labels["tip2"] == "Own")
    }

    // MARK: - S04-F4: display_kind = 'hidden' rows stay out of sight

    @Test func hiddenDisplayRowsLeaveTranscriptSearchAndPreview() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await open(home)

        let transcript = await service.fetchMessages(sessionId: "live", limit: 100)
        #expect(transcript.map(\.id) == [2, 4])
        let skeleton = await service.fetchSkeletonMessages(sessionId: "live", limit: 100)
        #expect(skeleton.messages.map(\.id) == [2, 4])

        let hits = try await service.searchMessagesChecked(query: "zebra")
        #expect(hits.map(\.id) == [2])

        #expect(await service.fetchSessionPreview(sessionId: "live") == "real opening zebra")
        let previews = await service.fetchSessionPreviews(sessionIds: ["live"])
        #expect(previews["live"] == "real opening zebra")
        let listPreviews = await service.sessionListSnapshot(limit: 100).previews
        #expect(listPreviews["live"] == "real opening zebra")
        await service.close()
    }

    @Test func displayKindFilterIsGatedOnTheColumn() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchMessages(sessionId: "x", limit: 10)
        let oldSQL = try #require(await mock.queryLog.last?.sql)
        #expect(!oldSQL.contains("display_kind"))
        #expect(SessionPreviewSQL.firstEligibleUserRowSQL(hasActiveColumn: true, hasCompactedColumn: true)
            == SessionPreviewSQL.firstEligibleUserRowSQL(
                hasActiveColumn: true, hasCompactedColumn: true, hasDisplayKindColumn: false))

        let current = MockHermesQueryBackend()
        await current.setHasMessagesActiveColumn(true)
        await current.setHasDisplayKindColumn(true)
        let v0191 = HermesDataService(context: .local, backend: current)
        #expect(await v0191.open())
        _ = await v0191.fetchMessages(sessionId: "x", limit: 10)
        let sql = try #require(await current.queryLog.last?.sql)
        #expect(sql.contains("AND active = 1 AND COALESCE(display_kind, '') <> 'hidden'"))
    }

    /// The same answers through `RemoteSQLiteBackend` — the real heredoc
    /// into `sqlite3 -readonly -json`, driven over `LocalTransport` — so the
    /// recursive CTE, the usage derived table and the display filter are
    /// proven on the SSH query path, not only the in-process one.
    @Test func remoteBackendGivesTheSameAnswers() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = ServerContext.local(home: home)
        let backend = RemoteSQLiteBackend(context: context, transport: LocalTransport(contextID: context.id))
        let service = HermesDataService(context: context, backend: backend)
        #expect(await service.open())
        #expect(await backend.hasArchivedColumn)
        #expect(await backend.hasDisplayKindColumn)

        let snapshot = await service.sessionListSnapshot(limit: 100)
        #expect(Set(snapshot.sessions.map(\.id)) == ["live", "chainTip", "malformed"])
        let chain = try #require(snapshot.sessions.first { $0.id == "chainTip" })
        #expect(chain.lineageIds == ["chainRoot", "chainMid", "chainTip"])
        #expect(snapshot.previews["chainTip"] == "tip turn")
        #expect(snapshot.previews["live"] == "real opening zebra")

        let stats = await service.fetchStats(since: Date(timeIntervalSince1970: Self.nowTs - 7 * Self.day))
        #expect(stats.totalSessions == 3)
        #expect(stats.totalInputTokens == 610)

        #expect(await service.fetchMessages(sessionId: "live", limit: 100).map(\.id) == [2, 4])
        #expect(await service.fetchMessages(sessionIds: chain.allSessionIds, limit: 100).map(\.id) == [5, 6, 7, 8, 9])
        #expect(try await service.searchMessagesChecked(query: "zebra").map(\.id) == [2])
        await service.close()
    }

    @Test func localAndRemoteDetectTheNewColumns() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let local = LocalSQLiteBackend(context: .local(home: home))
        #expect(await local.open())
        #expect(await local.hasArchivedColumn)
        #expect(await local.hasDisplayKindColumn)
        await local.close()

        let old = try makeHome(
            schema: """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, started_at REAL);
            CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL);
            """,
            seed: ""
        )
        defer { try? FileManager.default.removeItem(at: old) }
        let legacy = LocalSQLiteBackend(context: .local(home: old))
        #expect(await legacy.open())
        #expect(await legacy.hasArchivedColumn == false)
        #expect(await legacy.hasDisplayKindColumn == false)
        await legacy.close()
    }
}

#endif
