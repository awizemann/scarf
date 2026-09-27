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
    static func backUp(
        home: URL, into dir: URL,
        options: BackupManifest.Options = .init(includeAuth: false, includeMcpTokens: false, includeLogs: false, checkpointedWAL: false),
        archiveName: String = "out.scarfbackup"
    ) async throws -> RemoteBackupService.BackupResult {
        let service = RemoteBackupService(context: .local(home: home))
        let summary = try await service.preflight()
        return try await service.run(
            preflight: summary,
            options: options,
            archiveURL: dir.appendingPathComponent(archiveName),
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

    /// Stop a holder without `waitUntilExit`, which can park forever in a
    /// Swift Testing task when the child has already been reaped.
    static func stopHolder(_ proc: Process, _ stdin: Pipe) {
        try? stdin.fileHandleForWriting.close()
        if proc.isRunning { proc.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning, Date() < deadline { usleep(20_000) }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
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
            .filter { $0.hasPrefix(HermesDatabaseScripts.snapshotDirPrefix) }
        #expect(leftovers.isEmpty)

        // The manifest tells the truth.
        let manifest = result.manifest
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.options.checkpointedWAL == false)
        let state = try #require(manifest.databases)
        #expect(state.entries.map(\.path) == ["state.db"])
        #expect(state.entries.first?.method == "sqlite3")
        #expect(state.skipped.isEmpty)

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
        // (R19: members are `./…`, so the home's contents land at the top.)
        let archived = try FileManager.default.contentsOfDirectory(atPath: homeOut.path)
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
            let state = try #require(result.manifest.databases)
            let unpacked = root.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await RemoteRestoreService.unzipArchive(at: result.archiveURL, into: unpacked)
            try Self.untar(unpacked.appendingPathComponent(state.tarballPath), into: unpacked)
            let snapshot = try Self.inspect(unpacked.appendingPathComponent("state.db").path)
            #expect(snapshot.count == 250, "withWAL: \(withWAL), method: \(state.entries.map(\.method))")
            #expect(snapshot.integrity == "ok")
        }
    }

    /// R16a (documents a known, accepted effect): snapshotting a WAL-mode
    /// database that a cleanly stopped Hermes left with no sidecars may
    /// create an EMPTY `-wal` and a `-shm` beside it. The database's own
    /// bytes don't change and the `-wal` holds no frames, so nothing was
    /// written to the data (charter C3). Hermes's own `hermes backup` does
    /// the same: `_safe_copy_db` opens the source `mode=ro` and
    /// `sqlite3.backup()`s it (`hermes_cli/backup.py:332-369` @ v2026.9.24),
    /// which on this Mac leaves `state.db-wal` (0 bytes) and `state.db-shm`.
    @Test("a stopped database may gain an empty -wal and a -shm from the snapshot, and nothing else")
    func snapshotOfStoppedDatabaseMayCreateEmptySidecars() async throws {
        let root = try Self.scratch("sidecars")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        try Self.makeUnheldHome(home, rows: 40, withWAL: false)
        let db = home.appendingPathComponent("state.db")
        let wal = URL(fileURLWithPath: db.path + "-wal")
        #expect(!FileManager.default.fileExists(atPath: wal.path), "fixture: no sidecars before")
        let before = Self.bytes(db)

        _ = try await Self.backUp(home: home, into: root)

        #expect(Self.bytes(db) == before, "the database itself is never written")
        if FileManager.default.fileExists(atPath: wal.path) {
            #expect(Self.bytes(wal)?.isEmpty == true, "a -wal the snapshot created holds no frames")
        }
        // Those two sidecars are all it may leave: no snapshot directory, no copy.
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: home.path))
        #expect(left.isSubset(of: ["state.db", "state.db-wal", "state.db-shm"]), "\(left.sorted())")
    }

    @Test("a home with no database backs up without a snapshot entry")
    func backupWithoutStateDB() async throws {
        let root = try Self.scratch("nodb")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: home.appendingPathComponent("SOUL.md"))
        let result = try await Self.backUp(home: home, into: root)
        #expect(result.manifest.databases == nil)
    }

    @Test("the snapshot pass never checkpoints, reports unreadable databases, and never writes them")
    func snapshotScriptShape() async throws {
        let script = HermesDatabaseScripts.snapshotAll(home: "/h", snapshotDir: "/h/.snap", prunedDirs: ["logs"])
        #expect(script.contains("sqlite3 -readonly"))
        #expect(script.contains("mode=ro"))
        // The only writable connection is gated on proving no_ckpt_on_close
        // and runs query_only; nothing ever asks for a checkpoint.
        #expect(!script.contains("wal_checkpoint"))
        #expect(script.contains("PRAGMA query_only=1"))
        #expect(script.contains("sqlite3 :memory: '.dbconfig no_ckpt_on_close on'"))

        let root = try Self.scratch("badsnap")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("plugins/x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let garbage = home.appendingPathComponent("plugins/x/cache.db")
        try Data(repeating: 0x41, count: 8192).write(to: garbage)
        let seed = try Self.openWALWriter(home.appendingPathComponent("logs/pruned.db").path, rows: 1)
        sqlite3_close(seed)
        let result = try await LocalTransport().asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", HermesDatabaseScripts.snapshotAll(
                home: home.path, snapshotDir: root.appendingPathComponent("snap").path, prunedDirs: ["logs"])],
            stdin: nil, timeout: 60)
        let report = HermesDatabaseScripts.parseSnapshotReport(result.stdoutString)
        #expect(report.finished)
        #expect(report.failed == ["plugins/x/cache.db"])
        #expect(report.ok.isEmpty, "a pruned directory's databases are not snapshotted")
        #expect(Self.bytes(garbage) == Data(repeating: 0x41, count: 8192))
        #expect(result.stderrString.contains("cache.db"))
    }

    /// The finding's follow-up: every `*.db` Hermes itself snapshots, not
    /// just the root state.db.
    @Test("every database in the home is snapshotted, none is archived live, and restore publishes them all")
    func everyDatabaseRoundTrips() async throws {
        let root = try Self.scratch("alldb")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/.hermes")
        for dir in ["profiles/work", "cron"] {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("model: x\n".utf8).write(to: source.appendingPathComponent("config.yaml"))
        // Live writers with rows only in their WALs, as a running gateway leaves them.
        let writers = try [
            ("state.db", 11), ("profiles/work/state.db", 22), ("kanban.db", 33), ("cron/executions.db", 44),
        ].map { (path, rows) in (path, rows, try Self.openWALWriter(source.appendingPathComponent(path).path, rows: rows)) }
        let before = writers.map { Self.bytes(source.appendingPathComponent($0.0)) }
        let backup = try await Self.backUp(home: source, into: root)
        // C3 for every database, not just state.db.
        #expect(writers.map { Self.bytes(source.appendingPathComponent($0.0)) } == before)
        for writer in writers { sqlite3_close(writer.2) }

        let dbs = try #require(backup.manifest.databases)
        #expect(Set(dbs.entries.map(\.path)) == Set(writers.map(\.0)))
        // The home tarball holds no database and no sidecar at any depth.
        let listing = try Self.capture("/usr/bin/tar", ["-tzf", Self.unzipped(backup.archiveURL, in: root)
            .appendingPathComponent(backup.manifest.hermes.tarballPath).path])
        #expect(!listing.split(separator: "\n").contains { $0.hasSuffix(".db") || $0.contains(".db-") })

        // Target: a stopped Hermes with its own profile DB and a stale WAL there.
        let target = root.appendingPathComponent("dst/.hermes")
        try Self.makeUnheldHome(target, rows: 5, withWAL: true)
        try Self.makeUnheldHome(target.appendingPathComponent("profiles/work"), rows: 6, withWAL: true)
        let service = RemoteRestoreService(context: .local(home: target))
        let inspection = try await service.inspect(archiveURL: backup.archiveURL)
        _ = try await service.run(inspection: inspection, options: .init(targetProjectsRoot: root.path), progress: { _ in })

        for (path, rows, _) in writers {
            let db = target.appendingPathComponent(path).path
            #expect(!FileManager.default.fileExists(atPath: db + "-wal"), "\(path) kept a foreign WAL")
            let restored = try Self.inspect(db)
            #expect(restored.count == rows, "\(path)")
            #expect(restored.integrity == "ok")
        }
    }

    @Test("restore refuses while a process holds a profile database, not only state.db")
    func restoreRefusesHeldProfileDatabase() async throws {
        let root = try Self.scratch("heldprofile")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/.hermes")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("profiles/work"), withIntermediateDirectories: true)
        let w = try Self.openWALWriter(source.appendingPathComponent("profiles/work/state.db").path, rows: 3)
        let backup = try await Self.backUp(home: source, into: root)
        sqlite3_close(w)

        let target = root.appendingPathComponent("dst/.hermes")
        try Self.makeUnheldHome(target.appendingPathComponent("profiles/work"), rows: 9, withWAL: false)
        let profileDB = target.appendingPathComponent("profiles/work/state.db").path
        let dbBefore = Self.bytes(URL(fileURLWithPath: profileDB))
        let (holder, holderStdin) = try Self.spawnHolder(profileDB)
        try #require(holder.isRunning, "the holder must still have the database open")
        defer {
            Self.stopHolder(holder, holderStdin)
        }
        let service = RemoteRestoreService(context: .local(home: target))
        let inspection = try await service.inspect(archiveURL: backup.archiveURL)
        #expect(inspection.stateDBHolders == .held([holder.processIdentifier]))
        await #expect(throws: RemoteRestoreService.RestoreError.self) {
            _ = try await service.run(inspection: inspection, options: .init(targetProjectsRoot: root.path), progress: { _ in })
        }
        #expect(Self.bytes(URL(fileURLWithPath: profileDB)) == dbBefore)
    }

    /// Review follow-ups: a symlinked state.db, a directory named `*.db`, a
    /// database with glob characters in its name, and a Hermes retired-WAL
    /// capture, all through a real backup and restore.
    @Test("symlinked state.db, *.db directories, odd names and retired-WAL captures survive the round trip correctly")
    func awkwardHomeRoundTrip() async throws {
        let root = try Self.scratch("awkward")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/.hermes")
        let data = root.appendingPathComponent("data")
        for dir in [source.appendingPathComponent("plug.db"), source.appendingPathComponent("state.db.retired-wal-1-2"), data] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // state.db lives elsewhere, symlinked in.
        let realState = try Self.openWALWriter(data.appendingPathComponent("real.db").path, rows: 31)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("state.db").path, withDestinationPath: data.appendingPathComponent("real.db").path)
        let odd = try Self.openWALWriter(source.appendingPathComponent("odd [1].db").path, rows: 2)
        try Data("notes".utf8).write(to: source.appendingPathComponent("plug.db/notes.txt"))
        try Data("image".utf8).write(to: source.appendingPathComponent("state.db.retired-wal-1-2/image.db"))
        try Data("frames".utf8).write(to: source.appendingPathComponent("state.db.retired-wal-1-2/image.db-wal"))

        let backup = try await Self.backUp(home: source, into: root)
        sqlite3_close(realState); sqlite3_close(odd)
        let dbs = try #require(backup.manifest.databases)
        #expect(Set(dbs.entries.map(\.path)) == ["state.db", "odd [1].db"], "the retired-WAL image is not snapshotted")
        let listing = try Self.capture("/usr/bin/tar", ["-tzf", Self.unzipped(backup.archiveURL, in: root)
            .appendingPathComponent(backup.manifest.hermes.tarballPath).path])
        #expect(listing.contains("./plug.db/notes.txt"), "a directory named *.db is kept")
        #expect(!listing.contains("retired-wal"), "retired-WAL captures are left out whole, as hermes backup does")
        #expect(!listing.split(separator: "\n").contains { $0.hasSuffix("state.db") || $0.hasSuffix("odd [1].db") })

        let target = root.appendingPathComponent("dst/.hermes")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let service = RemoteRestoreService(context: .local(home: target))
        _ = try await service.run(
            inspection: try await service.inspect(archiveURL: backup.archiveURL),
            options: .init(targetProjectsRoot: root.path), progress: { _ in })
        #expect(try Self.inspect(target.appendingPathComponent("state.db").path).count == 31)
        #expect(try Self.inspect(target.appendingPathComponent("odd [1].db").path).count == 2)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("plug.db/notes.txt").path))
    }

    @Test("a backup whose state.db can't be snapshotted fails instead of leaving it out")
    func unreadableRootStateFails() async throws {
        let root = try Self.scratch("badroot")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8192).write(to: home.appendingPathComponent("state.db"))
        await #expect(throws: RemoteBackupService.BackupError.self) {
            _ = try await Self.backUp(home: home, into: root)
        }
    }

    @Test("a database whose name has a line break refuses the backup instead of riding along live")
    func unnameableDatabaseRefuses() async throws {
        let root = try Self.scratch("unnameable")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let seed = try Self.openWALWriter(home.appendingPathComponent("odd\nname.db").path, rows: 1)
        sqlite3_close(seed)
        var thrown: Error?
        do { _ = try await Self.backUp(home: home, into: root) } catch { thrown = error }
        #expect(thrown?.localizedDescription.contains("tab or line break") == true, "\(String(describing: thrown))")
    }

    @Test("manifest database paths that could escape the home are refused")
    func unsafeDatabasePaths() {
        for bad in ["../x.db", "/etc/x.db", "a/../../x.db", "a//x.db", "x.txt", "./x.db", "a\nb.db",
                    "state.db.retired-wal-1-2/image.db"] {
            #expect(!RemoteRestoreService.isSafeDatabasePath(bad), "\(bad)")
        }
        for good in ["state.db", "profiles/work/state.db", "odd [1].db"] {
            #expect(RemoteRestoreService.isSafeDatabasePath(good), "\(good)")
        }
    }

    @Test("leftover Scarf directories from a killed run are swept; fresh ones and non-Scarf ones are kept")
    func leftoversAreSwept() async throws {
        let root = try Self.scratch("leftover")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        let stale = home.appendingPathComponent(HermesDatabaseScripts.snapshotDirPrefix + "old")
        let staleStaging = home.appendingPathComponent(HermesDatabaseScripts.stagingDirPrefix + "old")
        let fresh = home.appendingPathComponent(HermesDatabaseScripts.snapshotDirPrefix + "busy")
        let foreign = home.appendingPathComponent(".scarf-something-else")
        for dir in [stale, staleStaging, fresh, foreign] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("state.db"))
        }
        let old = Date(timeIntervalSinceNow: -2 * 86_400)
        for dir in [stale, staleStaging, foreign] {
            for url in [dir.appendingPathComponent("state.db"), dir] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
        }
        let result = try await LocalTransport().asyncRunProcess(
            executable: "/bin/bash", args: ["-lc", HermesDatabaseScripts.leftoverCleanup(home: home.path)],
            stdin: nil, timeout: 60)
        #expect(result.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: staleStaging.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path), "a run in progress elsewhere must survive")
        #expect(FileManager.default.fileExists(atPath: foreign.path), "only Scarf's own prefixes are swept")
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
        #expect(backup.manifest.databases == nil)

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
            Self.stopHolder(holder, holderStdin)
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
        // v1 tarred every other database live WITH its WAL (only the root
        // state.db's sidecars were excluded): rows only in that WAL must
        // survive the lift.
        try Self.makeUnheldHome(stage.appendingPathComponent("profiles/p"), rows: 17, withWAL: true)
        // bsdtar reads extract operands as patterns: a bracketed name must
        // still be found.
        let bracket = try Self.openWALWriter(stage.appendingPathComponent("k[1].db").path, rows: 4)
        sqlite3_close(bracket)
        // bsdtar escapes `\` and non-ASCII in listings; names like these
        // broke a listing-driven lift.
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("profiles/café"), withIntermediateDirectories: true)
        let accent = try Self.openWALWriter(stage.appendingPathComponent("profiles/café/b\\c.db").path, rows: 6)
        sqlite3_close(accent)
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
        let profile = target.appendingPathComponent("profiles/p/state.db").path
        #expect(!FileManager.default.fileExists(atPath: profile + "-wal"))
        #expect(try Self.inspect(profile).count == 17, "the archived WAL's rows were folded in")
        #expect(try Self.inspect(target.appendingPathComponent("k[1].db").path).count == 4)
        #expect(try Self.inspect(target.appendingPathComponent("profiles/café/b\\c.db").path).count == 6)
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
        let lifted = try await RemoteRestoreService.liftLegacyDatabases(
            from: tarball, leaf: ".hermes", workDir: root)
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

    /// The Linux branch, run on a Mac against a fake `/proc` of symlinks.
    /// Names that would break an `ls -l` parse (a ` -> ` in the path, a
    /// space) must still be found, through `find -lname` and through the
    /// `readlink` fallback alike.
    @Test("the /proc scan finds holders by link target, including unlinked sidecars, whatever the names look like",
          arguments: [false, true])
    func procScan(forceReadlink: Bool) async throws {
        let root = try Self.scratch("proc")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("odd -> home [1]/.hermes")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("profiles/w"), withIntermediateDirectories: true)
        // What `/proc` links name: the real path (`/private/var/…` on a Mac;
        // Foundation's resolvingSymlinksInPath strips `/private`).
        let real = try #require(realpath(home.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let proc = root.appendingPathComponent("proc")
        func link(_ pid: Int, _ fd: Int, _ target: String) throws {
            let dir = proc.appendingPathComponent("\(pid)/fd")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("\(fd)").path, withDestinationPath: target)
        }
        try link(1, 0, "/dev/null")
        try link(812, 5, real + "/state.db")
        try link(812, 6, real + "/state.db-wal")
        try link(913, 7, real + "/profiles/w/state.db-shm (deleted)")
        try link(999, 3, real + "/state.db.bak")
        try link(999, 4, "/other/state.db")
        try link(4242, 1, real + "/state.db")   // "our own" pid, excluded

        let script = HermesDatabaseScripts.holderScan(
            databases: [home.path + "/state.db", home.path + "/profiles/w/state.db"],
            ownPID: 4242, procRoot: proc.path, forceReadlink: forceReadlink) + "\necho \"SCARF_HOLDERS:$holders\""
        let result = try await LocalTransport().asyncRunProcess(
            executable: "/bin/bash", args: ["-lc", script], stdin: nil, timeout: 60)
        #expect(RemoteRestoreService.parseHolderOutput(result.stdoutString) == .held([812, 913]),
                "\(result.stdoutString) \(result.stderrString)")
    }

    /// R16a X3 (security): every named profile is a Hermes home with its
    /// own credentials. "Include auth.json" off used to exclude only the
    /// ROOT `auth.json` (and `mcp-tokens/`, `gateway_state.json` only at the
    /// root), so each profile's credentials shipped in the archive. This
    /// runs the real backup against a scratch home with profiles and reads
    /// the actual tar listing.
    @Test("with auth off, no profile's auth.json, MCP tokens or gateway state reaches the archive")
    func profileCredentialsStayOut() async throws {
        let root = try Self.scratch("profauth")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".hermes")
        let files = [
            "config.yaml", "auth.json", "gateway_state.json", "mcp-tokens/linear.json",
            "profiles/work/config.yaml", "profiles/work/auth.json", "profiles/work/gateway_state.json",
            "profiles/work/mcp-tokens/linear.json", "profiles/work/mcp-tokens/linear.client.json",
            "profiles/work/skills/notes/SKILL.md",
            "profiles/my team [2]/auth.json", "profiles/my team [2]/SOUL.md",
            "profiles/my team [2]/mcp-tokens/github.json",
            "auth.json.corrupt", "profiles/work/auth.json.corrupt",
            "logs/agent.log", "profiles/work/logs/agent.log", "profiles/work/skills/notes/logs/keep.md",
        ]
        for rel in files {
            let url = home.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
        func listing(_ options: BackupManifest.Options, _ name: String) async throws -> Set<String> {
            let result = try await Self.backUp(home: home, into: root, options: options, archiveName: name)
            let tarball = try Self.unzipped(result.archiveURL, in: root)
                .appendingPathComponent(result.manifest.hermes.tarballPath)
            return Set(try Self.capture("/usr/bin/tar", ["-tzf", tarball.path])
                .split(separator: "\n").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        }

        let off = try await listing(.init(includeAuth: false, includeMcpTokens: false, includeLogs: false, checkpointedWAL: false), "off.scarfbackup")
        for secret in ["auth.json", "auth.json.corrupt", "gateway_state.json", "mcp-tokens", "linear.json", "github.json", "linear.client.json", "agent.log"] {
            #expect(!off.contains { $0.hasSuffix("/" + secret) || $0.contains("/" + secret + "/") },
                    "\(secret) shipped: \(off.sorted())")
        }
        // Everything else in the profiles still ships.
        for kept in ["./config.yaml", "./profiles/work/config.yaml",
                     "./profiles/work/skills/notes/SKILL.md", "./profiles/my team [2]/SOUL.md",
                     "./profiles/work/skills/notes/logs/keep.md"] {
            #expect(off.contains(kept), "\(kept) missing: \(off.sorted())")
        }

        // Auth on: every home's auth.json ships; tokens and runtime state still don't.
        let on = try await listing(.init(includeAuth: true, includeMcpTokens: false, includeLogs: false, checkpointedWAL: false), "on.scarfbackup")
        for kept in ["./auth.json", "./profiles/work/auth.json", "./profiles/my team [2]/auth.json"] {
            #expect(on.contains(kept), "\(kept) missing: \(on.sorted())")
        }
        #expect(!on.contains { $0.contains("mcp-tokens") || $0.hasSuffix("gateway_state.json") }, "\(on.sorted())")
    }

    @Test("backup excludes follow the home's own directory name")
    func excludesUseLeaf() {
        let ex = RemoteBackupService.hermesExcludes(
            leaf: "hermes-data",
            options: .init(includeAuth: false, includeMcpTokens: true, includeLogs: true, checkpointedWAL: false),
            databases: ["state.db", "profiles/a [1]/state.db"])
        #expect(ex.contains("hermes-data/state.db"))
        #expect(ex.contains("hermes-data/profiles/a \\[1\\]/state.db"), "glob-escaped")
        #expect(!ex.contains("*.db"), "a pattern would also drop a directory named x.db")
        #expect(ex.contains("*.db-wal"))
        #expect(ex.contains("*.retired-wal-*"))
        #expect(ex.contains("hermes-data/auth.json"))
        #expect(ex.contains("hermes-data/profiles/*/auth.json"), "every profile home has its own")
        #expect(ex.contains("hermes-data/gateway_state.json"))
        #expect(ex.contains("hermes-data/profiles/*/gateway_state.json"))
        #expect(!ex.contains("hermes-data/mcp-tokens"), "includeMcpTokens is on in this case")
        #expect(!ex.contains { $0.hasPrefix(".hermes/") })
        #expect(ex.contains("hermes-data/profiles/*/auth.json.corrupt"), "Hermes's copy of an unparseable store")
        let tokensOff = RemoteBackupService.hermesExcludes(leaf: ".hermes", options: .safeDefault, databases: [])
        #expect(tokensOff.contains(".hermes/mcp-tokens"))
        #expect(tokensOff.contains(".hermes/profiles/*/mcp-tokens"))
        #expect(RemoteBackupService.prunedDirs(options: .safeDefault).contains("profiles/*/mcp-tokens"),
                "the snapshot pass prunes the same trees")
        // Logs are named per profile: a `profiles/*/logs` wildcard would also
        // drop a skill's own `logs` folder.
        let logs = RemoteBackupService.prunedDirs(options: .safeDefault, profiles: ["work", "a [1]"])
        #expect(logs.contains("profiles/work/logs"))
        #expect(logs.contains("profiles/a \\[1\\]/logs"))
        #expect(!logs.contains("profiles/*/logs"))
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

    static func capture(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text
    }

    static func unzipped(_ archive: URL, in root: URL) throws -> URL {
        let dir = root.appendingPathComponent("unzipped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", archive.path, "-d", dir.path])
        return dir
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
