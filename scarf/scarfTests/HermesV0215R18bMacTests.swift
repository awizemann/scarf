import Testing
import Foundation
import SQLite3
import ScarfCore
@testable import scarf

/// Remediation R18b (task t-486aed3f), Mac-target half.
///
/// T2-F1 (P1): two registry rows at one path trapped
/// `Dictionary(uniqueKeysWithValues:)` on every Sessions tab load and every
/// chat sidebar refresh, so the app crashed on launch into either and kept
/// crashing until `projects.json` was edited by hand. These drive the real
/// view models against a scratch Hermes home with a real `state.db`.
///
/// Also: T2-F2 (a failed read keeps the last good rows and says so),
/// T1-F4 (a sidebar delete that deleted nothing says so), T1-F1 (the Bot
/// Chat CLI turn is not killed at 300 s, and a failed turn still shows
/// what Hermes saved), and the template installer's duplicate-path refusal.
struct HermesV0215R18bMacTests {

    // MARK: - Fixtures

    /// The pre-v0.7 `sessions` / `messages` shape `HermesDataService`
    /// reads (every column its list and message SELECTs name).
    static let schemaSQL = """
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
        parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
        message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
        estimated_cost_usd REAL
    );
    CREATE TABLE messages (
        id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT,
        tool_calls TEXT, tool_name TEXT, timestamp REAL, token_count INTEGER, finish_reason TEXT
    );
    INSERT INTO sessions (id, source, title, started_at, message_count) VALUES ('s1', 'cli', 'one', 1.0, 1);
    INSERT INTO sessions (id, source, title, started_at, message_count) VALUES ('s2', 'cli', 'two', 2.0, 1);
    INSERT INTO messages (id, session_id, role, content, timestamp) VALUES (1, 's1', 'user', 'first', 1.5);
    INSERT INTO messages (id, session_id, role, content, timestamp) VALUES (2, 's2', 'user', 'second', 2.5);
    """

    static func exec(_ sql: String, dbAt dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = dir.appendingPathComponent("state.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "fixture open failed")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture exec failed: \(msg)")
        }
    }

    /// A home with a state.db, two registry rows at `/work/app` (the
    /// Doctor's `duplicatePath`, written raw the way a hand edit or an
    /// older Add Project leaves it) and `s1` attributed to that path.
    static func duplicateRegistryHome() throws -> TempHermesHome {
        let home = try TempHermesHome()
        try exec(schemaSQL, dbAt: home.url)
        let scarf = home.url.appendingPathComponent("scarf", isDirectory: true)
        try FileManager.default.createDirectory(at: scarf, withIntermediateDirectories: true)
        try Data("""
        {"projects": [
          {"name": "App", "path": "/work/app"},
          {"name": "App (work)", "path": "/work/app"}
        ]}
        """.utf8).write(to: scarf.appendingPathComponent("projects.json"))
        try Data(#"{"mappings": {"s1": "/work/app"}}"#.utf8)
            .write(to: scarf.appendingPathComponent("session_project_map.json"))
        return home
    }

    /// Break every later `sessions` query on a handle that is already open.
    static func breakSessionsTable(_ home: TempHermesHome) throws {
        try exec("ALTER TABLE sessions RENAME TO sessions_gone;", dbAt: home.url)
    }

    // MARK: - T2-F1: the crashing sites

    @Test @MainActor func sessionsTabLoadsWithTwoProjectsAtOnePath() async throws {
        let home = try Self.duplicateRegistryHome()
        defer { home.cleanup() }
        let vm = SessionsViewModel(context: home.context)
        await vm.load()
        #expect(vm.loadError == nil)
        #expect(vm.sessions.map(\.id) == ["s2", "s1"])
        let s1 = try #require(vm.sessions.first { $0.id == "s1" })
        #expect(vm.projectName(for: s1) == "App")
        #expect(vm.allProjects.count == 2)
    }

    @Test @MainActor func chatSidebarRefreshesWithTwoProjectsAtOnePath() async throws {
        let home = try Self.duplicateRegistryHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        await vm.loadRecentSessions()
        #expect(vm.recentSessions.map(\.id) == ["s2", "s1"])
        let s1 = try #require(vm.recentSessions.first { $0.id == "s1" })
        #expect(vm.projectName(for: s1) == "App")
    }

    // MARK: - T2-F2: a failed read keeps the last good rows

    @Test @MainActor func sessionsTabKeepsItsRowsAndRaisesTheBannerOnAFailedReload() async throws {
        let home = try Self.duplicateRegistryHome()
        defer { home.cleanup() }
        let vm = SessionsViewModel(context: home.context)
        await vm.load()
        #expect(vm.sessions.count == 2)

        try Self.breakSessionsTable(home)
        await vm.load()
        #expect(vm.loadError?.contains("sessions") == true)
        #expect(vm.sessions.map(\.id) == ["s2", "s1"], "a failed tick must not wipe a loaded list")
        #expect(vm.isLoading == false)
    }

    @Test @MainActor func sessionsTabWithAnUnreadableStoreSaysSoFromTheFirstLoad() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try Self.exec("CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT);", dbAt: home.url)
        let vm = SessionsViewModel(context: home.context)
        await vm.load()
        #expect(vm.sessions.isEmpty)
        #expect(vm.loadError?.lowercased().contains("no such column") == true)
    }

    @Test @MainActor func chatSidebarKeepsItsRowsOnAFailedRefresh() async throws {
        let home = try Self.duplicateRegistryHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        await vm.loadRecentSessions()
        #expect(vm.recentSessions.count == 2)
        try Self.breakSessionsTable(home)
        await vm.loadRecentSessions()
        #expect(vm.recentSessions.map(\.id) == ["s2", "s1"])
    }

    // MARK: - T1-F4: a sidebar delete that deleted nothing says so

    @Test @MainActor func sidebarDeleteThatFailsOutrightSaysSo() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        vm.sessionDeleteRunner = { _, _ in 1 }
        await vm.deleteSession("gone")
        let hint = try #require(vm.richChatViewModel.transientHint)
        #expect(hint.contains("Couldn't delete that session"))
        #expect(hint.contains("exited 1"))
    }

    // MARK: - Template installer: one folder, one row

    @Test func templateInstallRefusesAPathARegistryRowAlreadyClaims() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])
        let service = ProjectTemplateService(context: home.context)
        let inspection = try await service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        // A row whose folder is gone, at the path the install would use —
        // spelled with a trailing slash, so the check has to normalize.
        try ProjectDashboardService(context: home.context).saveRegistry(
            ProjectRegistry(projects: [ProjectEntry(name: "Old", path: plan.projectDir + "/")]),
            allowEmpty: true
        )

        #expect(throws: ProjectTemplateError.self) {
            try ProjectTemplateInstaller(context: home.context).install(plan: plan)
        }
        // Refused in preflight: nothing was created.
        #expect(!FileManager.default.fileExists(atPath: plan.projectDir))
        let rows = ProjectDashboardService(context: home.context).loadRegistry().projects
        #expect(rows.map(\.name) == ["Old"])
    }

    @Test func registeredPathRefusalNamesTheExistingRow() {
        #expect(throws: (any Error).self) {
            try ProjectTemplateInstaller.refuseRegisteredPath(
                "/p/app", in: [ProjectEntry(name: "Old", path: "/p/./app")]
            )
        }
        #expect(ProjectTemplateError.projectPathRegistered(path: "/p/app", name: "Old")
            .errorDescription?.contains("“Old”") == true)
        #expect((try? ProjectTemplateInstaller.refuseRegisteredPath(
            "/p/app", in: [ProjectEntry(name: "Other", path: "/p/other")]
        )) != nil)
    }

    // MARK: - T1-F1: Bot Chat CLI turns

    /// Hermes' own Bot Mode runs this command with no limit
    /// (`_run_local_turn`, tools/bot_mode_dm.py:411-421 @ v2026.9.24). The
    /// ceiling exists only because every subprocess needs one; it must be
    /// far past any turn a user waits on — it was 300 s.
    @Test func botChatCLITurnIsNotKilledAtFiveMinutes() {
        #expect(BotConversationViewModel.cliTurnCeiling >= 12 * 60 * 60)
    }

    /// A turn that fails part-way can have saved the prompt and part of a
    /// reply. The poll stops on failure, so the transcript is read once
    /// more first; before, the saved reply stayed invisible until the chat
    /// was reopened.
    @Test @MainActor func failedCLITurnStillShowsWhatHermesSaved() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let botHome = home.url.appendingPathComponent("profiles/scout", isDirectory: true)
        try Self.exec("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
            parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
            message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
            output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
            estimated_cost_usd REAL
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT,
            tool_calls TEXT, tool_name TEXT, timestamp REAL, token_count INTEGER, finish_reason TEXT
        );
        INSERT INTO sessions (id, source, title, started_at) VALUES ('bot-chat-1', 'cli', 'Bot Chat', 1.0);
        """, dbAt: botHome)

        let vm = BotConversationViewModel(
            profileName: "scout",
            context: home.context,
            locator: { _ in HermesDataService.CanonicalBotChat(registryId: "bot-chat-1", liveId: "bot-chat-1", liveSource: "cli") },
            creator: { _, _, text in
                // What Hermes persisted before the turn died.
                try? HermesV0215R18bMacTests.exec("""
                INSERT INTO messages (session_id, role, content, timestamp) VALUES ('bot-chat-1', 'user', '\(text)', 10.0);
                INSERT INTO messages (session_id, role, content, timestamp, finish_reason) VALUES ('bot-chat-1', 'assistant', 'partial reply', 11.0, 'stop');
                """, dbAt: botHome)
                return "hermes exited 1: provider went away"
            },
            acpClientMaker: { ctx, _, _ in ACPClient(context: ctx) { _ in BotConversationTests.InertACPChannel() } }
        )
        vm.open()
        for _ in 0..<50 where vm.delivery != .cliTransport { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(vm.delivery == .cliTransport)

        vm.send("hello")
        let rich = vm.chat.richChatViewModel
        for _ in 0..<100 where rich.acpError == nil { try await Task.sleep(nanoseconds: 20_000_000) }

        #expect(rich.acpError == "hermes exited 1: provider went away")
        #expect(rich.isAgentWorking == false)
        #expect(rich.messages.contains { $0.isAssistant && $0.content == "partial reply" })
        vm.close()
    }
}
