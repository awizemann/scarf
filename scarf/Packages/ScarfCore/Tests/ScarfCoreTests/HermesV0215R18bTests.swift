#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Remediation R18b (Hermes v0.21.5 audit, R15 touched-surface findings,
/// task t-486aed3f).
///
/// - T2-F1: two registry rows at one path crashed every surface that built
///   a path → name map with `Dictionary(uniqueKeysWithValues:)`.
/// - T2-F2: a failed `state.db` read rendered as an empty or zero result.
/// - T2-F3: Dashboard / list previews came from a different population
///   than the rows they label.
/// - T1-F2 / T1-F3: the model-hint verb and the permission-timeout close.
@Suite struct HermesV0215R18bTests {

    // MARK: - Fixtures

    /// Registry with two rows at `/work/app` (the Doctor's `duplicatePath`)
    /// plus an ordinary row, written as raw JSON the way a hand edit or an
    /// older Add Project leaves it.
    static let duplicateRegistryJSON = """
    {"projects": [
      {"name": "App", "path": "/work/app"},
      {"name": "App (work)", "path": "/work/app"},
      {"name": "Other", "path": "/work/other"}
    ]}
    """

    static func makeHome(schema: String = HermesV0215StateDDL.schemaSQL + HermesV0215StateDDL.ftsSQL,
                         seed: String = HermesV0215SessionsDataR11Tests.seedSQL) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r18b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try exec(schema + seed, home: home)
        return home
    }

    static func exec(_ sql: String, home: URL) throws {
        var db: OpaquePointer?
        let path = home.appendingPathComponent("state.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture failed: \(msg)")
        }
    }

    static func writeScarfFile(_ name: String, _ text: String, home: URL) throws {
        let dir = home.appendingPathComponent("scarf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// Make every later `sessions` query fail on a handle that is already
    /// open — the shape of a read that breaks after a good load (a
    /// transient SSH drop, a locked or replaced database).
    static func breakSessionsTable(home: URL) throws {
        try exec("ALTER TABLE sessions RENAME TO sessions_gone;", home: home)
    }

    // MARK: - T2-F1: duplicate project paths

    @Test func projectNamesToleratesTwoRowsAtOnePath() {
        let projects = [
            ProjectEntry(name: "App", path: "/work/app"),
            ProjectEntry(name: "App (work)", path: "/work/app"),
            ProjectEntry(name: "Other", path: "/work/other"),
        ]
        let names = SessionAttributionService.projectNames(
            mappings: ["s1": "/work/app", "s2": "/work/other", "s3": "/elsewhere"],
            projects: projects
        )
        // First row at a path names it; unknown paths stay unattributed.
        #expect(names == ["s1": "App", "s2": "Other"])
    }

    @Test func restoreReanchorMappingToleratesADuplicatedSourcePath() {
        typealias Restored = RemoteRestoreService.RestoreResult.RestoredProject
        let mapping = RemoteRestoreService.reanchorMapping([
            Restored(name: "App", sourcePath: "/src/app", targetPath: "/dst/app"),
            Restored(name: "App (work)", sourcePath: "/src/app", targetPath: "/dst/app"),
            Restored(name: "Other", sourcePath: "/src/other", targetPath: "/dst/other"),
        ])
        #expect(mapping == ["/src/app": "/dst/app", "/src/other": "/dst/other"])
    }

    /// The whole re-anchor stage over a registry holding the duplicate:
    /// both rows at the old path move, nothing traps, unknown keys survive.
    @Test func restoreReanchorRewritesBothRowsAtADuplicatedPath() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r18b-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.writeScarfFile("projects.json", """
        {"schemaVersion": 7, "projects": [
          {"name": "App", "path": "/src/app"},
          {"name": "App (work)", "path": "/src/app"},
          {"name": "Other", "path": "/src/other"}
        ]}
        """, home: home)
        typealias Restored = RemoteRestoreService.RestoreResult.RestoredProject
        let restored = [
            Restored(name: "App", sourcePath: "/src/app", targetPath: "/dst/app"),
            Restored(name: "App (work)", sourcePath: "/src/app", targetPath: "/dst/app"),
            Restored(name: "Other", sourcePath: "/src/other", targetPath: "/dst/other"),
        ]
        let ctx = ServerContext.local(home: home)
        try await RemoteRestoreService(context: ctx).reanchorProjectsRegistry(
            transport: ctx.makeTransport(),
            hermesHome: home.path,
            mapping: RemoteRestoreService.reanchorMapping(restored)
        )
        let data = try Data(contentsOf: home.appendingPathComponent("scarf/projects.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let paths = (root["projects"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        #expect(paths == ["/dst/app", "/dst/app", "/dst/other"])
        #expect(root["schemaVersion"] as? Int == 7)
    }

    @MainActor
    @Test func addProjectRefusesAFolderAlreadyInTheList() async throws {
        try await ProjectsViewModelErrorSurfacingTests.withTempHome { ctx, path in
            try ProjectsViewModelErrorSurfacingTests.seed(
                [ProjectEntry(name: "site", path: "/tmp/r18b-site")], context: ctx
            )
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            // Another spelling of the same folder.
            #expect(await vm.addProject(name: "site again", path: "/tmp/r18b-site/") == false)
            #expect(vm.mutationError?.message.contains("already in the list as “site”") == true)
            let saved = try ProjectsViewModelErrorSurfacingTests.read(path)
            #expect(!saved.contains("site again"))
            // A different folder still adds.
            #expect(await vm.addProject(name: "other", path: "/tmp/r18b-other") == true)
        }
    }

    // MARK: - T2-F3: previews for the listed rows

    /// The R11 seed lists `live`, `chainTip` (root `chainRoot`) and
    /// `malformed`. Unlisted rows — `archivedRoot`, `delegateChild` — have
    /// NEWER first user messages than `malformed`, so "the newest 3
    /// previews" left `malformed` without one and its row showed its id.
    @Test func dashboardAndListPreviewsCoverExactlyTheListedRows() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())

        let dashboard = await service.dashboardSnapshot(sessionLimit: 3)
        #expect(Set(dashboard.recentSessions.map(\.id)) == ["live", "chainTip", "malformed"])
        #expect(dashboard.sessionPreviews["malformed"] == "malformed opening")
        #expect(dashboard.sessionPreviews["live"] == "real opening zebra")
        #expect(dashboard.sessionPreviews["chainTip"] != nil)
        #expect(dashboard.sessionPreviews["delegateChild"] == nil)
        #expect(dashboard.sessionPreviews["archivedRoot"] == nil)

        let list = await service.sessionListSnapshot(limit: 3)
        #expect(list.queryError == nil)
        #expect(list.previews["malformed"] == "malformed opening")
        #expect(list.previews["delegateChild"] == nil)
        #expect(list.previews["archivedRoot"] == nil)

        // The window follows the listing: with 1 row, only that row.
        let one = await service.sessionListSnapshot(limit: 1)
        #expect(one.sessions.map(\.id) == ["live"])
        #expect(Set(one.previews.keys) == ["live"])
    }

    // MARK: - T2-F2: failures are reported, not rendered as empty

    @Test func sessionListAndInsightsReportAQueryFailure() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        #expect(await service.sessionListSnapshot(limit: 10).queryError == nil)
        #expect(await service.insightsSnapshot(since: .distantPast).queryError == nil)

        try Self.breakSessionsTable(home: home)

        let list = await service.sessionListSnapshot(limit: 10)
        #expect(list.sessions.isEmpty)
        #expect(list.queryError?.contains("sessions") == true)
        #expect(await service.insightsSnapshot(since: .distantPast).queryError != nil)
        await #expect(throws: HermesDataService.QueryFailure.self) {
            _ = try await service.fetchSessionsInPeriodChecked(since: .distantPast)
        }
        await #expect(throws: HermesDataService.QueryFailure.self) {
            _ = try await service.fetchUsageAggregatesInPeriodChecked(since: .distantPast)
        }
        // The unchecked forms keep their old contract.
        #expect(await service.fetchSessionsInPeriod(since: .distantPast).isEmpty)
    }

    @MainActor
    @Test func insightsKeepsItsFiguresAndRaisesTheBannerOnAFailedReload() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = InsightsViewModel(context: .local(home: home))
        vm.period = .all
        await vm.load()
        #expect(vm.loadError == nil)
        let sessions = vm.sessions.count
        let tokens = vm.totalTokens
        #expect(sessions > 0)
        #expect(tokens > 0)

        try Self.breakSessionsTable(home: home)
        await vm.load()
        #expect(vm.loadError != nil)
        #expect(vm.isLoading == false)
        // Same period: the last good figures stay on screen.
        #expect(vm.sessions.count == sessions)
        #expect(vm.totalTokens == tokens)

        // A different period can't borrow them: cleared under the banner.
        vm.period = .week
        await vm.load()
        #expect(vm.loadError != nil)
        #expect(vm.sessions.isEmpty)
        #expect(vm.totalTokens == 0)
    }

    @MainActor
    @Test func projectSessionsKeepsRowsAndSaysWhyOnAFailedReload() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.writeScarfFile("session_project_map.json",
                                #"{"mappings": {"live": "/work/app"}}"#, home: home)
        let vm = ProjectSessionsViewModel(
            context: .local(home: home),
            project: ProjectEntry(name: "App", path: "/work/app")
        )
        await vm.load()
        #expect(vm.loadError == nil)
        #expect(vm.sessions.map(\.id) == ["live"])

        try Self.breakSessionsTable(home: home)
        await vm.load()
        #expect(vm.loadError != nil)
        #expect(vm.sessions.map(\.id) == ["live"])
        // Not blamed on Hermes having deleted the chats.
        #expect(vm.emptyStateHint?.contains("deleted") != true)
    }

    @MainActor
    @Test func projectSessionsWithAnUnreadableStoreDoesNotClaimTheChatsWereDeleted() async throws {
        let home = try Self.makeHome(schema: "CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT);", seed: "")
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.writeScarfFile("session_project_map.json",
                                #"{"mappings": {"live": "/work/app"}}"#, home: home)
        let vm = ProjectSessionsViewModel(
            context: .local(home: home),
            project: ProjectEntry(name: "App", path: "/work/app")
        )
        await vm.load()
        #expect(vm.sessions.isEmpty)
        #expect(vm.loadError?.lowercased().contains("no such column") == true)
        #expect(vm.emptyStateHint == nil)
    }

    // MARK: - T1-F2: the model hint names a real recovery

    @Test func unavailableModelHintNamesTheModelMenuNotAMissingVerb() throws {
        let hint = try #require(ACPErrorHint.classify(
            errorMessage: "Internal error",
            stderrTail: "openai.NotFoundError: Error code: 404 - {'error': {'code': 'model_not_found'}}"
        )?.hint)
        #expect(!hint.contains("sessions clone"))
        #expect(hint.contains("model menu"))
    }

    // MARK: - T1-F3: Hermes gave up waiting for a permission answer

    /// `session/request_permission` exactly as Hermes builds it: the tool
    /// call below is `_build_permission_tool_call("rm -rf build", "Delete
    /// build").model_dump(by_alias=True)` from the v2026.9.24 worktree.
    static let hermesPermissionRequest = #"""
    {"jsonrpc": "2.0", "id": 7, "method": "session/request_permission", "params": {
      "sessionId": "s",
      "toolCall": {"content": [{"content": {"text": "Delete build\n$ rm -rf build", "type": "text"}, "type": "content"}],
                   "kind": "execute", "rawInput": {"command": "rm -rf build", "description": "Delete build"},
                   "status": "pending", "title": "Delete build: rm -rf build", "toolCallId": "perm-check-1",
                   "sessionUpdate": "tool_call_update"},
      "options": [{"optionId": "allow_once", "kind": "allow_once", "name": "Allow once"},
                  {"optionId": "deny", "kind": "reject_once", "name": "Deny"}]}}
    """#

    /// The close `await_permission` sends after `FutureTimeout`
    /// (`update_tool_call(tool_call_id, status="failed")`, dumped the same way).
    static let hermesTimeoutClose = #"""
    {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s",
      "update": {"status": "failed", "toolCallId": "perm-check-1", "sessionUpdate": "tool_call_update"}}}
    """#

    static func raw(_ json: String) throws -> ACPRawMessage {
        try JSONDecoder().decode(ACPRawMessage.self, from: Data(json.utf8))
    }

    @MainActor private func engagedVM() -> RichChatViewModel {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "go")
        return vm
    }

    @Test func permissionRequestKeepsItsToolCallId() throws {
        let event = try #require(ACPEventParser.parsePermissionRequest(try Self.raw(Self.hermesPermissionRequest)))
        guard case let .permissionRequest(_, requestId, request) = event else {
            Issue.record("not a permission request"); return
        }
        #expect(requestId == 7)
        #expect(request.toolCallId == "perm-check-1")
    }

    @MainActor
    @Test func hermesTimingOutAPermissionClosesTheSheetAndSaysSo() throws {
        let vm = engagedVM()
        vm.handleACPEvent(try #require(ACPEventParser.parsePermissionRequest(try Self.raw(Self.hermesPermissionRequest))))
        #expect(vm.pendingPermission?.requestId == 7)

        vm.handleACPEvent(try #require(ACPEventParser.parse(notification: try Self.raw(Self.hermesTimeoutClose))))
        #expect(vm.pendingPermission == nil)
        #expect(vm.transientHint?.contains("stopped waiting") == true)
        #expect(vm.transientHint?.contains("Delete build: rm -rf build") == true)
    }

    /// The ordinary path: the user answers (the request is popped before
    /// the reply is sent, on Mac and iOS), then Hermes's close arrives.
    /// No hint, and nothing else in the queue is touched.
    @MainActor
    @Test func closeAfterTheUserAnsweredIsQuiet() throws {
        let vm = engagedVM()
        vm.handleACPEvent(try #require(ACPEventParser.parsePermissionRequest(try Self.raw(Self.hermesPermissionRequest))))
        vm.handleACPEvent(.permissionRequest(sessionId: "s", requestId: 8, request: ACPPermissionRequestEvent(
            toolCallTitle: "second", toolCallKind: "execute", options: [("deny", "Deny")], toolCallId: "perm-check-2"
        )))
        vm.resolvePermission(requestId: 7)
        vm.handleACPEvent(try #require(ACPEventParser.parse(notification: try Self.raw(Self.hermesTimeoutClose))))
        #expect(vm.transientHint == nil)
        #expect(vm.permissionQueue.map(\.requestId) == [8])
    }

    /// A real tool's completion (an id that had a `tool_call` start) never
    /// pops a permission request, even one carrying the same id.
    @MainActor
    @Test func aRealToolCompletionNeverPopsAPermission() {
        let vm = engagedVM()
        vm.handleACPEvent(.toolCallStart(sessionId: "s", call: ACPToolCallEvent(
            toolCallId: "t1", title: "bash", kind: "execute", status: "pending",
            content: "", rawInput: nil, locationPaths: []
        )))
        vm.handleACPEvent(.permissionRequest(sessionId: "s", requestId: 9, request: ACPPermissionRequestEvent(
            toolCallTitle: "x", toolCallKind: "execute", options: [("deny", "Deny")], toolCallId: "t1"
        )))
        vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: "t1", kind: "execute", status: "failed", content: "", rawOutput: nil
        )))
        #expect(vm.pendingPermission?.requestId == 9)
        #expect(vm.transientHint == nil)
    }
}

#endif
