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
            return Self.versionHeadline(r.stdoutString)
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

        // Stage 1: consistent snapshots of every `*.db` in the home
        // (state.db, each profile's state.db, kanban.db, response_store.db,
        // cron/executions.db, …), archived as their own tarball. This used
        // to run `PRAGMA wal_checkpoint(TRUNCATE)` on the live state.db: a
        // write to state.db (charter C3), and not a reliable one either.
        // Under a busy gateway it checkpointed only partially, still exited
        // 0, and the frames left in the (excluded) WAL were missing from
        // the archive; every other database was tarred live. Each snapshot
        // copies every committed page, WAL frames included, through a
        // connection that cannot write the source
        // (``HermesDatabaseScripts/snapshotFunction``), which is how
        // `hermes backup` snapshots every `*.db`
        // (`hermes_cli/backup.py:101-104`, `:590-610` @ v2026.9.24). The
        // paths come from the already-expanded hermesHomePath, never
        // `context.paths`, which can still carry a literal `~`.
        //
        // It always runs, whatever preflight saw: the script finds the
        // databases itself, so a probe that missed one can't produce a
        // "successful" backup without it.
        let hermesLeaf = (preflight.hermesHomePath as NSString).lastPathComponent
        var databases: BackupManifest.DatabaseSnapshots?
        try Task.checkCancellation()
        progress(.snapshottingDB)
        guard !preflight.snapshotUnavailable else {
            throw BackupError.snapshotFailed(
                "neither sqlite3 nor python3 is available on the server. Install sqlite3 there and back up again.")
        }
        let snapshotDir = preflight.hermesHomePath + "/" + HermesDatabaseScripts.snapshotDirPrefix + UUID().uuidString
        // Named profiles, for the per-profile `logs` exclusion. Best effort:
        // a listing that fails only means those logs ride along.
        let profileNames = (try? transport.listDirectory(preflight.hermesHomePath + "/profiles")) ?? []
        // What each home's `cache/` holds, so everything but the durable
        // subdirectories Hermes keeps can be left out (see
        // ``runtimeExcludedPaths(profiles:cacheEntries:)``). Best effort,
        // like the profile listing: a cache that can't be listed rides along.
        var cacheEntries: [String: [String]] = [:]
        for dir in ["cache"] + Self.listableProfiles(profileNames).map({ "profiles/\($0)/cache" }) {
            if let entries = try? transport.listDirectory(preflight.hermesHomePath + "/" + dir) {
                cacheEntries[dir] = entries
            }
        }
        var snapshotted: [String] = []
        do {
            let report = try await takeDatabaseSnapshots(
                transport: transport,
                home: preflight.hermesHomePath,
                snapshotDir: snapshotDir,
                options: options,
                profiles: profileNames,
                cacheEntries: cacheEntries,
                timeout: Self.snapshotTimeout(homeBytes: preflight.hermesHomeBytes)
            )
            snapshotted = report.ok.map(\.path) + report.failed
            let skipped = report.failed
            if !report.ok.isEmpty {
                try Task.checkCancellation()
                let tarball = workDir.appendingPathComponent(BackupArchiveLayout.databasesTarballPath)
                let hash = try await streamToFile(
                    transport: transport,
                    command: Self.tarCommand(workDir: snapshotDir, target: ".", excludes: []),
                    destination: tarball
                ) { _ in }
                let size = (try? FileManager.default.attributesOfItem(atPath: tarball.path)[.size] as? Int64) ?? 0
                databases = BackupManifest.DatabaseSnapshots(
                    tarballPath: BackupArchiveLayout.databasesTarballPath,
                    tarballSize: size,
                    tarballSHA256: hash,
                    entries: report.ok.map { .init(path: $0.path, method: $0.method) },
                    skipped: skipped
                )
            } else if !skipped.isEmpty {
                databases = BackupManifest.DatabaseSnapshots(
                    tarballPath: "", tarballSize: 0, tarballSHA256: "", entries: [], skipped: skipped)
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
        let hermesExcludes = Self.hermesExcludes(
            leaf: hermesLeaf, options: options, databases: snapshotted, profiles: profileNames,
            cacheEntries: cacheEntries)
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
            databases: databases
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

    /// The version line out of `hermes --version`'s banner. The command
    /// prints several lines — version, install directory, install method,
    /// Python, OpenAI SDK and, when it checked, an update note
    /// (`hermes_cli/_startup_fast.py:181-221` @ v2026.9.24) — and the whole
    /// banner used to be stored as the manifest's version and shown as one
    /// six-line row. The first `Hermes Agent …` line wins (it has led the
    /// output since v2026.3.12); failing that, the first non-empty line, so
    /// a login shell's own chatter before it is skipped. `nil` for nothing.
    public static func versionHeadline(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first { $0.hasPrefix("Hermes Agent") } ?? lines.first
    }

    // MARK: - Tar / shell helpers

    /// The `tar -czf -` a backup stage streams, with the one exit status
    /// that is not a failure mapped to 0.
    ///
    /// GNU tar exits 1 when a file changed while it was being read — `file
    /// changed as we read it`, including a DIRECTORY whose entries changed,
    /// which a running gateway causes at least once a minute by atomically
    /// rewriting `gateway_state.json` in the home root
    /// (`gateway/status.py:743-744` @ v2026.9.24). The archive is complete
    /// and valid; `--warning=no-file-changed` only hides the message, the
    /// status stays 1. Treating it as fatal made every backup of a Linux
    /// host with a live gateway fail. Exit 2 (fatal: an unreadable file, a
    /// write error) still fails.
    ///
    /// Only GNU tar's 1 means that. bsdtar (a Mac) and BusyBox tar exit 1
    /// for real errors, such as a file they could not open, so there any
    /// non-zero status still fails. `tar --version`'s output goes to grep,
    /// never into the archive stream on stdout.
    static func tarCommand(workDir: String, target: String, excludes: [String]) -> String {
        var parts: [String] = ["tar -czf -"]
        for ex in excludes {
            parts.append("--exclude=\(shellQuote(ex))")
        }
        parts.append("-C \(shellQuote(workDir))")
        parts.append(shellQuote(target))
        return parts.joined(separator: " ") + "; " + tarExitFilter
    }

    /// See ``tarCommand(workDir:target:excludes:)``.
    static let tarExitFilter =
        "scarf_rc=$?; if [ \"$scarf_rc\" -eq 1 ] && tar --version 2>/dev/null | grep -q 'GNU tar'; then exit 0; fi; exit \"$scarf_rc\""

    /// Always-on Hermes-tree exclusions, regardless of options: each live
    /// database the snapshot pass found (`databases`, home-relative: they
    /// are archived from consistent snapshots, or listed as skipped), every
    /// SQLite sidecar, Hermes's retired-WAL captures (left out whole, as
    /// `hermes backup` does), Scarf's own snapshot and restore staging
    /// directories, and runtime state files (`gateway_state.json`).
    ///
    /// The databases are excluded by their exact (glob-escaped) paths, not a
    /// `*.db` pattern, which would also swallow a DIRECTORY named `x.db` and
    /// everything in it. The sidecar patterns are unanchored, so they reach
    /// every subdirectory under both GNU tar and bsdtar.
    ///
    /// `leaf` is the home's own directory name: `.hermes` for a default
    /// install, something else for a server whose Hermes home was
    /// configured elsewhere.
    ///
    /// Every named profile is a Hermes home of its own, under
    /// `profiles/<name>/`, with its own `auth.json`, `mcp-tokens/` and
    /// `gateway_state.json` (`hermes_cli/profiles.py:174-177`,
    /// `hermes_cli/auth.py:481-482`, `tools/mcp_oauth.py:229-232`
    /// @ v2026.9.24). So each credential and runtime-state exclusion is made
    /// twice: once at the home's root and once as `profiles/*/…`. The `*`
    /// crosses `/` in GNU tar and bsdtar exclude patterns (not in BusyBox
    /// tar), so there the profile form also drops a file of that exact name
    /// deeper inside a profile: over-excluding a stray `auth.json` is the
    /// safe direction when the user asked for no credentials. `auth.json`
    /// goes with the copy Hermes keeps of a store it couldn't parse,
    /// `auth.json.corrupt` (`hermes_cli/auth.py:679`).
    ///
    /// `profiles` are the profile directory names found on the host, used
    /// for exclusions that must NOT over-reach (see ``prunedDirs(options:profiles:)``).
    ///
    /// Everything `hermes backup` itself leaves out is left out too
    /// (`hermes_cli/backup.py:46-81,106-118` @ v2026.9.24): the Hermes
    /// codebase, dependency trees, caches, prior backups and snapshots,
    /// runtime downloads, pid files and browser profiles — see
    /// ``hermesAnyDepthExcludes``, ``anyDepthPatterns(leaf:names:)`` and
    /// ``runtimeExcludedPaths(profiles:cacheEntries:)``.
    static func hermesExcludes(
        leaf: String, options: BackupManifest.Options, databases: [String], profiles: [String] = [],
        cacheEntries: [String: [String]] = [:]
    ) -> [String] {
        var excludes: [String] = databases.map { HermesDatabaseScripts.globEscape(leaf + "/" + $0) }
        excludes += [
            "*.db-wal",
            "*.db-shm",
            "*.db-journal",
            HermesDatabaseScripts.retiredWALPattern,
            "\(leaf)/\(HermesDatabaseScripts.snapshotDirPrefix)*",
            "\(leaf)/\(HermesDatabaseScripts.stagingDirPrefix)*",
        ]
        excludes += homeScoped("gateway_state.json").map { "\(leaf)/\($0)" }
        excludes += anyDepthPatterns(leaf: leaf, names: hermesAnyDepthExcludes)
        excludes += prunedDirs(options: options, profiles: profiles, cacheEntries: cacheEntries)
            .map { "\(leaf)/\($0)" }
        if !options.includeAuth {
            excludes += (homeScoped("auth.json") + homeScoped("auth.json.corrupt")).map { "\(leaf)/\($0)" }
        }
        return excludes
    }

    /// Home-relative paths the backup leaves out entirely, so their
    /// databases (if any) are not snapshotted either. Each is listed for
    /// the root home and for every profile home (see
    /// ``hermesExcludes(leaf:options:databases:profiles:)``).
    ///
    /// `logs` is named per profile (`profiles/<name>/logs`, from the
    /// directory listing), not as `profiles/*/logs`: that wildcard would
    /// also drop a `logs` folder deep inside a profile's skills, which is
    /// the user's data. A profile missed by the listing keeps its logs,
    /// which only costs archive size.
    ///
    /// Also always the Hermes-managed trees ``runtimeExcludedPaths(profiles:cacheEntries:)``
    /// names, whatever the options say.
    static func prunedDirs(
        options: BackupManifest.Options, profiles: [String] = [], cacheEntries: [String: [String]] = [:]
    ) -> [String] {
        var dirs: [String] = []
        if !options.includeMcpTokens { dirs += homeScoped("mcp-tokens") }
        if !options.includeLogs {
            dirs.append("logs")
            dirs += listableProfiles(profiles)
                .map { "profiles/" + HermesDatabaseScripts.globEscape($0) + "/logs" }
        }
        dirs += runtimeExcludedPaths(profiles: profiles, cacheEntries: cacheEntries)
        return dirs
    }

    /// Profile directory names that can be spliced into a path.
    static func listableProfiles(_ profiles: [String]) -> [String] {
        profiles.filter { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }
    }

    // MARK: - What `hermes backup` leaves out (hermes_cli/backup.py @ v2026.9.24)

    /// `_EXCLUDED_DIRS` (`backup.py:52-69`) without `hermes-agent`, which
    /// Hermes matches only at the home's root (see
    /// ``runtimeExcludedPaths(profiles:cacheEntries:)``). Hermes skips these
    /// at ANY depth (`_should_exclude`, `:270-279`): prior backups and
    /// state snapshots (each a full state.db copy), trajectory checkpoints,
    /// dependency trees and tool caches, nested `.git`, and both browser
    /// profile stores. `browser-profile/` holds copies of the user's real
    /// browser Cookies and Login Data — a credential store Hermes says must
    /// never enter an archive — so it is excluded whether or not the user
    /// included `auth.json`.
    static let hermesAnyDepthExcludedDirs = [
        "__pycache__", ".git", "node_modules", "backups", "state-snapshots", "checkpoints",
        "browser-profiles", "browser-profile", ".venv", "venv", "site-packages",
        ".cache", ".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ]

    /// `_EXCLUDED_NAMES` (`:108`: runtime lock and pid files), the `.pyc` /
    /// `.pyo` half of `_EXCLUDED_SUFFIXES` (`:106`; the SQLite sidecars are
    /// excluded above) and the updater's `state.db.pre-update-emergency-*`
    /// backups (`_EXCLUDED_PREFIXES`, `:115-118`; the other prefix is the
    /// retired-WAL capture, already excluded). Any depth, as in Hermes.
    static let hermesAnyDepthExcludedFiles = [
        ".backup.lock", "gateway.pid", "cron.pid", "*.pyc", "*.pyo", "state.db.pre-update-emergency-*",
    ]

    static var hermesAnyDepthExcludes: [String] { hermesAnyDepthExcludedDirs + hermesAnyDepthExcludedFiles }

    /// How many directories below the home an any-depth pattern reaches on
    /// BusyBox tar. Eight covers
    /// `profiles/<name>/skills/<category>/<skill>/node_modules` with room to
    /// spare; GNU tar and bsdtar reach every depth (see below).
    static let anyDepthPatternDepth = 8

    /// Exclude patterns for names Hermes skips at any depth BELOW the home:
    /// `leaf/x`, `leaf/*/x`, `leaf/*/*/x`, ….
    ///
    /// Never the bare name. Tar is run as `-C <parent> <leaf>`, and every tar
    /// also tries an unanchored pattern against the home's own directory, so
    /// a home whose directory is called `backups` or `venv` would archive
    /// nothing (Hermes matches home-relative paths, where the home's own
    /// name never appears).
    ///
    /// The per-depth forms are for BusyBox tar: its `*` never crosses `/`
    /// when creating an archive, and when EXTRACTING it anchors a pattern at
    /// the start of the member name and compares only as many components as
    /// the pattern has (`find_list_entry2`), so a bare `x` never matched
    /// below the top directory at all. GNU tar and bsdtar let `*` cross `/`,
    /// so there `leaf/*/x` alone already reaches every depth; the extra forms
    /// only repeat it, and are only ever built from names Hermes excludes at
    /// any depth anyway.
    static func anyDepthPatterns(leaf: String, names: [String]) -> [String] {
        let top = HermesDatabaseScripts.globEscape(leaf)
        return names.flatMap { name in
            (0..<anyDepthPatternDepth).map { depth in
                top + "/" + String(repeating: "*/", count: depth) + name
            }
        }
    }

    /// Hermes-managed runtime trees matched ONLY at the root of a home — the
    /// root home and each `profiles/<name>/` — because a deeper directory of
    /// the same name (a skill's `models/`) is user data
    /// (`_in_excluded_root_dir`, `backup.py:84-93`): `LOCAL_RUNTIME_ROOT_DIRS`
    /// (`models`, `runtimes`, `node` — GGUF weights, llama.cpp runtimes,
    /// managed Node; `hermes_constants.py:210`) and `browser_profiles`
    /// (the Browser Use CLI's Chromium profile, `:78-81`).
    static let hermesHomeRootExcludedDirs = ["models", "runtimes", "node", "browser_profiles"]

    /// The `cache/` subdirectories Hermes keeps (`_KEPT_CACHE_SUBDIRS`,
    /// `:83`): media the gateway delivered or received and the citations
    /// ledger, which nothing can rebuild. Everything else directly under a
    /// home's `cache/` is regenerable and left out.
    static let hermesKeptCacheEntries: Set<String> = [
        "images", "audio", "videos", "documents", "screenshots", "citations",
    ]

    /// Home-relative paths of the Hermes-managed trees, each named exactly:
    ///
    /// - `hermes-agent` at the root only (`backup.py:46-47`, `:278`): the
    ///   Hermes codebase, venv and `.git` included, which is where a default
    ///   non-root install puts it (`scripts/install.sh:188`). Restoring it
    ///   over another host overwrote that host's installed Hermes.
    /// - ``hermesHomeRootExcludedDirs`` at the root and at each profile root.
    /// - every entry of a home's `cache/` that is not one of
    ///   ``hermesKeptCacheEntries`` (`cacheEntries` maps `cache` or
    ///   `profiles/<name>/cache` to that directory's listing).
    ///
    /// Exact per-profile names, never a `profiles/*/…` wildcard: GNU tar and
    /// bsdtar let `*` cross `/`, so the wildcard would also drop a skill's
    /// own `models/` deep inside a profile.
    static func runtimeExcludedPaths(profiles: [String], cacheEntries: [String: [String]]) -> [String] {
        let homes = [""] + listableProfiles(profiles).map { "profiles/" + HermesDatabaseScripts.globEscape($0) + "/" }
        var paths = ["hermes-agent"]
        for home in homes {
            paths += hermesHomeRootExcludedDirs.map { home + $0 }
        }
        for (cacheDir, entries) in cacheEntries.sorted(by: { $0.key < $1.key }) {
            let dir = cacheDir.split(separator: "/").map { HermesDatabaseScripts.globEscape(String($0)) }
                .joined(separator: "/")
            paths += entries
                .filter { !$0.isEmpty && !$0.contains("/") && !hermesKeptCacheEntries.contains($0) }
                .sorted()
                .map { dir + "/" + HermesDatabaseScripts.globEscape($0) }
        }
        return paths
    }

    /// `name` at the root of the Hermes home and at the root of each
    /// profile home.
    static func homeScoped(_ name: String) -> [String] {
        [name, "profiles/*/\(name)"]
    }

    // MARK: - Database snapshots

    /// Ceiling on the snapshot pass (charter C10). It copies every database
    /// on the host in one pass, so it scales with the home's size (5 MB/s,
    /// a slow disk), never below 15 minutes; an hour when the size is
    /// unknown (`du -sb` is GNU-only).
    static func snapshotTimeout(homeBytes: Int64?) -> TimeInterval {
        guard let homeBytes else { return 3600 }
        return max(900, TimeInterval(homeBytes) / 5_000_000)
    }

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

    /// Snapshot every database under `home` into `snapshotDir`. The root
    /// `state.db` is the one the backup cannot do without: if it exists and
    /// could not be snapshotted, this throws. Any other database that could
    /// not be snapshotted is reported back (and recorded in the manifest as
    /// skipped), as `hermes backup` reports its own
    /// (`hermes_cli/backup.py:723`).
    private func takeDatabaseSnapshots(
        transport: any ServerTransport,
        home: String,
        snapshotDir: String,
        options: BackupManifest.Options,
        profiles: [String],
        cacheEntries: [String: [String]],
        timeout: TimeInterval
    ) async throws -> HermesDatabaseScripts.SnapshotReport {
        let result: ProcessResult
        do {
            result = try await transport.asyncRunProcess(
                executable: "/bin/bash",
                args: ["-lc", HermesDatabaseScripts.snapshotAll(
                    home: home, snapshotDir: snapshotDir,
                    prunedDirs: Self.prunedDirs(options: options, profiles: profiles, cacheEntries: cacheEntries),
                    prunedNames: Self.hermesAnyDepthExcludedDirs)],
                stdin: nil,
                timeout: timeout
            )
        } catch {
            throw BackupError.snapshotFailed(error.localizedDescription)
        }
        let report = HermesDatabaseScripts.parseSnapshotReport(result.stdoutString)
        let why = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, report.finished else {
            throw BackupError.snapshotFailed(why.isEmpty ? "exit \(result.exitCode)" : why)
        }
        // The root state.db is the one database a backup can't do without:
        // present means snapshotted, or the backup fails.
        if report.rootStateDB, !report.ok.contains(where: { $0.path == "state.db" }) {
            throw BackupError.snapshotFailed(why.isEmpty ? "no method could read state.db" : why)
        }
        // A database whose name can't be carried through the report can be
        // neither snapshotted nor excluded, so it would ride along live.
        // Refuse rather than archive it that way.
        if report.unnameable > 0 {
            throw BackupError.snapshotFailed(
                "\(report.unnameable) database file(s) in the Hermes home have a tab or line break in their name. Rename them and back up again.")
        }
        return report
    }

    /// Best-effort removal of the snapshot directory. A leftover (a run
    /// killed mid-way) is excluded from later backups by
    /// ``hermesExcludes(leaf:options:databases:)`` and swept by the next run's
    /// ``HermesDatabaseScripts/leftoverCleanup(home:)``.
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
