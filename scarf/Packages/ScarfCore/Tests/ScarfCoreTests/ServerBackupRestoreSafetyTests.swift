import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// R05 (S14-F1/F2/F3): Manage Servers → Back Up / Restore against a real
/// WAL-mode `state.db` in scratch Hermes homes on this Mac (a `.local(home:)`
/// context, never the real `~/.hermes`).
///
/// - Backup never writes state.db: the file and its WAL are byte-identical
///   afterwards, and the archive's snapshot still holds the rows that were
///   only in the WAL (the old `wal_checkpoint(TRUNCATE)` + live tar lost them).
/// - Restore refuses while another process holds the target's state.db, and
///   otherwise removes the old database's `-wal`/`-shm` before publishing,
///   so a foreign WAL is never replayed over the restored file.
/// - Restore writes into the server's configured Hermes home, whatever that
///   directory is called.
@Suite(.serialized)
struct ServerBackupRestoreSafetyTests {

    // MARK: - SQLite helpers (test process only)

    /// Open a WAL database, write `rows` rows with auto-checkpoint off, and
    /// return the still-open handle: the rows live only in `state.db-wal`
    /// until the caller closes it.
    static func openWALWriter(_ path: String, rows: Int, table: String = "t") throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw TestError("open \(path)") }
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0",
                    "CREATE TABLE IF NOT EXISTS \(table)(x INTEGER)", "BEGIN"] {
            try exec(db, sql)
        }
        for i in 0..<rows { try exec(db, "INSERT INTO \(table) VALUES(\(i))") }
        try exec(db, "COMMIT")
        return db
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError("\(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// `SELECT count(*)` and `PRAGMA integrity_check`.
    static func inspect(_ path: String, table: String = "t") throws -> (count: Int, integrity: String) {
        var db: OpaquePointer?
        // Read-write, as Hermes opens it: a read-only open of a WAL-mode
        // file without its `-shm` can't build the WAL index. Only ever used
        // on scratch files after every assertion about their sidecars.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw TestError("open \(path)")
        }
        defer { sqlite3_close(db) }
        func scalar(_ sql: String) throws -> String {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TestError("\(sql): \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else {
                throw TestError("\(sql): no row (\(String(cString: sqlite3_errmsg(db))))")
            }
            return String(cString: text)
        }
        let count = Int(try scalar("SELECT count(*) FROM \(table)")) ?? -1
        return (count, try scalar("PRAGMA integrity_check"))
    }

    struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r05-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// Back up `home` into `<dir>/out.scarfbackup` through the real service.
    static func backUp(home: URL, into dir: URL) async throws -> RemoteBackupService.BackupResult {
        let service = RemoteBackupService(context: .local(home: home))
        let summary = try await service.preflight()
        return try await service.run(
            preflight: summary,
            options: BackupManifest.Options(includeAuth: false, includeMcpTokens: false, includeLogs: false, checkpointedWAL: false),
            archiveURL: dir.appendingPathComponent("out.scarfbackup"),
            progress: { _ in }
        )
    }

    /// A child process that holds `path` open (the stand-in for a running
    /// gateway). Returns once the CLI has actually opened the database.
    static func spawnHolder(_ path: String) throws -> (Process, Pipe) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [path]
        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        stdin.fileHandleForWriting.write(Data("SELECT 'opened';\n".utf8))
        // Block until the query answered, i.e. the file is open.
        var seen = Data()
        while !String(decoding: seen, as: UTF8.self).contains("opened") {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            seen.append(chunk)
        }
        return (proc, stdin)
    }

    // MARK: - S14-F2: backup is read-only and complete

    @Test("backup leaves a live WAL database byte-identical and archives the WAL-only rows")
    func backupSnapshotsWithoutWriting() async throws {
        let root = try Self.scratch("backup")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("model: x\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
        let dbPath = home.appendingPathComponent("state.db").path

        // A "gateway" holding the database, with 500 rows only in the WAL.
        let writer = try Self.openWALWriter(dbPath, rows: 500)
        defer { sqlite3_close(writer) }
        let dbBefore = Self.bytes(URL(fileURLWithPath: dbPath))
        let walBefore = Self.bytes(URL(fileURLWithPath: dbPath + "-wal"))
        #expect((walBefore?.count ?? 0) > 0, "fixture must have WAL frames")

        let result = try await Self.backUp(home: home, into: root)

        // C3: not one byte of state.db or its WAL changed.
        #expect(Self.bytes(URL(fileURLWithPath: dbPath)) == dbBefore)
        #expect(Self.bytes(URL(fileURLWithPath: dbPath + "-wal")) == walBefore)
        // No snapshot staging left behind in the home.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.path)
            .filter { $0.hasPrefix(RemoteBackupService.snapshotDirPrefix) }
        #expect(leftovers.isEmpty)

        // The manifest tells the truth.
        let manifest = result.manifest
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.options.checkpointedWAL == false)
        let state = try #require(manifest.stateDB)
        #expect(state.method == "sqlite3")

        // Unpack and look inside.
        let unpacked = root.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try await RemoteRestoreService.unzipArchive(at: result.archiveURL, into: unpacked)
        let stateOut = unpacked.appendingPathComponent("state-x")
        let homeOut = unpacked.appendingPathComponent("home-x")
        for dir in [stateOut, homeOut] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Self.untar(unpacked.appendingPathComponent(state.tarballPath), into: stateOut)
        try Self.untar(unpacked.appendingPathComponent(manifest.hermes.tarballPath), into: homeOut)

        let snapshot = try Self.inspect(stateOut.appendingPathComponent("state.db").path)
        #expect(snapshot.count == 500, "rows that were only in the WAL must be in the snapshot")
        #expect(snapshot.integrity == "ok")
        // The home tarball carries neither the live database nor its sidecars.
        let archived = try FileManager.default.contentsOfDirectory(atPath: homeOut.appendingPathComponent(".hermes").path)
        #expect(archived.contains("config.yaml"))
        #expect(!archived.contains("state.db"))
        #expect(!archived.contains { $0.hasPrefix("state.db-") })
    }

    /// Freeze a live WAL database as a crashed or stopped Hermes leaves it:
    /// copy `state.db` and its `-wal` (with frames) while the writer still
    /// has them open, into `home`, with no process holding the copies.
    /// `withWAL: false` leaves no sidecars at all (a cleanly stopped Hermes
    /// on Linux, which deletes its WAL on close).
    static func makeUnheldHome(_ home: URL, rows: Int, withWAL: Bool) throws {
        let scratch = home.deletingLastPathComponent().appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let live = scratch.appendingPathComponent("state.db").path
        let writer = try openWALWriter(live, rows: rows)
        if !withWAL {
            try exec(writer, "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try FileManager.default.copyItem(atPath: live, toPath: home.appendingPathComponent("state.db").path)
        if withWAL {
            try FileManager.default.copyItem(atPath: live + "-wal", toPath: home.appendingPathComponent("state.db-wal").path)
        }
        sqlite3_close(writer)
        try? FileManager.default.removeItem(at: scratch)
    }

    @Test("a stopped Hermes's database (no sidecars, or WAL frames with no holder) snapshots without being written")
    func backupOfUnheldDatabase() async throws {
        for withWAL in [false, true] {
            let root = try Self.scratch("unheld")
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent(".hermes")
            try Self.makeUnheldHome(home, rows: 250, withWAL: withWAL)
            let db = home.appendingPathComponent("state.db")
            let dbBefore = Self.bytes(db)
            let walBefore = Self.bytes(URL(fileURLWithPath: db.path + "-wal"))

            let result = try await Self.backUp(home: home, into: root)

            // The last connection to close never checkpointed the WAL into
            // state.db (charter C3), and the WAL itself is untouched.
            #expect(Self.bytes(db) == dbBefore, "withWAL: \(withWAL)")
            if withWAL {
                #expect(Self.bytes(URL(fileURLWithPath: db.path + "-wal")) == walBefore)
            }
            let state = try #require(result.manifest.stateDB)
            let unpacked = root.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await RemoteRestoreService.unzipArchive(at: result.archiveURL, into: unpacked)
            try Self.untar(unpacked.appendingPathComponent(state.tarballPath), into: unpacked)
            let snapshot = try Self.inspect(unpacked.appendingPathComponent("state.db").path)
            #expect(snapshot.count == 250, "withWAL: \(withWAL), method: \(state.method)")
            #expect(snapshot.integrity == "ok")
        }
    }

    @Test("a home with no state.db backs up without a snapshot entry")
    func backupWithoutStateDB() async throws {
        let root = try Self.scratch("nodb")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: home.appendingPathComponent("SOUL.md"))
        let result = try await Self.backUp(home: home, into: root)
        #expect(result.manifest.stateDB == nil)
    }

    @Test("the snapshot script never checkpoints and fails loudly on a bad path")
    func snapshotScriptShape() async throws {
        let script = RemoteBackupService.snapshotScript(stateDB: "/h/state.db", snapshotDir: "/h/.snap")
        #expect(script.contains("sqlite3 -readonly"))
        #expect(script.contains("mode=ro"))
        // The only writable connection is gated on proving no_ckpt_on_close
        // and runs query_only; nothing ever asks for a checkpoint.
        #expect(!script.contains("wal_checkpoint"))
        #expect(script.contains("PRAGMA query_only=1"))
        #expect(script.contains("sqlite3 :memory: '.dbconfig no_ckpt_on_close on'"))

        let root = try Self.scratch("badsnap")
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ db: URL) async throws -> ProcessResult {
            try await LocalTransport().asyncRunProcess(
                executable: "/bin/bash",
                args: ["-lc", RemoteBackupService.snapshotScript(
                    stateDB: db.path, snapshotDir: root.appendingPathComponent("snap").path)],
                stdin: nil, timeout: 60)
        }
        // No database: said so explicitly, never a silent success.
        let absent = try await run(root.appendingPathComponent("missing/state.db"))
        #expect(absent.exitCode == 0)
        #expect(absent.stdoutString.contains("SCARF_SNAPSHOT_ABSENT"))
        // A file no method can read: a loud failure.
        let garbage = root.appendingPathComponent("state.db")
        try Data(repeating: 0x41, count: 8192).write(to: garbage)
        let broken = try await run(garbage)
        #expect(broken.exitCode != 0)
        #expect(!broken.stdoutString.contains("SCARF_SNAPSHOT_OK"))
        #expect(Self.bytes(garbage) == Data(repeating: 0x41, count: 8192))
    }

    // MARK: - S14-F1 / S14-F3: restore

    /// Build a target home that already has its own database AND a real
    /// leftover WAL from it (as a killed gateway leaves behind).
    static func makeTargetWithStaleWAL(_ home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dbPath = home.appendingPathComponent("state.db").path
        let writer = try openWALWriter(dbPath, rows: 7, table: "old")
        let wal = bytes(URL(fileURLWithPath: dbPath + "-wal"))
        sqlite3_close(writer)  // last connection: checkpoints and deletes the WAL
        try #require(wal).write(to: URL(fileURLWithPath: dbPath + "-wal"))
        try Data(count: 32768).write(to: URL(fileURLWithPath: dbPath + "-shm"))
    }

    @Test("restore removes the old WAL/SHM and publishes the snapshot into a custom-named home")
    func restorePublishesSafely() async throws {
        let root = try Self.scratch("restore")
        defer { try? FileManager.default.removeItem(at: root) }
        // Source.
        let source = root.appendingPathComponent("src/.hermes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("model: restored\n".utf8).write(to: source.appendingPathComponent("config.yaml"))
        let writer = try Self.openWALWriter(source.appendingPathComponent("state.db").path, rows: 321)
        let backup = try await Self.backUp(home: source, into: root)
        sqlite3_close(writer)

        // Target: a configured home NOT called `.hermes`, with a stale WAL.
        let target = root.appendingPathComponent("srv/hermes-data")
        try Self.makeTargetWithStaleWAL(target)

        let service = RemoteRestoreService(context: .local(home: target))
        let inspection = try await service.inspect(archiveURL: backup.archiveURL)
        #expect(inspection.targetHermesHome == target.path)
        #expect(inspection.stateDBHolders == .clear)
        let result = try await service.run(
            inspection: inspection,
            options: .init(targetProjectsRoot: root.appendingPathComponent("projects").path),
            progress: { _ in })

        #expect(result.hermesHome == target.path)
        let db = target.appendingPathComponent("state.db").path
        // The old sidecars were removed BEFORE anything opened the new file.
        #expect(!FileManager.default.fileExists(atPath: db + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: db + "-shm"))
        // Owner-only, as Hermes keeps it.
        let mode = try FileManager.default.attributesOfItem(atPath: db)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let restored = try Self.inspect(db)
        #expect(restored.count == 321)
        #expect(restored.integrity == "ok")
        #expect(try String(contentsOf: target.appendingPathComponent("config.yaml"), encoding: .utf8) == "model: restored\n")
        // Nothing landed in a `.hermes` beside it, and no staging is left.
        #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent(".hermes").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path)
            .allSatisfy { !$0.hasPrefix(RemoteRestoreService.stagingDirPrefix) })
    }

    @Test("an archive without a database leaves the target's state.db and its WAL alone")
    func restoreWithoutDatabaseKeepsTargetWAL() async throws {
        let root = try Self.scratch("nodb-restore")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/.hermes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("model: new\n".utf8).write(to: source.appendingPathComponent("config.yaml"))
        let backup = try await Self.backUp(home: source, into: root)
        #expect(backup.manifest.stateDB == nil)

        // Target: a stopped Hermes whose newest sessions are still in its WAL.
        let target = root.appendingPathComponent("dst/.hermes")
        try Self.makeUnheldHome(target, rows: 77, withWAL: true)
        let db = target.appendingPathComponent("state.db").path
        let dbBefore = Self.bytes(URL(fileURLWithPath: db))
        let walBefore = Self.bytes(URL(fileURLWithPath: db + "-wal"))

        let service = RemoteRestoreService(context: .local(home: target))
        let inspection = try await service.inspect(archiveURL: backup.archiveURL)
        _ = try await service.run(inspection: inspection, options: .init(targetProjectsRoot: root.path), progress: { _ in })

        #expect(Self.bytes(URL(fileURLWithPath: db)) == dbBefore)
        #expect(Self.bytes(URL(fileURLWithPath: db + "-wal")) == walBefore, "the WAL holds committed sessions")
        #expect(try Self.inspect(db).count == 77)
        #expect(try String(contentsOf: target.appendingPathComponent("config.yaml"), encoding: .utf8) == "model: new\n")
    }

    @Test("restore refuses, and changes nothing, while another process holds state.db")
    func restoreRefusesLiveDatabase() async throws {
        let root = try Self.scratch("live")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/.hermes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("model: new\n".utf8).write(to: source.appendingPathComponent("config.yaml"))
        let writer = try Self.openWALWriter(source.appendingPathComponent("state.db").path, rows: 3)
        let backup = try await Self.backUp(home: source, into: root)
        sqlite3_close(writer)

        let target = root.appendingPathComponent("dst/.hermes")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("model: old\n".utf8).write(to: target.appendingPathComponent("config.yaml"))
        let targetDB = target.appendingPathComponent("state.db").path
        let seed = try Self.openWALWriter(targetDB, rows: 9, table: "old")
        sqlite3_close(seed)
        let dbBefore = Self.bytes(URL(fileURLWithPath: targetDB))

        let (holder, holderStdin) = try Self.spawnHolder(targetDB)
        defer {
            try? holderStdin.fileHandleForWriting.close()
            holder.terminate()
            holder.waitUntilExit()
        }

        let service = RemoteRestoreService(context: .local(home: target))
        let inspection = try await service.inspect(archiveURL: backup.archiveURL)
        #expect(inspection.stateDBHolders == .held([holder.processIdentifier]))

        var thrown: Error?
        do {
            _ = try await service.run(inspection: inspection, options: .init(), progress: { _ in })
        } catch {
            thrown = error
        }
        let error = try #require(thrown as? RemoteRestoreService.RestoreError)
        guard case .hermesRunning(let pids, let homeRestored) = error else {
            Issue.record("expected hermesRunning, got \(error)")
            return
        }
        #expect(pids == [holder.processIdentifier])
        #expect(homeRestored == false)
        #expect(error.localizedDescription.contains("Nothing was changed"))
        // Nothing was changed.
        #expect(Self.bytes(URL(fileURLWithPath: targetDB)) == dbBefore)
        #expect(try String(contentsOf: target.appendingPathComponent("config.yaml"), encoding: .utf8) == "model: old\n")
    }

    @Test("a v1 archive (state.db inside the home tarball) still restores, with the stale WAL removed first")
    func restoresLegacyV1Archive() async throws {
        let root = try Self.scratch("v1")
        defer { try? FileManager.default.removeItem(at: root) }
        // Hand-build a v1 archive: `.hermes/` with a plain state.db.
        let stage = root.appendingPathComponent("stage/.hermes")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let seed = try Self.openWALWriter(stage.appendingPathComponent("state.db").path, rows: 42)
        sqlite3_close(seed)  // checkpointed into the file, WAL gone
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tarball = work.appendingPathComponent(BackupArchiveLayout.hermesTarballPath)
        try Self.run("/usr/bin/tar", ["-czf", tarball.path, "-C", stage.deletingLastPathComponent().path, ".hermes"])
        let manifest = BackupManifest(
            schemaVersion: 1,
            createdAt: "2026-01-01T00:00:00Z",
            source: .init(serverID: "s", displayName: "Old", host: "h", user: nil, hermesVersion: nil),
            hermes: .init(homePath: "/root/.hermes", tarballPath: BackupArchiveLayout.hermesTarballPath,
                          tarballSize: 0, tarballSHA256: try Self.sha256(tarball)),
            projects: [],
            options: .init(includeAuth: false, includeMcpTokens: false, includeLogs: false, checkpointedWAL: true)
        )
        try JSONEncoder().encode(manifest).write(to: work.appendingPathComponent(BackupArchiveLayout.manifestPath))
        let archive = root.appendingPathComponent("v1.scarfbackup")
        try await RemoteBackupService.zipDirectory(workDir: work, into: archive)

        let target = root.appendingPathComponent("dst/.hermes")
        try Self.makeTargetWithStaleWAL(target)
        let service = RemoteRestoreService(context: .local(home: target))
        let inspection = try await service.inspect(archiveURL: archive)
        _ = try await service.run(inspection: inspection, options: .init(targetProjectsRoot: root.path), progress: { _ in })

        let db = target.appendingPathComponent("state.db").path
        let left = try FileManager.default.contentsOfDirectory(atPath: target.path)
        #expect(!FileManager.default.fileExists(atPath: db + "-wal"), "left: \(left)")
        let restored = try Self.inspect(db)
        #expect(restored.count == 42)
        #expect(restored.integrity == "ok")
    }

    @Test("a v1 home tarball without a database lifts to nil, not an error")
    func liftLegacyWithoutDatabase() async throws {
        let root = try Self.scratch("lift")
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage/.hermes")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stage.appendingPathComponent("SOUL.md"))
        let tarball = root.appendingPathComponent("h.tar.gz")
        try Self.run("/usr/bin/tar", ["-czf", tarball.path, "-C", stage.deletingLastPathComponent().path, ".hermes"])
        let lifted = try await RemoteRestoreService.liftLegacyStateDB(
            from: tarball, member: ".hermes/state.db", workDir: root)
        #expect(lifted == nil)
    }

    @Test("an archive from a newer schema is refused before anything is written")
    func refusesUnknownSchema() {
        #expect(!BackupManifest.supportedSchemaVersions.contains(3))
        #expect(BackupManifest.supportedSchemaVersions.contains(1))
        #expect(BackupManifest.supportedSchemaVersions.contains(BackupManifest.currentSchemaVersion))
    }

    // MARK: - Pure helpers

    @Test("target Hermes home follows the configured home, expanding ~ against $HOME")
    func targetHomeResolution() {
        #expect(RemoteRestoreService.resolveTargetHermesHome(configured: "/var/lib/hermes/.hermes", userHome: "/home/ubuntu")
                == "/var/lib/hermes/.hermes")
        #expect(RemoteRestoreService.resolveTargetHermesHome(configured: "~/.hermes", userHome: "/home/ubuntu")
                == "/home/ubuntu/.hermes")
        #expect(RemoteRestoreService.resolveTargetHermesHome(configured: "~/.hermes", userHome: nil) == nil)
    }

    @Test("holder output parsing: clear, held, unknown, and login-shell noise")
    func holderParsing() {
        #expect(RemoteRestoreService.parseHolderOutput("motd\nSCARF_HOLDERS:\n") == .clear)
        #expect(RemoteRestoreService.parseHolderOutput("SCARF_HOLDERS: 12 345\n") == .held([12, 345]))
        if case .unknown = RemoteRestoreService.parseHolderOutput("SCARF_HOLDERS:UNKNOWN") {} else {
            Issue.record("UNKNOWN must parse as unknown")
        }
        #expect(RemoteRestoreService.parseHolderOutput("nothing") == nil)
    }

    /// The Linux branch reads `ls -l /proc/[0-9]*/fd`. Feed the awk program a
    /// captured-shape listing so it is exercised on a Mac too.
    @Test("the /proc fd scan finds holders, including an unlinked WAL, and nothing else")
    func procScanAwk() throws {
        let listing = """
        /proc/1/fd:
        total 0
        lrwx------ 1 root root 64 Sep 26 10:00 0 -> /dev/null

        /proc/812/fd:
        total 0
        lrwx------ 1 hermes hermes 64 Sep 26 10:00 5 -> /var/lib/hermes/.hermes/state.db
        lrwx------ 1 hermes hermes 64 Sep 26 10:00 6 -> /var/lib/hermes/.hermes/state.db-wal

        /proc/913/fd:
        total 0
        lrwx------ 1 hermes hermes 64 Sep 26 10:00 7 -> /var/lib/hermes/.hermes/state.db-shm (deleted)

        /proc/999/fd:
        total 0
        lrwx------ 1 hermes hermes 64 Sep 26 10:00 3 -> /var/lib/hermes/.hermes/state.db.bak
        lrwx------ 1 hermes hermes 64 Sep 26 10:00 4 -> /other/state.db
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        proc.arguments = [RemoteRestoreService.procFDAwkProgram]
        proc.environment = ["SCARF_DB": "/var/lib/hermes/.hermes/state.db"]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        try proc.run()
        input.fileHandleForWriting.write(Data(listing.utf8))
        try input.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        let pids = Set(out.split(whereSeparator: \.isNewline).map(String.init))
        #expect(pids == ["812", "913"])
    }

    @Test("backup excludes follow the home's own directory name")
    func excludesUseLeaf() {
        let ex = RemoteBackupService.hermesExcludes(
            leaf: "hermes-data",
            options: .init(includeAuth: false, includeMcpTokens: true, includeLogs: true, checkpointedWAL: false))
        #expect(ex.contains("hermes-data/state.db"))
        #expect(ex.contains("hermes-data/state.db-wal"))
        #expect(ex.contains("hermes-data/auth.json"))
        #expect(!ex.contains { $0.hasPrefix(".hermes/") })
    }

    // MARK: - Process helpers

    static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TestError("\(exe) exited \(p.terminationStatus)") }
    }

    static func untar(_ tarball: URL, into dir: URL) throws {
        try run("/usr/bin/tar", ["-xzf", tarball.path, "-C", dir.path])
    }

    static func sha256(_ url: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return String(text.prefix(64))
    }
}
