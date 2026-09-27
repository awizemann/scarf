import Foundation
import CryptoKit
#if canImport(os)
import os
#endif

/// Streams a Hermes home + project trees off a (local or remote) server
/// into a single `.scarfbackup` archive on disk.
///
/// **Why not just run `hermes backup`.** Hermes's CLI captures `~/.hermes/`
/// only; project file trees (the user's actual code) live outside that
/// home and aren't included. A "rebuild this droplet from scratch" flow
/// needs both. This service does both — Hermes home as one inner tarball,
/// each registered project as its own — and writes a manifest pinning the
/// source server, hermes version, and per-tarball SHA-256s so restore can
/// detect corruption before it half-extracts.
///
/// **Memory profile.** Tarballs stream over SSH (`tar -czf -`) and into
/// disk-backed temp files chunk-by-chunk via `streamRawBytes`. We never
/// hold a multi-GB buffer in RAM. The final ZIP step shells out to
/// `/usr/bin/zip`, which also streams from disk.
///
/// **Cleanup.** The temp dir lives under
/// `FileManager.default.temporaryDirectory` and is removed on every exit
/// path (success, failure, cancellation) via `defer`.
public final class RemoteBackupService: @unchecked Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "RemoteBackupService")
    #endif

    /// Assembling the outer `.scarfbackup` zip from the staged work dir
    /// (charter C10: every subprocess has a timeout). A ceiling on a wedged
    /// `zip`, not a budget — the work dir is the user's whole Hermes home,
    /// so a healthy run on a multi-GB home can legitimately take minutes,
    /// and a backup killed halfway is worse than one that takes a while.
    /// Mirrors ``RemoteRestoreService/unzipTimeout``, the same archive in
    /// the other direction.
    public static let zipTimeout: TimeInterval = 900

    public let context: ServerContext

    public init(context: ServerContext) {
        self.context = context
    }

    /// Coarse stages the UI binds to. The service publishes one of these
    /// per meaningful state change so a progress sheet can render
    /// "Archiving Hermes home — 412 MB so far" without polling.
    public enum Progress: Sendable, Equatable {
        case preflight
        /// Taking a read-only `.backup` snapshot of `state.db` on the host.
        case snapshottingDB
        case archivingHermes(bytesWritten: Int64)
        case archivingProject(name: String, bytesWritten: Int64)
        case bundling
        case finalizing
    }

    public enum BackupError: Error, LocalizedError {
        case preflightFailed(String)
        case remoteCommandFailed(String)
        case localIO(String)
        case zipFailed(String)
        /// `state.db` exists but no consistent read-only snapshot of it
        /// could be taken. The backup stops rather than archiving a live
        /// database file that could be torn or missing its WAL frames.
        case snapshotFailed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .preflightFailed(let m): return "Backup preflight failed: \(m)"
            case .remoteCommandFailed(let m): return "Remote command failed during backup: \(m)"
            case .localIO(let m): return "Local file I/O failed during backup: \(m)"
            case .zipFailed(let m): return "Couldn't assemble the backup archive: \(m)"
            case .snapshotFailed(let m): return "Couldn't take a consistent snapshot of state.db: \(m)"
            case .cancelled: return "Backup cancelled."
            }
        }
    }

    /// What the UI displays before any archiving starts. Populated by
    /// `preflight()` so the user can see (and confirm) total size +
    /// project count + hermes version before committing 4 minutes of
    /// SSH traffic.
    public struct PreflightSummary: Sendable, Equatable {
        public var hermesVersion: String?
        public var hermesHomePath: String
        public var hermesHomeBytes: Int64?
        public var projects: [ProjectSummary]
        /// `sqlite3` is on the host's PATH. It takes the read-only
        /// `state.db` snapshot; `python3` is the fallback.
        public var sqliteAvailable: Bool
        /// `python3` is on the host's PATH (snapshot fallback when
        /// `sqlite3` is missing or fails).
        public var pythonAvailable: Bool = false
        /// `<home>/state.db` exists on the host. When it does, the backup
        /// needs a snapshot tool; when it doesn't, there is nothing to
        /// snapshot.
        public var stateDBPresent: Bool = false

        /// True when the backup can't archive `state.db` safely: the file
        /// exists but neither snapshot tool is available.
        public var snapshotUnavailable: Bool {
            stateDBPresent && !sqliteAvailable && !pythonAvailable
        }

        public struct ProjectSummary: Sendable, Equatable {
            public var id: String
            public var name: String
            public var path: String
            public var sizeBytes: Int64?
            public var reachable: Bool
        }

        public var totalSizeBytes: Int64? {
            let parts: [Int64] = [hermesHomeBytes ?? 0] + projects.compactMap { $0.sizeBytes }
            let sum = parts.reduce(0, +)
            return sum > 0 ? sum : nil
        }
    }

    public struct BackupResult: Sendable {
        public var manifest: BackupManifest
        public var archiveURL: URL
        public var archiveSize: Int64
    }

    /// Probe the remote (or local) before committing to the full
    /// archive. Cheap — three short SSH calls and one file read. Safe
    /// to call repeatedly; nothing is mutated on the source side.
    public func preflight() async throws -> PreflightSummary {
        let transport = context.makeTransport()

        // 1. Resolve $HOME so the absolute paths in the manifest are
        //    canonical (e.g. `/home/alan/.hermes`, not the
        //    `~`-prefixed `HermesPathSet.home`).
        let homeResult = try await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", "echo \"$HOME\""],
            stdin: nil,
            timeout: 30
        )
        guard homeResult.exitCode == 0 else {
            throw BackupError.preflightFailed("Couldn't resolve remote $HOME (exit \(homeResult.exitCode)): \(homeResult.stderrString)")
        }
        let resolvedHome = homeResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Hermes version. Optional — older builds may not implement
        //    `--version`. Empty/missing isn't fatal; the manifest just
        //    won't carry a version stamp.
        let versionResult = try? await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", "hermes --version 2>/dev/null || true"],
            stdin: nil,
            timeout: 30
        )
        let hermesVersion: String? = {
            guard let r = versionResult, r.exitCode == 0 else { return nil }
            let trimmed = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        // 3. Hermes home size + canonical path. `context.paths.home`
        //    can be `~/.hermes` for remotes that didn't pin
        //    `SSHConfig.remoteHome`; tar doesn't expand `~`, so we
        //    resolve every path against the just-fetched $HOME
        //    BEFORE storing it in the summary. `tar -C '~'` would
        //    fail with "No such file or directory" otherwise (and
        //    `du -sb '~/.hermes' 2>/dev/null` swallows the same
        //    error silently — that's why preflight looked green).
        let hermesHome = Self.expandTilde(context.paths.home, home: resolvedHome)
        let hermesSize = await Self.estimateBytes(transport: transport, path: hermesHome)

        // 4. Enumerate projects via the existing transport-aware
        //    service. Empty registry → empty list, not an error.
        //    Same tilde expansion as above so project paths stored
        //    in `~/.hermes/scarf/projects.json` with `~/projects/foo`
        //    don't blow up later in `tar -C`.
        let registry = ProjectDashboardService(context: context).loadRegistry()
        var projectSummaries: [PreflightSummary.ProjectSummary] = []
        for project in registry.projects where !project.archived {
            let expanded = Self.expandTilde(project.path, home: resolvedHome)
            let reachable = transport.fileExists(expanded)
            let bytes = reachable ? await Self.estimateBytes(transport: transport, path: expanded) : nil
            projectSummaries.append(PreflightSummary.ProjectSummary(
                id: project.path,                       // path is the registry's stable handle
                name: project.name,
                path: expanded,
                sizeBytes: bytes,
                reachable: reachable
            ))
        }

        // 5. Snapshot tooling. `state.db` is archived from a read-only
        //    `.backup` snapshot (charter C3: Scarf never writes state.db),
        //    taken with `sqlite3` or, failing that, `python3`.
        let toolCheck = try? await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", Self.toolProbeScript(stateDB: hermesHome + "/state.db")],
            stdin: nil,
            timeout: 30
        )
        let tools = Self.parseToolProbe(toolCheck?.stdoutString ?? "")
        // No markers at all means the probe never ran; reading that as "no
        // state.db, no tools" would plan a backup without the sessions.
        guard tools.contains("probe") else {
            throw BackupError.preflightFailed(
                "couldn't check the server for state.db and sqlite3 (\(toolCheck.map { "exit \($0.exitCode)" } ?? "no response")).")
        }

        return PreflightSummary(
            hermesVersion: hermesVersion,
            hermesHomePath: hermesHome,
            hermesHomeBytes: hermesSize,
            projects: projectSummaries,
            sqliteAvailable: tools.contains("sqlite3"),
            pythonAvailable: tools.contains("python3"),
            stateDBPresent: tools.contains("statedb")
        )
    }

    /// Replace a leading `~` or `~/` with the resolved remote home.
    /// Tar (and most non-shell tools) don't expand tildes — only the
    /// shell does, and we deliberately single-quote paths in the
    /// command string for whitespace-safety, which then suppresses
    /// shell expansion. So we expand here, in Swift, with a
    /// known-good `$HOME` value.
    static func expandTilde(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// Run the full backup: stream Hermes home + each project tarball,
    /// build the manifest, ZIP everything into `archiveURL`. Caller
    /// holds the `Task` and can cancel; cooperative checks fire between
    /// stages.
    public func run(
        preflight: PreflightSummary,
        options: BackupManifest.Options,
        archiveURL: URL,
        progress: @Sendable @escaping (Progress) -> Void
    ) async throws -> BackupResult {
        let transport = context.makeTransport()

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        try Task.checkCancellation()
        progress(.preflight)

        // Stage 1: a consistent snapshot of state.db, archived as its own
        // tarball. This used to run `PRAGMA wal_checkpoint(TRUNCATE)` on
        // the live database: a write to state.db (charter C3), and not a
        // reliable one either. Under a busy gateway it checkpointed only
        // partially, still exited 0, and the frames left in the (excluded)
        // WAL were missing from the archive. The snapshot copies every
        // committed page, WAL frames included, through a connection that
        // cannot write the source (see ``snapshotScript(stateDB:snapshotDir:)``).
        // Hermes's own `hermes backup` snapshots the same way
        // (`hermes_cli/backup.py:101-104` @ v2026.9.24). The path comes from
        // the already-expanded hermesHomePath, never `context.paths.stateDB`,
        // which can still carry a literal `~`.
        //
        // It always runs, whatever preflight saw: the script itself decides
        // whether there is a state.db, so a probe that missed it can't
        // produce a "successful" backup with no sessions in it.
        let hermesLeaf = (preflight.hermesHomePath as NSString).lastPathComponent
        var stateEntry: BackupManifest.StateDBSnapshot?
        try Task.checkCancellation()
        progress(.snapshottingDB)
        guard !preflight.snapshotUnavailable else {
            throw BackupError.snapshotFailed(
                "neither sqlite3 nor python3 is available on the server. Install sqlite3 there and back up again.")
        }
        let snapshotDir = preflight.hermesHomePath + "/" + Self.snapshotDirPrefix + UUID().uuidString
        do {
            if let method = try await takeStateSnapshot(
                transport: transport,
                stateDB: preflight.hermesHomePath + "/state.db",
                snapshotDir: snapshotDir
            ) {
                try Task.checkCancellation()
                let stateTarball = workDir.appendingPathComponent(BackupArchiveLayout.stateDBTarballPath)
                let stateHash = try await streamToFile(
                    transport: transport,
                    command: Self.tarCommand(workDir: snapshotDir, target: "state.db", excludes: []),
                    destination: stateTarball
                ) { _ in }
                let stateSize = (try? FileManager.default.attributesOfItem(atPath: stateTarball.path)[.size] as? Int64) ?? 0
                stateEntry = BackupManifest.StateDBSnapshot(
                    tarballPath: BackupArchiveLayout.stateDBTarballPath,
                    tarballSize: stateSize,
                    tarballSHA256: stateHash,
                    method: method
                )
            }
        } catch {
            await removeSnapshotDir(transport: transport, snapshotDir: snapshotDir)
            throw error
        }
        await removeSnapshotDir(transport: transport, snapshotDir: snapshotDir)

        // Stage 2: Hermes home tarball, WITHOUT the live state.db (the
        // snapshot above stands in for it) or its sidecars. The home's
        // own directory name is archived, so a server whose Hermes home
        // isn't called `.hermes` backs up too.
        try Task.checkCancellation()
        let hermesTarball = workDir.appendingPathComponent("hermes.tar.gz")
        let hermesExcludes = Self.hermesExcludes(leaf: hermesLeaf, options: options)
        let hermesTarCmd = Self.tarCommand(
            workDir: preflight.hermesHomePath.deletingLastPathComponent_String(),
            target: hermesLeaf,
            excludes: hermesExcludes
        )
        let hermesHash = try await streamToFile(
            transport: transport,
            command: hermesTarCmd,
            destination: hermesTarball
        ) { written in
            progress(.archivingHermes(bytesWritten: written))
        }
        let hermesSize = (try? FileManager.default.attributesOfItem(atPath: hermesTarball.path)[.size] as? Int64) ?? 0

        // Stage 3: per-project tarballs.
        let projectsDir = workDir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        var projectEntries: [BackupManifest.ProjectEntry] = []
        for summary in preflight.projects where summary.reachable {
            try Task.checkCancellation()
            let projID = Self.stableID(forPath: summary.path)
            let outerName = "\(projID).tar.gz"
            let dest = projectsDir.appendingPathComponent(outerName)
            let parent = (summary.path as NSString).deletingLastPathComponent
            let leaf = (summary.path as NSString).lastPathComponent
            let cmd = Self.tarCommand(
                workDir: parent,
                target: leaf,
                excludes: Self.projectExcludes()
            )
            let hash = try await streamToFile(
                transport: transport,
                command: cmd,
                destination: dest
            ) { written in
                progress(.archivingProject(name: summary.name, bytesWritten: written))
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            projectEntries.append(BackupManifest.ProjectEntry(
                id: projID,
                name: summary.name,
                path: summary.path,
                tarballPath: BackupArchiveLayout.projectTarballPath(for: projID),
                tarballSize: size,
                tarballSHA256: hash
            ))
        }

        // Stage 4: build manifest, write to workDir.
        try Task.checkCancellation()
        let manifest = BackupManifest(
            createdAt: ISO8601DateFormatter().string(from: Date()),
            source: BackupManifest.Source(
                serverID: context.id.uuidString,
                displayName: context.displayName,
                host: Self.host(for: context),
                user: Self.user(for: context),
                hermesVersion: preflight.hermesVersion
            ),
            hermes: BackupManifest.HermesTree(
                homePath: preflight.hermesHomePath,
                tarballPath: BackupArchiveLayout.hermesTarballPath,
                tarballSize: hermesSize,
                tarballSHA256: hermesHash
            ),
            projects: projectEntries,
            options: BackupManifest.Options(
                includeAuth: options.includeAuth,
                includeMcpTokens: options.includeMcpTokens,
                includeLogs: options.includeLogs,
                // Nothing checkpoints the WAL any more (C3). How state.db
                // was captured is recorded, truthfully, in `stateDB`.
                checkpointedWAL: false
            ),
            stateDB: stateEntry
        )
        let manifestData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            manifestData = try encoder.encode(manifest)
        } catch {
            throw BackupError.localIO("Couldn't encode manifest: \(error.localizedDescription)")
        }
        let manifestURL = workDir.appendingPathComponent(BackupArchiveLayout.manifestPath)
        do {
            try manifestData.write(to: manifestURL, options: .atomic)
        } catch {
            throw BackupError.localIO("Couldn't write manifest: \(error.localizedDescription)")
        }

        // Stage 5: ZIP everything in workDir into the user-chosen
        // destination. Atomic via temp file + rename so a half-written
        // archive isn't visible.
        try Task.checkCancellation()
        progress(.bundling)
        let tempArchive = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".\(archiveURL.lastPathComponent).inflight-\(UUID().uuidString).zip")
        try await Self.zipDirectory(workDir: workDir, into: tempArchive)
        progress(.finalizing)
        do {
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }
            try FileManager.default.moveItem(at: tempArchive, to: archiveURL)
        } catch {
            try? FileManager.default.removeItem(at: tempArchive)
            throw BackupError.localIO("Couldn't move archive into place: \(error.localizedDescription)")
        }

        let archiveSize = (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int64) ?? 0
        return BackupResult(
            manifest: manifest,
            archiveURL: archiveURL,
            archiveSize: archiveSize
        )
    }

    // MARK: - Streaming

    /// Spawn a remote (or local) `bash -lc <cmd>` and pump its stdout
    /// into `destination`, computing SHA-256 incrementally as bytes
    /// arrive. Returns the hex digest. The process gets a fresh
    /// `bash -lc` shell on each invocation — same login-shell story
    /// as `streamRawBytes` so PATH picks up pipx installs etc.
    private func streamToFile(
        transport: any ServerTransport,
        command: String,
        destination: URL,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws -> String {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: destination) else {
            throw BackupError.localIO("Couldn't open \(destination.lastPathComponent) for writing")
        }
        defer { try? fh.close() }
        var hasher = SHA256()
        var written: Int64 = 0
        let stream = transport.streamRawBytes(
            executable: "/bin/bash",
            args: ["-lc", command]
        )
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                try fh.write(contentsOf: chunk)
                hasher.update(data: chunk)
                written += Int64(chunk.count)
                onProgress(written)
            }
        } catch is CancellationError {
            throw BackupError.cancelled
        } catch let err as TransportError {
            throw BackupError.remoteCommandFailed(err.localizedDescription)
        } catch {
            throw BackupError.remoteCommandFailed(error.localizedDescription)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Tar / shell helpers

    static func tarCommand(workDir: String, target: String, excludes: [String]) -> String {
        var parts: [String] = ["tar -czf -"]
        for ex in excludes {
            parts.append("--exclude=\(shellQuote(ex))")
        }
        parts.append("-C \(shellQuote(workDir))")
        parts.append(shellQuote(target))
        return parts.joined(separator: " ")
    }

    /// Always-on Hermes-tree exclusions, regardless of options: the live
    /// `state.db` (archived separately from a read-only snapshot) and its
    /// SQLite sidecars, Scarf's own snapshot and restore staging
    /// directories, and runtime state files (`gateway_state.json`).
    ///
    /// `leaf` is the home's own directory name: `.hermes` for a default
    /// install, something else for a server whose Hermes home was
    /// configured elsewhere.
    static func hermesExcludes(leaf: String, options: BackupManifest.Options) -> [String] {
        var excludes: [String] = [
            "\(leaf)/state.db",
            "\(leaf)/state.db-wal",
            "\(leaf)/state.db-shm",
            "\(leaf)/state.db-journal",
            "\(leaf)/\(snapshotDirPrefix)*",
            "\(leaf)/\(RemoteRestoreService.stagingDirPrefix)*",
            "\(leaf)/gateway_state.json",
        ]
        if !options.includeAuth { excludes.append("\(leaf)/auth.json") }
        if !options.includeMcpTokens { excludes.append("\(leaf)/mcp-tokens") }
        if !options.includeLogs { excludes.append("\(leaf)/logs") }
        return excludes
    }

    // MARK: - state.db snapshot

    /// Prefix of the directory the snapshot is written into, inside the
    /// Hermes home: the same filesystem as the database, and a directory
    /// the Hermes user can always write. `/tmp` is often a small tmpfs
    /// that a multi-GB state.db won't fit in.
    static let snapshotDirPrefix = ".scarf-backup-snapshot-"

    /// Ceiling on the snapshot copy (charter C10). Generous: it copies the
    /// whole database, which can be several GB on a long-lived host.
    static let snapshotTimeout: TimeInterval = 900

    /// Prints one `SCARF_TOOL:<name>` line per snapshot input that is
    /// available on the host. Markers, because a login shell can print
    /// its own noise to stdout.
    static func toolProbeScript(stateDB: String) -> String {
        [
            "[ -f \(shellQuote(stateDB)) ] && echo SCARF_TOOL:statedb",
            "command -v sqlite3 >/dev/null 2>&1 && echo SCARF_TOOL:sqlite3",
            "command -v python3 >/dev/null 2>&1 && echo SCARF_TOOL:python3",
            "echo SCARF_TOOL:probe",
        ].joined(separator: "; ")
    }

    static func parseToolProbe(_ stdout: String) -> Set<String> {
        Set(stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SCARF_TOOL:") else { return nil }
            return String(trimmed.dropFirst("SCARF_TOOL:".count))
        })
    }

    /// The host-side snapshot script: a consistent copy of `stateDB` in
    /// `<snapshotDir>/state.db`, taken so that nothing can write to the
    /// source. Tried in order, first success wins:
    ///
    /// 1. `sqlite3 -readonly … VACUUM INTO` (SQLite 3.27+): one read
    ///    transaction, so a busy writer can't make it start over.
    /// 2. `sqlite3 -readonly … .backup`, for an older sqlite3.
    /// 3. The same `.backup` on a READWRITE connection with
    ///    `PRAGMA query_only=1` and `.dbconfig no_ckpt_on_close on`, for a
    ///    sqlite3 that can't open a WAL database read-only when its `-wal`
    ///    and `-shm` are gone (a stopped Hermes; Apple's `/usr/bin/sqlite3`
    ///    is one). Only after the CLI proves on `:memory:` that it honours
    ///    `no_ckpt_on_close`, exactly as `RemoteSQLiteBackend`'s relaxed
    ///    reads do: a writable connection that is the last to close would
    ///    otherwise checkpoint the WAL into state.db (charter C3).
    /// 4. `python3`'s `sqlite3.Connection.backup()` (one step) from a
    ///    `mode=ro` URI. Not on macOS, where `/usr/bin/python3` can be the
    ///    Command Line Tools installer stub.
    ///
    /// Prints `SCARF_SNAPSHOT_OK:<tool>` on success,
    /// `SCARF_SNAPSHOT_ABSENT` when there is no `state.db` to copy, and
    /// exits non-zero otherwise.
    static func snapshotScript(stateDB: String, snapshotDir: String) -> String {
        let db = shellQuote(stateDB)
        let destPath = snapshotDir + "/state.db"
        let dest = shellQuote(destPath)
        // SQL string literal: `'` doubled. Passed through bash single quotes.
        let vacuum = shellQuote("VACUUM INTO '" + destPath.replacingOccurrences(of: "'", with: "''") + "'")
        // `.backup` takes a dot-command argument: double-quoted for the
        // sqlite3 shell, which reads `\` and `"` escapes inside it.
        let dotBackup = shellQuote(".backup \"" + destPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\"")
        let python = [
            "import sqlite3,sys,urllib.request as u",
            "s=sqlite3.connect('file:'+u.pathname2url(sys.argv[1])+'?mode=ro',uri=True,timeout=10)",
            "d=sqlite3.connect(sys.argv[2])",
            "s.backup(d)",
            "d.close()",
            "s.close()",
        ].joined(separator: "\n")
        let relaxed = "sqlite3 -cmd '.output /dev/null' -cmd '.dbconfig no_ckpt_on_close on' -cmd '.output stdout' -cmd 'PRAGMA query_only=1' -cmd '.timeout 10000'"
        return [
            "[ -f \(db) ] || { echo SCARF_SNAPSHOT_ABSENT; exit 0; }",
            "mkdir -p \(shellQuote(snapshotDir)) || exit 1",
            "if command -v sqlite3 >/dev/null 2>&1; then",
            "  if sqlite3 -readonly -cmd '.timeout 10000' \(db) \(vacuum); then echo SCARF_SNAPSHOT_OK:sqlite3; exit 0; fi",
            "  rm -f \(dest)",
            "  if sqlite3 -readonly -cmd '.timeout 10000' \(db) \(dotBackup); then echo SCARF_SNAPSHOT_OK:sqlite3; exit 0; fi",
            "  rm -f \(dest)",
            "  case \"$(sqlite3 :memory: '.dbconfig no_ckpt_on_close on' 2>/dev/null)\" in",
            "    *'no_ckpt_on_close on'*)",
            "      if \(relaxed) \(db) \(dotBackup); then echo SCARF_SNAPSHOT_OK:sqlite3-query-only; exit 0; fi",
            "      rm -f \(dest) ;;",
            "  esac",
            "fi",
            "if [ \"$(uname -s 2>/dev/null)\" != Darwin ] && command -v python3 >/dev/null 2>&1 && python3 -c \(shellQuote(python)) \(db) \(dest); then echo SCARF_SNAPSHOT_OK:python3; exit 0; fi",
            "rm -f \(dest)",
            "exit 1",
        ].joined(separator: "\n")
    }

    /// Run ``snapshotScript(stateDB:snapshotDir:)`` and return the tool
    /// that produced the snapshot, or `nil` when the host has no state.db.
    /// Throws ``BackupError/snapshotFailed(_:)`` with the host's own
    /// explanation when no method succeeded.
    private func takeStateSnapshot(
        transport: any ServerTransport,
        stateDB: String,
        snapshotDir: String
    ) async throws -> String? {
        let result: ProcessResult
        do {
            result = try await transport.asyncRunProcess(
                executable: "/bin/bash",
                args: ["-lc", Self.snapshotScript(stateDB: stateDB, snapshotDir: snapshotDir)],
                stdin: nil,
                timeout: Self.snapshotTimeout
            )
        } catch {
            throw BackupError.snapshotFailed(error.localizedDescription)
        }
        if result.exitCode == 0,
           result.stdoutString.split(whereSeparator: \.isNewline).contains(where: { $0 == "SCARF_SNAPSHOT_ABSENT" }) {
            return nil
        }
        guard result.exitCode == 0,
              let marker = result.stdoutString
                .split(whereSeparator: \.isNewline)
                .last(where: { $0.hasPrefix("SCARF_SNAPSHOT_OK:") }) else {
            let why = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackupError.snapshotFailed(why.isEmpty ? "exit \(result.exitCode)" : why)
        }
        return String(marker.dropFirst("SCARF_SNAPSHOT_OK:".count))
    }

    /// Best-effort removal of the snapshot directory. A leftover (a run
    /// killed mid-way) is excluded from later backups by
    /// ``hermesExcludes(leaf:options:)``.
    private func removeSnapshotDir(transport: any ServerTransport, snapshotDir: String) async {
        _ = try? await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", "rm -rf \(Self.shellQuote(snapshotDir))"],
            stdin: nil,
            timeout: 60
        )
    }

    /// Default project-tree exclusions: things that don't restore well
    /// (compiled object stores, virtualenvs that hard-code absolute
    /// paths, system-specific build outputs). Users can opt in via
    /// the future "include build artefacts" toggle in the Backup
    /// sheet — for now we always exclude these.
    private static func projectExcludes() -> [String] {
        [
            "*/node_modules",
            "*/.venv",
            "*/venv",
            "*/__pycache__",
            "*/.git/objects",
            "*/.next",
            "*/dist",
            "*/.DS_Store",
        ]
    }

    /// Single-quote a path / argument for embedding in a `bash -lc`
    /// string. Uses POSIX-safe single quotes with escape for embedded
    /// quotes (`'` → `'\''`).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Convenience: same idea as ServerContext.host, but tolerates the
    /// local case (no host) by returning `"localhost"`.
    private static func host(for context: ServerContext) -> String {
        if case .ssh(let cfg) = context.kind {
            return cfg.host
        }
        return "localhost"
    }

    private static func user(for context: ServerContext) -> String? {
        if case .ssh(let cfg) = context.kind {
            return cfg.user
        }
        return nil
    }

    /// `du -sb` (GNU) is the most portable way to get raw bytes —
    /// on macOS `du -sk` returns kilobytes. Returns nil if neither
    /// works.
    private static func estimateBytes(transport: any ServerTransport, path: String) async -> Int64? {
        let cmd = "du -sb \(shellQuote(path)) 2>/dev/null | awk '{print $1}'"
        guard let r = try? await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", cmd],
            stdin: nil,
            timeout: 60
        ), r.exitCode == 0 else { return nil }
        let s = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(s)
    }

    /// Stable ID for a project. The project registry tracks projects
    /// by absolute path, but paths can differ between source and
    /// target (different `$HOME`). We hash the path to get a stable
    /// 16-hex-char identifier that's safe to use as a tarball
    /// filename. Collisions are vanishingly unlikely — a Mac's path
    /// space is small and SHA-256 truncated to 64 bits has good
    /// properties for non-adversarial input.
    private static func stableID(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let bytes = digest.map { String(format: "%02x", $0) }.joined()
        return String(bytes.prefix(16))
    }

    /// Shell out to `/usr/bin/zip` to assemble the outer archive.
    /// macOS ships `zip` at this fixed path so we don't need a PATH
    /// search. `-r` recurse, `-q` quiet, `-X` strip extended attrs
    /// for reproducibility.
    ///
    /// Mac-only: iOS doesn't ship `/usr/bin/zip` and Foundation's `Process`
    /// is unavailable in the iOS SDK. The whole backup flow is a Mac-side
    /// operation; the iOS stub throws so any accidental call surfaces a
    /// clear message instead of an opaque link error.
    static func zipDirectory(
        workDir: URL,
        into archive: URL,
        timeout: TimeInterval = RemoteBackupService.zipTimeout
    ) async throws {
        #if os(iOS)
        throw BackupError.zipFailed("Backup zip is not supported on iOS — run the backup from the Mac app.")
        #else
        // **The clock starts BEFORE `run()`.** `timeout` is the caller's
        // wall-clock ceiling on the whole operation, and a fork+exec is part
        // of that operation — starting the budget after the spawn quietly
        // grants the child however long the machine took to start it, which
        // under load is the difference between a bounded wait and a generous
        // one. It also lets the overrun tests use a fixture sized to the
        // BOUND rather than one large enough to outrun a free head start
        // (round-5 decision 8).
        let started = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = workDir
        proc.arguments = ["-rqX", archive.path, "."]
        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe
        do {
            try proc.run()
        } catch {
            try? errPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForWriting.close()
            try? outPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            throw BackupError.zipFailed("Couldn't launch zip: \(error.localizedDescription)")
        }
        // C10: bounded, and drained CONCURRENTLY with the wait. `zip` prints
        // a warning per unreadable entry, and a Hermes home full of sockets
        // and permission-denied files produces enough of them to fill the
        // 64 KB pipe buffer — which deadlocks a parent that reads only after
        // the wait. See ``Process.waitDrainingAsync(timeout:pipes:drainGrace:)``.
        let (exited, drained) = await proc.waitDrainingAsync(
            timeout: max(0, timeout - Date().timeIntervalSince(started)),
            pipes: [errPipe, outPipe])
        // The write ends stay ours; the drain owns the read ends.
        try? errPipe.fileHandleForWriting.close()
        try? outPipe.fileHandleForWriting.close()
        guard exited else {
            throw BackupError.zipFailed("zip did not finish within \(Int(timeout))s and was stopped")
        }
        if proc.terminationStatus != 0 {
            let tail = String(data: drained.first ?? Data(), encoding: .utf8) ?? ""
            throw BackupError.zipFailed("zip exited \(proc.terminationStatus): \(tail)")
        }
        #endif
    }
}

// MARK: - Path helpers

private extension String {
    /// `(somePath as NSString).deletingLastPathComponent` lifted to a
    /// String extension. Used during preflight to derive the
    /// remote `$HOME` from `$HOME/.hermes`.
    func deletingLastPathComponent_String() -> String {
        (self as NSString).deletingLastPathComponent
    }
}
