#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Hermes v0.22.5 parity, slice S5 — session source display and session
/// fixes:
///
/// - `sessions.created_source` (v0.21.6, hermes_state_common.py:385) is
///   probed and decoded; from v0.22.3 Hermes stores cli/tui/gui/acp
///   sessions as `source='local'`, and `HermesSession.displaySource`
///   resolves the real surface (gateway/session_policy.py:85-105 @ v0.22.5).
/// - A host without the column emits the same SELECT as before.
/// - `last_active` honours Hermes's `coerce_epoch` window
///   (`_sql_freshest_of`, hermes_state_common.py:250-271 @ v0.22.5).
/// - `hermes sessions delete` refusals surface Hermes's own line
///   (hermes_cli/sessions_cmd.py:645-660 @ v0.22.5).
///
/// DB tests run on Hermes's own v0.21.5 DDL; the "v0.21.6+" fixture adds
/// `created_source` with the same `ALTER TABLE … ADD COLUMN` Hermes's
/// `_reconcile_columns` applies to a legacy store.
@Suite struct HermesV0225SessionSourceTests {

    // MARK: - Fixture DB

    private func makeHome(createdSource: Bool, seed: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-s5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = home.appendingPathComponent("state.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let alter = createdSource ? "ALTER TABLE sessions ADD COLUMN created_source TEXT;\n" : ""
        let sql = HermesV0215StateDDL.schemaSQL + HermesV0215StateDDL.ftsSQL + alter + seed
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture failed: \(msg)")
        }
        return home
    }

    private func cleanup(_ home: URL) {
        try? FileManager.default.removeItem(at: home)
    }

    /// One row per case `displaySource` distinguishes.
    private static let sourceSeed = """
    INSERT INTO sessions (id, source, created_source, started_at, message_count) VALUES
        ('localCli', 'local', 'cli', 1700000000, 1),
        ('localTui', 'local', 'tui', 1700000001, 1),
        ('localDesktop', 'local', 'desktop', 1700000002, 1),
        ('localAcp', 'local', 'acp', 1700000003, 1),
        ('localNull', 'local', NULL, 1700000004, 1),
        ('localUnknown', 'local', 'unknown', 1700000005, 1),
        ('telegram', 'telegram', 'telegram', 1700000006, 1),
        ('legacyCli', 'cli', NULL, 1700000007, 1);
    """

    // MARK: - created_source

    @Test func createdSourceResolvesTheDisplaySourceOnANewHost() async throws {
        let home = try makeHome(createdSource: true, seed: Self.sourceSeed)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let sessions = await service.fetchSessions()
        let display = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.displaySource) })
        #expect(display == [
            "localCli": "cli", "localTui": "tui", "localDesktop": "desktop", "localAcp": "acp",
            "localNull": "local", "localUnknown": "local",
            "telegram": "telegram", "legacyCli": "cli",
        ])
        // The raw routing column is untouched.
        #expect(sessions.first { $0.id == "localCli" }?.source == "local")
        #expect(sessions.first { $0.id == "localCli" }?.createdSource == "cli")
        #expect(sessions.first { $0.id == "localDesktop" }?.sourceIcon == "desktopcomputer")
        // The single-session shape carries it too.
        #expect(await service.fetchSession(id: "localTui")?.displaySource == "tui")
        await service.close()
    }

    @Test func aHostWithoutTheColumnKeepsTheOldShape() async throws {
        let seed = """
        INSERT INTO sessions (id, source, started_at, message_count) VALUES
            ('a', 'cli', 1700000000, 1), ('b', 'local', 1700000001, 1);
        """
        let home = try makeHome(createdSource: false, seed: seed)
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasCreatedSourceColumn == false)
        await backend.close()

        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let sessions = await service.fetchSessions()
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.createdSource == nil && $0.displaySource == $0.source })
        await service.close()
    }

    @Test func createdSourceJoinsTheSelectOnlyWhenProbed() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSessions()
        let oldSQL = try #require(await mock.queryLog.last?.sql)
        #expect(!oldSQL.contains("created_source"))

        await mock.setHasCreatedSourceColumn(true)
        await service.refresh()
        _ = await service.fetchSessions()
        let newSQL = try #require(await mock.queryLog.last?.sql)
        #expect(newSQL.contains(", created_source"))
        // Nothing else moved.
        #expect(newSQL.replacingOccurrences(of: ", created_source", with: "") == oldSQL)
    }

    @Test func displaySourceRules() {
        func row(_ source: String, _ created: String?) -> HermesSession {
            HermesSession(
                id: "s", source: source, userId: nil, model: nil, title: nil,
                parentSessionId: nil, startedAt: nil, endedAt: nil, endReason: nil,
                messageCount: 0, toolCallCount: 0, inputTokens: 0, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUSD: nil,
                reasoningTokens: 0, actualCostUSD: nil, costStatus: nil, billingProvider: nil,
                createdSource: created
            )
        }
        #expect(row("local", "cli").displaySource == "cli")
        #expect(row("local", "gui").displaySource == "desktop")
        #expect(row("local", "").displaySource == "local")
        #expect(row("local", "local").displaySource == "local")
        #expect(row("local", "unknown").displaySource == "local")
        #expect(row("local", nil).displaySource == "local")
        // Only a `local` row is rewritten; a gateway row keeps its source.
        #expect(row("telegram", "cli").displaySource == "telegram")
        #expect(row("tool", "tool").displaySource == "tool")
        // Survives the copy helpers.
        #expect(row("local", "acp").withTitle("T").displaySource == "acp")
        #expect(KnownPlatforms.icon(for: "desktop") == "desktopcomputer")
        #expect(!KnownPlatforms.all.contains { $0.name == "desktop" })
    }

    // MARK: - last_active epoch window

    @Test func lastActiveIgnoresTimestampsOutsideTheEpochWindow() async throws {
        let seed = """
        INSERT INTO sessions (id, source, started_at, message_count, last_activity_at) VALUES
            ('garbageMessage', 'cli', 1700000000, 2, NULL),
            ('garbageHeartbeat', 'cli', 1700000000, 1, 5e246),
            ('garbageStart', 'cli', -5, 0, NULL),
            ('clean', 'cli', 1700000000, 1, 1700000050);
        INSERT INTO messages (session_id, role, content, timestamp) VALUES
            ('garbageMessage', 'user', 'a', 1700000020),
            ('garbageMessage', 'user', 'b', 5e246),
            ('garbageHeartbeat', 'user', 'a', 1700000030),
            ('clean', 'user', 'a', 1700000040);
        """
        let home = try makeHome(createdSource: true, seed: seed)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let byID = Dictionary(uniqueKeysWithValues: await service.fetchSessions().map {
            ($0.id, $0.lastActive?.timeIntervalSince1970)
        })
        #expect(byID["garbageMessage"] == 1_700_000_020.0)
        #expect(byID["garbageHeartbeat"] == 1_700_000_030.0)
        // No trusted cell at all → NULL, as in Hermes.
        #expect(byID["garbageStart"] == .some(nil))
        #expect(byID["clean"] == 1_700_000_050.0)
        await service.close()
    }

    @Test func epochWindowMatchesHermesConstants() {
        // hermes_cli/timefmt.py:18-19 @ v0.22.5, rendered with Python repr.
        #expect(HermesDataService.sqlEpochWindow == "BETWEEN 0.0 AND 4200000000.0")
    }

    // MARK: - sessions delete refusals

    @Test func deleteFailureReasonPrefersHermesRefusalLine() {
        let busy = "Warning: deleting a pinned session 'abc'.\n"
            + "Cannot delete session 'abc': it has a queued or running turn. Wait for it to finish (or stop it), then retry.\n"
        #expect(SessionChainDelete.failureReason(from: busy)
                == "Cannot delete session 'abc': it has a queued or running turn. Wait for it to finish (or stop it), then retry.")
        #expect(SessionChainDelete.failureReason(from: "Cannot delete active session: held by pid 42\n")
                == "Cannot delete active session: held by pid 42")
        // Any host's other failure: the last non-empty line.
        #expect(SessionChainDelete.failureReason(from: "Traceback…\n  File x\nValueError: boom\n\n") == "ValueError: boom")
        // Nothing printed → nil, never an empty reason.
        #expect(SessionChainDelete.failureReason(from: "") == nil)
        #expect(SessionChainDelete.failureReason(from: " \n\n") == nil)
    }

    @Test func chainDeleteCarriesTheReason() {
        let outcome = SessionChainDelete.run(["tip", "root"], deleteReporting: { id in
            id == "root" ? (1, "Cannot delete active session: busy\n") : (0, "Deleted session 'tip'.\n")
        })
        #expect(outcome == SessionChainDelete.Outcome(
            deleted: ["tip"], failed: ("root", 1), failureReason: "Cannot delete active session: busy"))
        // The exit-code-only overload is unchanged.
        #expect(SessionChainDelete.run(["x"]) { _ in 1 }
                == SessionChainDelete.Outcome(deleted: [], failed: ("x", 1)))
    }
}

#endif
