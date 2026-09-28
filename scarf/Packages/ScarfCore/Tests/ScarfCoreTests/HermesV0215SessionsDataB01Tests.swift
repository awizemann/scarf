#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Blind re-audit B01: S04-sessions-data-F3 (internal session sources stay
/// out of the lists) and S11-projects-core-F1 (a project's Sessions tab
/// queries its attributed sessions directly instead of filtering the host's
/// newest 200).
///
/// Runs on Hermes's own v0.21.5 DDL (`HermesV0215StateDDL`). The listing
/// expectation was checked against Hermes's `list_sessions_rich(
/// exclude_sources=list(INTERNAL_LISTING_SOURCES))` on the same seed.
@Suite struct HermesV0215SessionsDataB01Tests {

    static let sourcesSeed = """
    INSERT INTO sessions (id, source, started_at) VALUES
        ('chat', 'cli', 1700000100),
        ('tg', 'telegram', 1700000090),
        ('worker', 'kanban', 1700000080),
        ('integration', 'tool', 1700000070),
        ('once', 'oneshot', 1700000060);
    """

    private static func open(_ home: URL) async -> HermesDataService {
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        return service
    }

    // MARK: - S04-F3

    @Test func listsLeaveOutKanbanToolAndOneshotSessions() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.sourcesSeed)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await Self.open(home)
        let listed = try await service.fetchSessionsChecked(limit: 50).map(\.id)
        #expect(listed == ["chat", "tg"])
        let snapshot = await service.sessionListSnapshot(limit: 50)
        #expect(snapshot.sessions.map(\.id) == ["chat", "tg"])
        let dashboard = await service.dashboardSnapshot(
            sessionLimit: 50, statsSince: Date(timeIntervalSince1970: 0))
        #expect(dashboard.recentSessions.map(\.id) == ["chat", "tg"])
        #expect(dashboard.stats.totalSessions == 2)
        await service.close()
    }

    @Test func preListableHostsGetTheUnaliasedSourceClause() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains("COALESCE(source, '') NOT IN ('kanban', 'tool', 'oneshot') AND parent_session_id IS NULL"))
    }

    // MARK: - S11-F1

    /// 250 cron runs newer than the project's chat, so the chat is far
    /// outside the host's newest 200.
    static var busyHostSeed: String {
        var cron: [String] = []
        for i in 0..<250 {
            cron.append("('cron_\(i)', 'cron', \(1_700_100_000 + i))")
        }
        return """
        INSERT INTO sessions (id, source, started_at) VALUES
            ('projectChat', 'acp', 1700000000),
            \(cron.joined(separator: ",\n    "));
        INSERT INTO sessions (id, source, started_at, ended_at, end_reason, parent_session_id) VALUES
            ('chainRoot', 'acp', 1700000010, 1700000020, 'compression', NULL),
            ('chainTip', 'acp', 1700000020, NULL, NULL, 'chainRoot');
        """
    }

    @MainActor
    @Test func projectTabFindsAttributedSessionsOutsideTheNewest200() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.busyHostSeed)
        defer { try? FileManager.default.removeItem(at: home) }
        // The chain was attributed under its continuation id (a chat
        // resumed after its session rotated); the list shows it at its tip.
        try HermesV0215R18bTests.writeScarfFile(
            "session_project_map.json",
            #"{"mappings": {"projectChat": "/work/app", "chainTip": "/work/app"}}"#,
            home: home)
        let vm = ProjectSessionsViewModel(
            context: .local(home: home),
            project: ProjectEntry(name: "App", path: "/work/app")
        )
        await vm.load()
        #expect(vm.loadError == nil)
        #expect(vm.sessions.map(\.id) == ["chainTip", "projectChat"])
        #expect(vm.sessions.first?.lineageIds == ["chainRoot", "chainTip"])
        #expect(vm.emptyStateHint == nil)
    }

    @MainActor
    @Test func projectTabSaysHermesNoLongerListsMissingSessions() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.busyHostSeed)
        defer { try? FileManager.default.removeItem(at: home) }
        try HermesV0215R18bTests.writeScarfFile(
            "session_project_map.json",
            #"{"mappings": {"gone1": "/work/app", "gone2": "/work/app"}}"#,
            home: home)
        let vm = ProjectSessionsViewModel(
            context: .local(home: home),
            project: ProjectEntry(name: "App", path: "/work/app")
        )
        await vm.load()
        #expect(vm.sessions.isEmpty)
        #expect(vm.emptyStateHint == ProjectSessionsViewModel.noListedSessionsHint(attributedCount: 2))
        #expect(vm.emptyStateHint?.contains("no longer lists") == true)
        #expect(vm.emptyStateHint?.contains("recent history") == false)
    }

    @Test func attributedLookupChunksTheIds() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.busyHostSeed)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await Self.open(home)
        let wanted: Set<String> = ["cron_0", "cron_1", "cron_2", "cron_3", "projectChat", "missing"]
        let found = try await service.fetchListedSessionsChecked(owning: wanted, chunkSize: 2)
        #expect(found.map(\.id) == ["cron_3", "cron_2", "cron_1", "cron_0", "projectChat"])
        #expect(try await service.fetchListedSessionsChecked(owning: []).isEmpty)
        await service.close()
    }
}

#endif
