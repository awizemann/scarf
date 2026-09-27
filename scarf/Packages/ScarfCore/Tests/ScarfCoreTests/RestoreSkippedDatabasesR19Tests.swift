import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// R19: an archive made before Scarf matched `hermes backup`'s scope can
/// list databases inside trees Hermes leaves out (a prior backup's
/// state.db under `backups/`, a cache's, the Hermes codebase's test
/// fixtures). The home extraction already skips those trees, so Restore
/// must not publish their databases either — it leaves them alone and says
/// so.
@Suite(.serialized)
struct RestoreSkippedDatabasesR19Tests {

    typealias Helpers = ServerBackupRestoreSafetyTests

    /// Mirrors `_should_exclude`'s tree rules (`hermes_cli/backup.py:84-93`,
    /// `:270-279` @ v2026.9.24). Each row was also checked against that
    /// function, run from the v2026.9.24 checkout's venv.
    static let leftOut = [
        "backups/state.db", "state-snapshots/s1/state.db", "checkpoints/x/c.db",
        "hermes-agent/tests/fixture.db", "models/m.db", "runtimes/r/x.db", "node/n.db",
        "browser_profiles/bu/Cookies.db", "browser-profile/Default/History.db",
        "cache/catalog.db", "cache/plugins/index.db",
        "skills/a/node_modules/m.db", "skills/a/.venv/lib/x.db",
        "profiles/work/backups/state.db", "profiles/work/models/m.db", "profiles/work/cache/tmp.db",
    ]

    static let restored = [
        "state.db", "kanban.db", "profiles/work/state.db", "skills/a/data.db",
        "skills/a/models/keep.db", "skills/a/hermes-agent/keep.db", "skills/a/cache/keep.db",
        "cache/images/i.db", "cache/citations/ledger.db", "profiles/work/cache/documents/d.db",
        "profiles/work/hermes-agent/keep.db",
    ]

    @Test func theTreeRuleMatchesHermes() {
        for path in Self.leftOut {
            #expect(RemoteBackupService.isInTreeHermesBackupLeavesOut(path), "\(path)")
        }
        for path in Self.restored {
            #expect(!RemoteBackupService.isInTreeHermesBackupLeavesOut(path), "\(path)")
        }
        let split = RemoteRestoreService.restorableDatabases(Self.restored + Self.leftOut)
        #expect(split.kept == Self.restored)
        #expect(split.skipped == Self.leftOut)
    }

    /// A v1 archive lifts every `*.db` in the home tarball, which is exactly
    /// the older-archive shape: the prior backup's state.db under
    /// `backups/` comes along. It is not published over the target, the
    /// target's own copy there is untouched, and the result names it.
    @Test func aV1ArchivesBackupCopyIsNotRestored() async throws {
        let root = try Helpers.scratch("r19-skip")
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage/.hermes")
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("backups"), withIntermediateDirectories: true)
        sqlite3_close(try Helpers.openWALWriter(stage.appendingPathComponent("state.db").path, rows: 42))
        sqlite3_close(try Helpers.openWALWriter(stage.appendingPathComponent("backups/state.db").path, rows: 7))
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tarball = work.appendingPathComponent(BackupArchiveLayout.hermesTarballPath)
        try Helpers.run("/usr/bin/tar", ["-czf", tarball.path, "-C", stage.deletingLastPathComponent().path, ".hermes"])
        let manifest = BackupManifest(
            schemaVersion: 1,
            createdAt: "2026-01-01T00:00:00Z",
            source: .init(serverID: "s", displayName: "Old", host: "h", user: nil, hermesVersion: nil),
            hermes: .init(homePath: "/root/.hermes", tarballPath: BackupArchiveLayout.hermesTarballPath,
                          tarballSize: 0, tarballSHA256: try Helpers.sha256(tarball)),
            projects: [],
            options: .init(includeAuth: false, includeMcpTokens: false, includeLogs: false, checkpointedWAL: true)
        )
        try JSONEncoder().encode(manifest).write(to: work.appendingPathComponent(BackupArchiveLayout.manifestPath))
        let archive = root.appendingPathComponent("v1.scarfbackup")
        try await RemoteBackupService.zipDirectory(workDir: work, into: archive)

        let target = root.appendingPathComponent("dst/.hermes")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("backups"), withIntermediateDirectories: true)
        let targetCopy = target.appendingPathComponent("backups/state.db")
        try Data("TARGET".utf8).write(to: targetCopy)

        let service = RemoteRestoreService(context: .local(home: target))
        let inspection = try await service.inspect(archiveURL: archive)
        let result = try await service.run(
            inspection: inspection, options: .init(targetProjectsRoot: root.path), progress: { _ in })

        #expect(result.databasesSkipped == ["backups/state.db"])
        #expect(try Helpers.inspect(target.appendingPathComponent("state.db").path).count == 42)
        #expect(try String(contentsOf: targetCopy, encoding: .utf8) == "TARGET")
    }

    /// A current archive lists no such database, so nothing is skipped.
    @Test func aCurrentArchiveSkipsNothing() async throws {
        let root = try Helpers.scratch("r19-noskip")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/.hermes")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("backups"), withIntermediateDirectories: true)
        sqlite3_close(try Helpers.openWALWriter(source.appendingPathComponent("state.db").path, rows: 5))
        sqlite3_close(try Helpers.openWALWriter(source.appendingPathComponent("backups/state.db").path, rows: 3))
        let backup = try await Helpers.backUp(home: source, into: root)
        #expect(backup.manifest.databases?.entries.map(\.path) == ["state.db"])
        let target = root.appendingPathComponent("dst/.hermes")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let service = RemoteRestoreService(context: .local(home: target))
        let result = try await service.run(
            inspection: try await service.inspect(archiveURL: backup.archiveURL),
            options: .init(targetProjectsRoot: root.path), progress: { _ in })
        #expect(result.databasesSkipped.isEmpty)
        #expect(try Helpers.inspect(target.appendingPathComponent("state.db").path).count == 5)
    }
}
