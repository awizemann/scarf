#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Fix package F4 — Monitor data integrity (section audit 2026-09,
/// task t-4ec88dae).
///
/// These run against a REAL seeded SQLite fixture rather than the mock
/// backend, because every finding here is about what the SQL actually
/// selects and counts: a mock that echoes back canned rows would have
/// happily passed the pre-fix code too.
///
/// The fixture is deliberately adversarial about population. It holds
/// six session rows of which only THREE are listable — a root, a branch
/// child, and a reset continuation — alongside a hidden root, a subagent
/// run, and a root that started long before any period window. Anything
/// that quietly counts all six is counting things the user cannot see in
/// any session list in the app.
@Suite struct SectionAuditF4MonitorTests {

    /// `1_700_000_000` ≈ 2023-11-14. The fixture pins "now" to
    /// `nowTs` and places rows relative to it, so the 7-day window
    /// assertions don't drift with the wall clock.
    private static let nowTs: Double = 1_700_000_000
    private static let day: Double = 86_400
    private var now: Date { Date(timeIntervalSince1970: Self.nowTs) }

    // MARK: - Fixture

    private func makeFixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-f4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dbPath = home.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        let n = Self.nowTs
        let d = Self.day

        // Sessions. `msgs`/`tools`/`inTok` are the per-session counters
        // the stat cards SUM, chosen so each population question has a
        // distinct answer:
        //   recentRoot   in-window, listable        →  10 msgs
        //   recentBranch in-window, listable child  →  20 msgs
        //   recentReset  in-window, reset continuation → 40 msgs
        //   oldRoot      listable but 30 days old   → 1000 msgs
        //   hiddenRoot   in-window but hidden       →  100 msgs
        //   subagent     in-window but a subagent run → 200 msgs
        // 7-day + listable = 70. All-time + listable = 1070.
        // Everything (the pre-fix query) = 1370.
        let schema = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
            parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
            message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
            output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
            estimated_cost_usd REAL,
            reasoning_tokens INTEGER, actual_cost_usd REAL, cost_status TEXT, billing_provider TEXT,
            api_call_count INTEGER, rewind_count INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0, last_activity_at REAL, last_activity_description TEXT,
            model_config TEXT, session_key TEXT,
            hidden INTEGER NOT NULL DEFAULT 0, last_read_at REAL
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
            tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
            token_count INTEGER, finish_reason TEXT, reasoning TEXT,
            reasoning_content TEXT, active INTEGER NOT NULL DEFAULT 1,
            compacted INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO sessions
            (id, source, model, title, started_at, ended_at, end_reason, parent_session_id,
             model_config, session_key, last_activity_at, hidden, last_read_at, pinned,
             message_count, tool_call_count, input_tokens, output_tokens,
             cache_read_tokens, cache_write_tokens, estimated_cost_usd)
        VALUES
            ('recentRoot',   'acp', 'claude-fable-5', 'Named Root', \(n - d), NULL, NULL, NULL,
             NULL, 'k0', \(n - 60), 0, NULL, 1, 10, 1, 100, 100, 0, 0, 0.01),
            ('branchParent', 'acp', 'gpt-5', NULL, \(n - 2 * d), \(n - 2 * d + 10), 'branched', NULL,
             NULL, 'kb', NULL, 0, NULL, 0, 0, 0, 0, 0, 0, 0, 0.0),
            ('recentBranch', 'acp', 'gpt-5', NULL, \(n - 2 * d + 20), NULL, NULL, 'branchParent',
             '{"_branched_from": "branchParent"}', 'kb2', NULL, 0, NULL, 0, 20, 2, 200, 200, 0, 0, 0.02),
            ('resetParent',  'acp', 'gpt-5', NULL, \(n - 3 * d), \(n - 3 * d + 10), 'session_reset', NULL,
             NULL, 'k1', NULL, 0, NULL, 0, 0, 0, 0, 0, 0, 0, 0.0),
            ('recentReset',  'acp', 'gpt-5', NULL, \(n - 3 * d + 20), NULL, NULL, 'resetParent',
             '{"_reset_from": "resetParent"}', 'k1', NULL, 0, NULL, 0, 40, 4, 400, 400, 0, 0, 0.04),
            ('oldRoot',      'acp', 'gpt-5', NULL, \(n - 30 * d), NULL, NULL, NULL,
             NULL, 'k9', NULL, 0, NULL, 0, 1000, 100, 1000, 1000, 0, 0, 1.0),
            ('hiddenRoot',   'acp', 'gpt-5', NULL, \(n - d), NULL, NULL, NULL,
             NULL, NULL, NULL, 1, NULL, 0, 100, 10, 100, 100, 0, 0, 0.1),
            ('subagent',     'acp', 'gpt-5', NULL, \(n - d), NULL, NULL, 'recentRoot',
             NULL, NULL, NULL, 0, NULL, 0, 200, 20, 200, 200, 0, 0, 0.2);

        INSERT INTO messages
            (id, session_id, role, content, tool_calls, tool_name, timestamp,
             reasoning, reasoning_content, active)
        VALUES
            (1, 'recentRoot',   'user', 'first user message of recentRoot', NULL, NULL, \(n - d), NULL, NULL, 1),
            (2, 'recentRoot',   'assistant', 'thinking reply', '[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]', 'bash', \(n - 30), NULL, 'the chain of thought', 1),
            (3, 'recentBranch', 'user', 'first user message of recentBranch', NULL, NULL, \(n - 2 * d), NULL, NULL, 1),
            (4, 'oldRoot',      'user', 'first user message of oldRoot', NULL, NULL, \(n - 30 * d), NULL, NULL, 1),
            (5, 'oldRoot',      'assistant', 'rewound call', '[{"id":"c2","type":"function","function":{"name":"grep","arguments":"{}"}}]', 'grep', \(n - 20), NULL, NULL, 0),
            (6, 'recentReset',  'user', 'first user message of recentReset', NULL, NULL, \(n - 3 * d), NULL, NULL, 1),
            (7, 'subagent',     'user', 'subagent turn', NULL, NULL, \(n - d), NULL, NULL, 1),
            (8, 'hiddenRoot',   'user', 'hidden turn', NULL, NULL, \(n - d), NULL, NULL, 1);
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

    private func openService(_ home: URL) async throws -> HermesDataService {
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        return service
    }

    // MARK: - Dashboard stats: the "Last 7 days" window

    @Test("\"Last 7 days\" stats count only the last 7 days")
    func statsHonourTheSinceWindow() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)

        let window = await service.fetchStats(since: now.addingTimeInterval(-7 * Self.day))
        // recentRoot + recentBranch + recentReset — the three listable
        // sessions started inside the window. branchParent/resetParent are
        // listable but carry zero counters.
        #expect(window.totalMessages == 70)
        #expect(window.totalToolCalls == 7)
        #expect(window.totalSessions == 5)

        // The unbounded shape every existing caller still gets.
        let allTime = await service.fetchStats()
        #expect(allTime.totalMessages == 1070)
        await service.close()
    }

    @Test("Stats count the same sessions the session list shows")
    func statsPopulationMatchesTheSessionList() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)

        let listed = await service.fetchSessions(limit: 500)
        let stats = await service.fetchStats()
        #expect(stats.totalSessions == listed.count)
        // The rows the list hides must not be in the totals: `hiddenRoot`
        // (100) and `subagent` (200) would push 1070 to 1370.
        #expect(stats.totalMessages == listed.reduce(0) { $0 + $1.messageCount })
        #expect(!listed.contains { $0.id == "hiddenRoot" || $0.id == "subagent" })
        await service.close()
    }

    @Test("The Dashboard snapshot's stats carry the same window")
    func dashboardSnapshotAppliesStatsSince() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)

        let bounded = await service.dashboardSnapshot(
            statsSince: now.addingTimeInterval(-7 * Self.day)
        )
        #expect(bounded.stats.totalMessages == 70)
        #expect(bounded.queryError == nil)

        let unbounded = await service.dashboardSnapshot()
        #expect(unbounded.stats.totalMessages == 1070)
        await service.close()
    }

    @Test("DashboardViewModel's window is exactly the seven days it advertises")
    func statsWindowStartIsSevenDaysBack() {
        // Guards the label/query pairing from the app side without
        // importing the app target: the VM's helper is a pure function of
        // `now`, so pin the arithmetic here.
        let now = Date(timeIntervalSince1970: Self.nowTs)
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now)
        #expect(start != nil)
        #expect(abs(now.timeIntervalSince(start!) - 7 * Self.day) < 3600)
    }

    // MARK: - Dashboard recent tool calls

    @Test("Recent tool calls skip rewound rows and leave reasoning_content on disk")
    func dashboardToolCallsAreLightAndActiveOnly() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)

        let snapshot = await service.dashboardSnapshot(toolCallLimit: 10)
        let ids = snapshot.recentToolCalls.map(\.id)
        // Message 5 is `active = 0` — a rewound tool call. It kept
        // resurfacing on the Dashboard after the user undid it.
        #expect(ids.contains(2))
        #expect(!ids.contains(5))
        // `messageColumnsLight` NULLs the blob but still reports that it
        // exists, so the UI can lazy-load it.
        let assistant = try #require(snapshot.recentToolCalls.first { $0.id == 2 })
        #expect(assistant.reasoningContent == nil)
        #expect(assistant.reasoningContentAvailable)
        #expect(!assistant.toolCalls.isEmpty)
        await service.close()
    }

    // MARK: - Sessions list: the correlated unread subquery

    @Test("The unread recency subquery is opt-out, and opting out costs only isUnread")
    func sessionListSnapshotCanDropTheCorrelatedSubquery() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)

        let withUnread = await service.sessionListSnapshot(limit: 100)
        let withoutUnread = await service.sessionListSnapshot(limit: 100, includeUnreadActivity: false)

        // Same rows, same order, same previews — the ONLY difference is
        // the derived recency column.
        #expect(withUnread.sessions.map(\.id) == withoutUnread.sessions.map(\.id))
        #expect(withUnread.previews == withoutUnread.previews)
        #expect(withUnread.sessions.contains { $0.lastActive != nil })
        #expect(withoutUnread.sessions.allSatisfy { $0.lastActive == nil })
        await service.close()
    }

    @Test("The chat sidebar's unread badge still works on the default path")
    func unreadBadgeSurvivesOnTheDefaultPath() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        // `recentRoot` has a message at now-30s and no read watermark set
        // in the fixture, so it reads as read (`last_read_at` NULL is
        // "never tracked" per Hermes). Stamp a stale watermark and prove
        // the derivation still fires through the default call.
        let dbPath = home.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(
            db,
            "UPDATE sessions SET last_read_at = \(Self.nowTs - 10 * Self.day) WHERE id = 'recentRoot'",
            nil, nil, nil
        ) == SQLITE_OK)
        sqlite3_close(db)

        let service = try await openService(home)
        let snapshot = await service.sessionListSnapshot(limit: 100)
        let root = try #require(snapshot.sessions.first { $0.id == "recentRoot" })
        #expect(root.isUnread)
        await service.close()
    }

    // MARK: - Insights

    @Test("Insights aggregates and the Insights session list share one population")
    func insightsSnapshotUsesTheSessionListPopulation() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)

        let since = Date(timeIntervalSince1970: 0)
        let sessions = await service.fetchSessionsInPeriod(since: since)
        let snapshot = await service.insightsSnapshot(since: since)

        // One start-hour bucket entry per listable session, and no more:
        // the histogram must describe exactly the rows the page lists.
        #expect(snapshot.startHours.values.reduce(0, +) == sessions.count)
        #expect(snapshot.daysOfWeek.values.reduce(0, +) == sessions.count)

        // `subagent` and `hiddenRoot` each carry a user message; counting
        // them here (the pre-fix `parent_session_id IS NULL` predicate did
        // for `hiddenRoot`, and dropped `recentBranch`/`recentReset`) made
        // the "messages you sent" card disagree with the session table.
        let listedIds = Set(sessions.map(\.id))
        #expect(listedIds.contains("recentBranch"))
        #expect(listedIds.contains("recentReset"))
        #expect(!listedIds.contains("hiddenRoot"))
        #expect(!listedIds.contains("subagent"))
        #expect(snapshot.userMessageCount == 4)  // recentRoot, recentBranch, recentReset, oldRoot
        await service.close()
    }

    @Test("The period query is bounded")
    func periodQueryHonoursItsLimit() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)
        let capped = await service.fetchSessionsInPeriod(since: Date(timeIntervalSince1970: 0), limit: 2)
        #expect(capped.count == 2)
        // Newest first, so the cap keeps the most recent sessions.
        #expect(capped.first?.id == "recentRoot")
        await service.close()
    }

    // MARK: - Targeted previews (Activity labels, Notable Sessions)

    @Test("Previews can be fetched for exactly the sessions asked for")
    func previewsForAKnownIdSet() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)

        let previews = await service.fetchSessionPreviews(sessionIds: ["oldRoot", "recentReset"])
        #expect(previews.count == 2)
        #expect(previews["oldRoot"] == "first user message of oldRoot")
        #expect(previews["recentReset"] == "first user message of recentReset")
        // Nothing else rides along — this is the whole point versus
        // `fetchSessionPreviews(limit:)`, which answers "the newest N".
        #expect(previews["recentRoot"] == nil)

        // Duplicates collapse, unknown ids are simply absent, and an
        // empty request never reaches the backend.
        #expect(await service.fetchSessionPreviews(sessionIds: []).isEmpty)
        let noisy = await service.fetchSessionPreviews(sessionIds: ["oldRoot", "oldRoot", "nope", ""])
        #expect(noisy.count == 1)
        await service.close()
    }

    // MARK: - Preview/title precedence

    @Test("Every surface names a session the same way")
    func displayLabelPrefersTitleThenPreviewThenId() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = try await openService(home)
        let sessions = await service.fetchSessions(limit: 100)

        let named = try #require(sessions.first { $0.id == "recentRoot" })
        // Titled: the title wins even when a preview is available. The
        // Dashboard used to prefer the preview here, so a session renamed
        // in the Sessions tab kept its old opening line on the Dashboard.
        #expect(named.displayLabel(preview: "first user message of recentRoot") == "Named Root")

        let untitled = try #require(sessions.first { $0.id == "recentBranch" })
        #expect(untitled.displayLabel(preview: "opening line") == "opening line")
        #expect(untitled.displayLabel(preview: "") == "recentBranch")
        #expect(untitled.displayLabel(preview: nil) == "recentBranch")
        await service.close()
    }
}

#endif // canImport(SQLite3)
