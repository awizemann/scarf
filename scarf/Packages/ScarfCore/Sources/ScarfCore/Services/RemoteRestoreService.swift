import Foundation
import CryptoKit
#if canImport(os)
import os
#endif

/// Reverses a `.scarfbackup` archive into a target server: validates,
/// streams tarballs into place over SSH, and re-anchors path-bearing
/// JSON sidecars so the restored Hermes home references the new layout.
///
/// **Validation gates.** No bytes are written to the target until the
/// manifest's `kind` magic + `schemaVersion` match, and every inner
/// tarball's SHA-256 matches what the manifest claims. A corrupt
/// archive surfaces a single named-path error instead of a half-extracted
/// home.
///
/// **Path re-anchoring.** Project absolute paths in
/// `~/.hermes/scarf/projects.json` reference the source server's home
/// (e.g. `/root/projects/foo`). After extraction the project lives at
/// `<targetProjectsRoot>/foo`, so the restore rewrites `path` for each
/// entry. Same logic for `<project>/.scarf/manifest.json` if it carries
/// self-references.
///
/// **Cron paused on restore.** Every job in `cron/jobs.json` is flipped
/// to `enabled = false` after restore. Restored cron jobs may carry
/// stale credentials (Slack tokens, webhooks) or run on schedules the
/// user no longer wants — auto-running them on a fresh droplet is
/// surprising. The user re-enables what they want from the Cron view.
public final class RemoteRestoreService: @unchecked Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "RemoteRestoreService")
    #endif

    // MARK: - Spawn budgets (charter C10)
    //
    // Every subprocess here has a timeout, and each one is named after what
    // it is waiting for rather than sharing one anonymous number. The sizes
    // come from the archives these spawns actually see: a Hermes-home backup
    // is the user's whole `~/.hermes` — state.db, logs and every project
    // tarball — routinely hundreds of MB and occasionally multi-GB.
    //
    // These are CEILINGS on a wedged child, not budgets a healthy one spends:
    // `unzip` on a 2 GB archive to local disk is a couple of minutes, and the
    // drain now runs concurrently with the wait, so a chatty archive no longer
    // has to reach the timeout at all. They are deliberately generous — a
    // restore killed halfway is worse than one that takes a while — and small
    // enough that a hung `unzip` is a message rather than a frozen app.

    /// Unpacking the outer `.scarfbackup` zip on the local disk.
    public static let unzipTimeout: TimeInterval = 900

    /// The remote `tar -x` finishing after the tarball's last byte is through
    /// the pipe. Shorter than ``unzipTimeout`` because the transfer — the slow
    /// part, and the part that varies with size — has already happened by the
    /// time the wait begins; what is left is the remote's final writes.
    public static let remoteExtractTimeout: TimeInterval = 300

    /// How long the tarball pump may make NO progress before the push is
    /// declared wedged.
    ///
    /// This is a stall ceiling, not a transfer budget: a multi-GB tarball over
    /// a slow link legitimately spends hours in the pump, and any wall-clock
    /// ceiling on the whole transfer would kill exactly the restores that
    /// needed it most. What is never legitimate is a pump that writes NOTHING
    /// for minutes — that is the remote having stopped reading stdin, which is
    /// what a `tar -x` blocked on its own full stderr buffer looks like from
    /// this side (round-4 P43b).
    public static let pumpStallTimeout: TimeInterval = 120

    public let context: ServerContext

    public init(context: ServerContext) {
        self.context = context
    }

    public enum Progress: Sendable, Equatable {
        case validating
        case verifyingHashes
        case planning
        case restoringHermes(bytesPushed: Int64)
        case restoringProject(name: String, bytesPushed: Int64)
        case reanchoringPaths
        case pausingCron
        case finalizing
    }

    public enum RestoreError: Error, LocalizedError {
        case archiveUnreadable(String)
        case unsupportedSchema(Int)
        case wrongKind(String)
        case integrityCheckFailed(path: String, expected: String, actual: String)
        case remoteCommandFailed(String)
        case localIO(String)
        /// A process on the target has `state.db` (or its WAL/SHM) open.
        /// Replacing the file under it is the corruption / split-brain
        /// class Hermes's own `hermes import` refuses
        /// (`hermes_cli/backup.py:536-559`, `:854-866` @ v2026.9.24).
        /// `homeRestored` says whether the rest of the Hermes home had
        /// already been written when the holder was found.
        case hermesRunning(pids: [Int32], homeRestored: Bool)
        /// Scarf could not tell whether anything holds `state.db` open
        /// (no `/proc` and no `lsof` on the host). Fails closed.
        case cannotConfirmHermesStopped(String, homeRestored: Bool)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .archiveUnreadable(let m): return "Couldn't read the backup archive: \(m)"
            case .unsupportedSchema(let v): return "Backup uses schema v\(v), which this version of Scarf doesn't recognize."
            case .wrongKind(let k): return "This file isn't a Scarf server backup (kind: \(k))."
            case .integrityCheckFailed(let p, let exp, let act): return "Backup is corrupt — \(p) hash mismatch (expected \(exp.prefix(12))…, got \(act.prefix(12))…)."
            case .remoteCommandFailed(let m): return "Remote command failed during restore: \(m)"
            case .localIO(let m): return "Local file I/O failed during restore: \(m)"
            case .hermesRunning(let pids, let homeRestored):
                let list = pids.map(String.init).joined(separator: ", ")
                return "Hermes is running on this server: process \(list) has one of its databases (state.db, a profile's state.db, kanban.db, …) open. Restoring over a database that is in use can corrupt it or lose sessions. Stop the Hermes gateway and close any Hermes chats on this server (including Scarf chat windows), then restore again. \(Self.outcome(homeRestored))"
            case .cannotConfirmHermesStopped(let m, let homeRestored):
                return "Couldn't confirm that Hermes is stopped on this server (\(m)). Stop the Hermes gateway and any Hermes chats there, then restore again. \(Self.outcome(homeRestored))"
            case .cancelled: return "Restore cancelled."
            }
        }

        private static func outcome(_ homeRestored: Bool) -> String {
            homeRestored
                ? "The rest of the Hermes home was restored, but its databases were left as they were."
                : "Nothing was changed."
        }
    }

    /// What `inspect()` returns to drive the restore-plan sheet. The
    /// caller picks `targetProjectsRoot`, optionally tweaks the cron
    /// pause toggle, then calls `run()` with the same archive URL.
    public struct InspectionResult: Sendable {
        public var manifest: BackupManifest
        public var workDir: URL          // unzipped temp dir; reused by run()
        /// The target user's `$HOME`. Only used for the default projects
        /// landing path; the Hermes home is ``targetHermesHome``.
        public var targetHomeResolved: String?
        public var targetHermesVersion: String?
        /// The Hermes home the restore writes into: the server's configured
        /// home (`context.paths.home`, `~` expanded against the target's
        /// `$HOME`), which is what the server's Hermes and every Scarf
        /// window read. `nil` only when a `~` path couldn't be expanded.
        public var targetHermesHome: String? = nil
        /// Whether something on the target holds `state.db` open right now.
        /// Shown in the plan sheet; `run()` checks again before writing.
        public var stateDBHolders: DBHolderProbe? = nil
    }

    /// Result of looking for processes that hold the target's `state.db`
    /// (or its `-wal`/`-shm`) open.
    public enum DBHolderProbe: Sendable, Equatable {
        case clear
        case held([Int32])
        case unknown(String)
    }

    public struct RestoreOptions: Sendable {
        /// Where to drop project tarballs. Each project lands at
        /// `<targetProjectsRoot>/<basename>`. Defaults to
        /// `<target $HOME>/projects` when not specified.
        public var targetProjectsRoot: String?
        /// Override the Hermes home to restore into (the directory itself,
        /// e.g. `/var/lib/hermes/.hermes`). Rarely needed: the default is
        /// the server's configured Hermes home.
        public var targetHermesHomeOverride: String?
        /// Pause every cron job after restore. Strongly recommended
        /// (the user re-enables intentionally).
        public var pauseCronJobs: Bool

        public init(
            targetProjectsRoot: String? = nil,
            targetHermesHomeOverride: String? = nil,
            pauseCronJobs: Bool = true
        ) {
            self.targetProjectsRoot = targetProjectsRoot
            self.targetHermesHomeOverride = targetHermesHomeOverride
            self.pauseCronJobs = pauseCronJobs
        }
    }

    public struct RestoreResult: Sendable {
        public var manifest: BackupManifest
        public var hermesHome: String
        public var projectsRestored: [RestoredProject]
        public var cronJobsPaused: Int

        public struct RestoredProject: Sendable {
            public var name: String
            public var sourcePath: String
            public var targetPath: String
        }
    }

    /// Unzip + manifest-validate + hash-verify in a temp dir. Cheap
    /// enough to call from a sheet's appearance handler so the user
    /// sees a populated preview before committing.
    public func inspect(archiveURL: URL) async throws -> InspectionResult {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // The caller owns `workDir` only on the SUCCESS path — it is handed
        // back inside `InspectionResult` for `run()` to reuse. On every
        // throwing path it is ours, and nothing was removing it: a
        // `.scarfbackup` whose unzip timed out or was killed left a
        // `scarf-restore-<uuid>` directory holding however much of a multi-GB
        // archive had already landed, once per attempt, until the OS swept the
        // temp dir (round-4 P43b).
        var handedToCaller = false
        defer {
            if !handedToCaller { try? FileManager.default.removeItem(at: workDir) }
        }

        // Unzip outer archive.
        try await Self.unzipArchive(at: archiveURL, into: workDir)

        // Decode + validate manifest.
        let manifestURL = workDir.appendingPathComponent(BackupArchiveLayout.manifestPath)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw RestoreError.archiveUnreadable("missing manifest.json")
        }
        let manifest: BackupManifest
        do {
            manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        } catch {
            throw RestoreError.archiveUnreadable("manifest.json malformed: \(error.localizedDescription)")
        }
        guard manifest.kind == BackupManifest.kindMagic else {
            throw RestoreError.wrongKind(manifest.kind)
        }
        guard BackupManifest.supportedSchemaVersions.contains(manifest.schemaVersion) else {
            throw RestoreError.unsupportedSchema(manifest.schemaVersion)
        }

        // Hash-verify every inner tarball before any remote bytes are
        // pushed.
        try await Self.verifyHash(file: workDir.appendingPathComponent(manifest.hermes.tarballPath), expected: manifest.hermes.tarballSHA256)
        if let bad = manifest.databases?.entries.map(\.path).first(where: { !Self.isSafeDatabasePath($0) }) {
            throw RestoreError.archiveUnreadable("the manifest lists an unsafe database path: \(bad)")
        }
        if let databases = manifest.databases, !databases.entries.isEmpty {
            try await Self.verifyHash(file: workDir.appendingPathComponent(databases.tarballPath), expected: databases.tarballSHA256)
        }
        for project in manifest.projects {
            try await Self.verifyHash(file: workDir.appendingPathComponent(project.tarballPath), expected: project.tarballSHA256)
        }

        // Probe the target for $HOME + hermes version. Doesn't fail
        // restore if the probe times out — the user can still pick
        // an override.
        let transport = context.makeTransport()
        let homeProbe = try? await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", "echo \"$HOME\""],
            stdin: nil,
            timeout: 30
        )
        let resolvedHome = homeProbe?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionProbe = try? await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", "hermes --version 2>/dev/null || true"],
            stdin: nil,
            timeout: 30
        )
        let resolvedVersion = versionProbe?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = (resolvedHome?.isEmpty == false) ? resolvedHome : nil
        let hermesHome = Self.resolveTargetHermesHome(configured: context.paths.home, userHome: home)
        var holders: DBHolderProbe?
        if let hermesHome {
            holders = await probeDatabaseHolders(
                transport: transport,
                databases: Self.absolute(Self.databasePathsForProbe(manifest), in: hermesHome))
        }

        handedToCaller = true
        return InspectionResult(
            manifest: manifest,
            workDir: workDir,
            targetHomeResolved: home,
            targetHermesVersion: (resolvedVersion?.isEmpty == false) ? resolvedVersion : nil,
            targetHermesHome: hermesHome,
            stateDBHolders: holders
        )
    }

    /// Run the restore. Pushes tarballs, re-anchors paths, optionally
    /// pauses cron. Caller owns the `workDir` URL from `inspect()` and
    /// is responsible for cleanup if `run` throws — on success this
    /// method removes the temp dir.
    public func run(
        inspection: InspectionResult,
        options: RestoreOptions,
        progress: @Sendable @escaping (Progress) -> Void
    ) async throws -> RestoreResult {
        defer { try? FileManager.default.removeItem(at: inspection.workDir) }
        let transport = context.makeTransport()
        let manifest = inspection.manifest

        try Task.checkCancellation()
        progress(.planning)

        // The server's configured Hermes home, not `$HOME/.hermes`: a server
        // whose home lives elsewhere (`/var/lib/hermes/.hermes`) used to be
        // restored into the SSH user's `~/.hermes`, which nothing reads.
        let hermesHome = options.targetHermesHomeOverride
            ?? inspection.targetHermesHome
            ?? manifest.hermes.homePath
        let userHome = inspection.targetHomeResolved
            ?? (manifest.hermes.homePath as NSString).deletingLastPathComponent
        let projectsRoot = options.targetProjectsRoot ?? (userHome + "/projects")

        // The archive's databases as one tarball of `<relpath>` members,
        // whatever the schema. v2 ships it that way; for v1 they are lifted
        // out of the home tarball HERE, on the Mac, before anything is
        // written to the target. Either way the home extraction below never
        // touches a database, and databases are only ever replaced by the
        // guarded publish in Stage 1b. A database the archive doesn't carry
        // (and its WAL) is left exactly as it is on the target.
        let archiveLeaf = manifest.schemaVersion >= 2
            ? (manifest.hermes.homePath as NSString).lastPathComponent
            : ".hermes"   // v1 always archived `.hermes/`
        let hermesTar = inspection.workDir.appendingPathComponent(manifest.hermes.tarballPath)
        let dbBundle: (tarball: URL, paths: [String])?
        if let databases = manifest.databases {
            dbBundle = databases.entries.isEmpty ? nil : (
                inspection.workDir.appendingPathComponent(databases.tarballPath),
                databases.entries.map(\.path))
        } else {
            dbBundle = try await Self.liftLegacyDatabases(
                from: hermesTar, leaf: archiveLeaf, workDir: inspection.workDir)
        }
        let targetDatabases = Self.absolute(dbBundle?.paths ?? ["state.db"], in: hermesHome)

        // Refuse BEFORE writing anything when something holds a database
        // this restore replaces (always including state.db) open. Checked
        // again right before the databases themselves are replaced.
        try await requireDatabasesUnheld(transport: transport, databases: targetDatabases)

        // Clear Scarf directories a killed run left in the target home.
        _ = try? await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", HermesDatabaseScripts.leftoverCleanup(home: hermesHome)],
            stdin: nil,
            timeout: 60
        )

        // Make sure the projects root exists so `tar -xzf` doesn't
        // fail on a missing -C target.
        let mkdirCmd = "mkdir -p \(Self.shellQuote(projectsRoot))"
        // `try?` here used to turn "the host is unreachable" into "the
        // directory is fine" — the restore then pushed tarballs into a
        // path nothing had created and reported success either way.
        let mkdirResult: ProcessResult
        do {
            mkdirResult = try await transport.asyncRunProcess(
                executable: "/bin/bash",
                args: ["-lc", mkdirCmd],
                stdin: nil,
                timeout: 30
            )
        } catch {
            throw RestoreError.remoteCommandFailed("mkdir \(projectsRoot) failed: \(error.localizedDescription)")
        }
        if mkdirResult.exitCode != 0 {
            throw RestoreError.remoteCommandFailed("mkdir \(projectsRoot) failed: \(mkdirResult.stderrString)")
        }

        // Stage 1: hermes home, minus every database and SQLite sidecar. The
        // tarball's single top-level directory is stripped so its contents
        // land directly in `hermesHome`, whatever that directory is called
        // on the target.
        try Task.checkCancellation()
        try await pushTarball(
            transport: transport,
            tarball: hermesTar,
            extractCommand: Self.hermesExtractCommand(
                hermesHome: hermesHome, archiveLeaf: archiveLeaf, databases: dbBundle?.paths ?? [])
        ) { written in
            progress(.restoringHermes(bytesPushed: written))
        }

        // Pause the restored cron jobs NOW, before anything else can fail:
        // they may carry the source host's credentials and schedules, and a
        // restore that stops at the database step (because Hermes is
        // running, by definition) must not leave them armed.
        var paused = 0
        if options.pauseCronJobs {
            try Task.checkCancellation()
            progress(.pausingCron)
            paused = try await pauseAllCronJobs(transport: transport, hermesHome: hermesHome)
        }

        // Stage 1b: the databases. Extracted into a staging directory in the
        // home (same filesystem, so each publish is a rename), then
        // published after a last holder check, in the same shell as the
        // replacement.
        if let dbBundle {
            try Task.checkCancellation()
            let staging = hermesHome + "/" + HermesDatabaseScripts.stagingDirPrefix + UUID().uuidString
            do {
                try await pushTarball(
                    transport: transport,
                    tarball: dbBundle.tarball,
                    // `-m`: the staged files get "now" as their mtime, not the
                    // backup's, so a concurrent run's leftover sweep can't
                    // mistake this staging directory for an abandoned one.
                    extractCommand: "mkdir -p \(Self.shellQuote(staging)) && tar -xmzf - -C \(Self.shellQuote(staging))"
                ) { _ in }
                try await publishDatabases(
                    transport: transport,
                    staging: staging,
                    paths: dbBundle.paths,
                    hermesHome: hermesHome
                )
            } catch {
                await removeStagingDir(transport: transport, staging: staging)
                throw error
            }
            await removeStagingDir(transport: transport, staging: staging)
        }

        // Stage 2: per-project tarballs.
        var restoredProjects: [RestoreResult.RestoredProject] = []
        for project in manifest.projects {
            try Task.checkCancellation()
            let tar = inspection.workDir.appendingPathComponent(project.tarballPath)
            try await pushTarball(
                transport: transport,
                tarball: tar,
                extractCommand: "tar -xzf - -C \(Self.shellQuote(projectsRoot))"
            ) { written in
                progress(.restoringProject(name: project.name, bytesPushed: written))
            }
            let basename = (project.path as NSString).lastPathComponent
            restoredProjects.append(RestoreResult.RestoredProject(
                name: project.name,
                sourcePath: project.path,
                targetPath: projectsRoot + "/" + basename
            ))
        }

        // Stage 3: re-anchor `~/.hermes/scarf/projects.json` so the
        // restored Hermes references the new project paths instead
        // of the source droplet's paths.
        try Task.checkCancellation()
        progress(.reanchoringPaths)
        try await reanchorProjectsRegistry(
            transport: transport,
            hermesHome: hermesHome,
            mapping: Dictionary(
                uniqueKeysWithValues: restoredProjects.map { ($0.sourcePath, $0.targetPath) }
            )
        )

        progress(.finalizing)
        return RestoreResult(
            manifest: manifest,
            hermesHome: hermesHome,
            projectsRestored: restoredProjects,
            cronJobsPaused: paused
        )
    }

    // MARK: - Push (tarball -> remote stdin)

    /// Stream a local `.tar.gz` into `extractCommand` (a `tar -xzf -`
    /// pipeline) on the destination. We use `transport.makeProcess` so the
    /// command is shell-wrapped the same way the rest of the app talks to
    /// remotes (`bash -lc` for SSH, direct invocation for local).
    private func pushTarball(
        transport: any ServerTransport,
        tarball: URL,
        extractCommand cmd: String,
        extractTimeout: TimeInterval = RemoteRestoreService.remoteExtractTimeout,
        stallTimeout: TimeInterval = RemoteRestoreService.pumpStallTimeout,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws {
        #if os(iOS)
        throw RestoreError.remoteCommandFailed("Remote restore is not supported on iOS in this build.")
        #else
        let proc = transport.makeProcess(executable: "/bin/bash", args: ["-lc", cmd])
        try await Self.streamTarball(
            into: proc,
            tarball: tarball,
            extractTimeout: extractTimeout,
            stallTimeout: stallTimeout,
            onProgress: onProgress
        )
        #endif
    }

    #if !os(iOS)
    /// Pump `tarball` into `proc`'s stdin, then wait for it — the whole piped
    /// half of ``pushTarball(transport:tarball:extractInto:...)``, split out so
    /// the tests can drive it with a child of their own choosing instead of a
    /// real remote `tar`.
    ///
    /// **Both drains are installed BEFORE the pump, and the pump has a stall
    /// ceiling.** The first version installed neither: it pumped the whole
    /// tarball and only then called `waitDraining`, so nothing was reading
    /// stderr while the tarball was in flight. A remote `tar -x` that reports a
    /// problem per member fills its 64 KB stderr buffer, blocks in `write()`,
    /// stops reading stdin, and the parent blocks forever in `writer.write()` —
    /// BEFORE the bounded wait that was supposed to rescue it, so
    /// ``remoteExtractTimeout`` was never reached and `Task.checkCancellation`
    /// only ran between chunks that had stopped coming. Reproduced with a child
    /// that writes 200 KB to stderr and then `cat > /dev/null`s its stdin
    /// (round-4 P43b).
    ///
    /// The drained data is handed to the post-pump verdict, so a `tar` that
    /// explained itself on stderr before the pump finished is still quoted back
    /// to the user.
    static func streamTarball(
        into proc: Process,
        tarball: URL,
        extractTimeout: TimeInterval = RemoteRestoreService.remoteExtractTimeout,
        stallTimeout: TimeInterval = RemoteRestoreService.pumpStallTimeout,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws {
        // standardInput: read end of an OS pipe whose write end we
        // pump from the local tarball file. Going through a pipe (vs
        // setting standardInput to a FileHandle directly) gives us
        // cooperative chunk-by-chunk control + cancellation.
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        /// Close every handle of every pipe. Only correct BEFORE the drain is
        /// started — after that the read ends belong to the drain.
        func closeEverything() {
            for pipe in [inPipe, outPipe, errPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }

        do {
            try proc.run()
        } catch {
            // The launch-failure path owns all six handles: nothing is
            // draining anything and there is no child to reap.
            closeEverything()
            throw RestoreError.remoteCommandFailed("Couldn't start remote tar: \(error.localizedDescription)")
        }

        // BEFORE the pump. See this method's note.
        let drain = Process.startDraining(pipes: [errPipe, outPipe])
        /// The caller's half of the pipes: the write ends, which the drain
        /// never touches. Every exit from here on goes through this.
        func closeWriteEnds() {
            try? errPipe.fileHandleForWriting.close()
            try? outPipe.fileHandleForWriting.close()
        }
        /// Bounded reap + drain + close, for the arms that give up mid-pump.
        /// `terminate()` alone leaves a child that ignores SIGTERM running and
        /// leaves both read ends draining into nothing.
        ///
        /// **Returns what the child had already said**, because that is
        /// usually the only explanation there is. Every give-up arm here fires
        /// precisely when the remote `tar` has stopped cooperating — and a
        /// `tar` stops cooperating by printing WHY and exiting. Throwing away
        /// the drain (`_ = proc.waitDraining(…)`, which is what these arms did)
        /// left the user with "Broken pipe" for a run whose stderr said
        /// `tar: /nope: Cannot open` (round-4 P43c).
        func abandon() async -> String {
            let (_, drained) = await proc.waitDrainingAsync(
                timeout: Self.abandonReapTimeout, drain: drain,
                drainGrace: Self.drainCollectGrace)
            closeWriteEnds()
            return Self.outputTail(drained)
        }

        let writer = inPipe.fileHandleForWriting
        // **Non-blocking, because a blocked write here cannot be rescued from
        // outside.** The obvious ceiling — a timer that kills the child when
        // the pump stops making progress — does not work: a shell child has
        // grandchildren (`tar` behind a `bash -lc`, the pipeline in the test's
        // reproduction) that INHERITED this pipe's read end, so killing the
        // one pid we may signal leaves the write blocked. Signalling the
        // process GROUP is not an option either: Foundation's children share
        // Scarf's group, so `kill(-pid, …)` would take Scarf with it. Measured:
        // an earlier draft of this fix DID carry that timer, and with the
        // drains moved back after the pump the reproduction still wedged past
        // three minutes — the kill it can deliver does not free the write.
        //
        // With `O_NONBLOCK` the parent is never inside an uninterruptible
        // write at all: a full pipe returns `EAGAIN`, which is where the stall
        // ceiling and `Task.checkCancellation()` both get their turn. It also
        // makes `EPIPE` a return value rather than a SIGPIPE that would kill
        // Scarf — `F_SETNOSIGPIPE` covers the same ground per-fd and is set
        // alongside it (round-4 P43b).
        let writeFD = writer.fileDescriptor
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: tarball)
        } catch {
            try? writer.close()
            _ = await abandon()
            throw RestoreError.localIO("Couldn't open tarball: \(error.localizedDescription)")
        }
        defer { try? reader.close() }

        var written: Int64 = 0
        var lastProgress = Date()
        var stalled = false
        var lastYield: Int64 = 0
        let chunkSize = 64 * 1024
        do {
            pump: while true {
                try Task.checkCancellation()
                // SUSPEND. The happy path — a remote reading as fast as we
                // write — never hits the `EAGAIN` arm below, so the whole
                // multi-gigabyte pump ran without a single suspension point:
                // `Task.checkCancellation()` is synchronous, and `write(2)`
                // on a drained pipe returns immediately. One cooperative
                // thread was held for the length of the push.
                // `Task.yield()` every ``pumpYieldBytes`` gives the pool its
                // thread back without measurably slowing the copy.
                if Self.shouldYield(written: written, lastYield: lastYield) {
                    lastYield = written
                    await Task.yield()
                }
                let chunk = reader.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                var offset = 0
                while offset < chunk.count {
                    try Task.checkCancellation()
                    let sent: Int = chunk.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return 0 }
                        return write(writeFD, base + offset, chunk.count - offset)
                    }
                    if sent > 0 {
                        offset += sent
                        written += Int64(sent)
                        lastProgress = Date()
                        onProgress(written)
                        continue
                    }
                    if sent < 0, errno == EINTR { continue }
                    // `write(2)` returning 0 for a NON-zero count accepted
                    // nothing and set no errno, so the throw below would
                    // report whatever `errno` happened to hold from an
                    // earlier call. It is the same condition `EAGAIN` names —
                    // no progress — so it gets the same treatment, under the
                    // same stall budget, which is what stops it spinning.
                    if sent == 0 || (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                        // The remote has stopped reading. Give it room, but
                        // not forever: see ``pumpStallTimeout``.
                        let stalledFor = Date().timeIntervalSince(lastProgress)
                        if stalledFor >= stallTimeout {
                            stalled = true
                            break pump
                        }
                        // **`poll(2)`, not a fixed sleep.** A flat 20 ms nap
                        // per `EAGAIN` turns the pipe into a metronome: the
                        // 64 KB buffer drains in microseconds and then the
                        // parent does nothing for the rest of the tick, so the
                        // push tops out near 3 MB/s no matter how fast the
                        // link is. Measured on a 64 MB payload into
                        // `cat > /dev/null`: 4138 MB/s blocking, 2.8 MB/s with
                        // the sleep — an hour and a half added to a 16 GB
                        // Hermes home. `poll` wakes on the byte, so the
                        // non-blocking pump costs what the blocking one did
                        // while keeping the property it exists for: the wait
                        // is CAPPED, at the shorter of what is left of the
                        // stall budget and ``pumpPollSlice``, so
                        // `Task.checkCancellation()` still gets a turn several
                        // times a second (round-4 P43c).
                        Self.waitWritable(
                            writeFD, upTo: min(stallTimeout - stalledFor, Self.pumpPollSlice))
                        continue
                    }
                    throw RestoreError.localIO(
                        "writing to the remote failed: \(String(cString: strerror(errno)))")
                }
            }
        } catch is CancellationError {
            try? writer.close()
            _ = await abandon()
            // `.cancelled` carries no message: the user asked for this one, so
            // there is nothing for the child's stderr to explain.
            throw RestoreError.cancelled
        } catch {
            try? writer.close()
            // The EPIPE arm lands HERE — a remote `tar` that refuses the
            // archive closes stdin, and the next write is "Broken pipe". Its
            // reason is on the stderr the drain has been collecting since the
            // spawn.
            let tail = await abandon()
            throw RestoreError.localIO(Self.appendingTail(
                "Couldn't pump tarball into remote: \(error.localizedDescription)", tail))
        }
        if stalled {
            try? writer.close()
            let tail = await abandon()
            throw RestoreError.remoteCommandFailed(Self.appendingTail(
                "the remote stopped reading the tarball for \(Int(stallTimeout))s, so the transfer was stopped",
                tail))
        }
        try? writer.close() // signals EOF to the remote tar

        // C10: bounded. The drain has been running since the spawn, so what is
        // collected here is everything the child said — including whatever it
        // said DURING the pump.
        let (exited, drained) = await proc.waitDrainingAsync(
            timeout: extractTimeout, drain: drain, drainGrace: Self.drainCollectGrace)
        // The write ends stay ours; the drain owns the read ends.
        closeWriteEnds()
        guard exited else {
            throw RestoreError.remoteCommandFailed(Self.appendingTail(
                "remote tar -x did not finish within \(Int(extractTimeout))s and was stopped",
                Self.outputTail(drained)))
        }
        if proc.terminationStatus != 0 {
            let tail = String(data: drained.first ?? Data(), encoding: .utf8) ?? ""
            throw RestoreError.remoteCommandFailed("tar -x exited \(proc.terminationStatus): \(tail)")
        }
    }

    /// How long to wait for the drained pipes to reach EOF once the child has
    /// gone, at the push.
    ///
    /// Longer than ``Process/drainGrace`` (1 s) on purpose. EOF lands at the
    /// child's exit, so on every ordinary path this wait returns at once and
    /// the size costs nothing; what the extra seconds buy is that the whole
    /// POINT of the drain — the child's own explanation of why it gave up —
    /// does not evaporate on a machine too busy to schedule a reader inside a
    /// second. It was a one-second grace that first lost `tar`'s message under
    /// load, before `ProcessPipeDrain` moved its readers onto threads of their
    /// own; the belt stays alongside the braces (round-4 P43c).
    static let drainCollectGrace: TimeInterval = 5

    /// The longest a single `poll(2)` inside the pump may park before the loop
    /// takes its `Task.checkCancellation()` again. Short enough that a user
    /// who cancels a wedged push sees it stop; long enough that a healthy push
    /// never notices the cap at all, because `poll` returns on the byte.
    ///
    /// **This IS a block on a cooperative thread, deliberately.** It is not the
    /// hazard ``Process/waitDrainingAsync(timeout:drain:drainGrace:)`` exists
    /// to remove, because that one is a five-minute reap and this one is a
    /// fifth of a second with a hard cap — bounded tightly enough that holding
    /// the thread is cheaper than the hop that would avoid it, and short
    /// enough that the pool cannot be starved by it.
    static let pumpPollSlice: TimeInterval = 0.2

    /// How many bytes the tarball pump may push between cooperative
    /// suspensions. 8 MB is ~128 of the 64 KB chunks — a few milliseconds on
    /// a fast link, and far below any rate the yield itself could bound.
    static let pumpYieldBytes: Int64 = 8 * 1024 * 1024

    /// Whether the pump owes a `Task.yield()`. Factored out so the rule is
    /// testable without a remote host on the other end of the pipe.
    static func shouldYield(written: Int64, lastYield: Int64) -> Bool {
        written - lastYield >= pumpYieldBytes
    }

    /// Block until `fd` accepts a write again, for at most `budget` seconds.
    ///
    /// The one bounded block in the pump, and it is bounded by construction:
    /// `poll` takes its timeout in milliseconds and the caller never passes
    /// more than ``pumpPollSlice``.
    static func waitWritable(_ fd: Int32, upTo budget: TimeInterval) {
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        // At least one tick: a zero timeout is a spin, and a negative one is
        // `poll`'s spelling of "forever".
        let milliseconds = Int32(max(1, min(10_000, (budget * 1000).rounded(.up))))
        _ = poll(&descriptor, 1, milliseconds)
    }

    /// The last `lines` non-blank lines of a drained child's output, for an
    /// error message. Empty when the child said nothing.
    ///
    /// Leading whitespace is trimmed for the same reason `HermesCLIVerdict`
    /// trims it: `tar` indents continuation lines, and an error tail that
    /// carries the indentation reads as a wall.
    static func outputTail(_ drained: [Data], lines: Int = 4) -> String {
        let significant = drained
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !significant.isEmpty else { return "" }
        return significant.suffix(lines).joined(separator: " / ")
    }

    /// Attach `tail` to `message`, or hand back `message` unchanged when the
    /// child said nothing worth quoting.
    static func appendingTail(_ message: String, _ tail: String) -> String {
        tail.isEmpty ? message : "\(message) — the remote said: \(tail)"
    }

    /// How long a give-up arm waits for the child it just abandoned. Short: the
    /// caller is already on its way out with an error, and the wait escalates
    /// SIGTERM → SIGKILL rather than hoping.
    static let abandonReapTimeout: TimeInterval = 5
    #endif

    // MARK: - Path re-anchor

    /// Rewrite each entry's `path` in `~/.hermes/scarf/projects.json`
    /// from source-host paths to target-host paths. We do this on the
    /// remote rather than mutating the tarball locally — the Hermes
    /// home tarball can be GBs and re-packing would double the
    /// transfer cost.
    ///
    /// **Was a truncating Python rewrite** (`open(path,'w')` after a
    /// `json.load`), which is the one shape the rest of the projects code
    /// exists to prevent: no absent-vs-unreadable probe, no `.bak`, no
    /// refusal, and a destination zeroed before the new bytes land. It ran
    /// through `try?`, so a transport that never executed it at all
    /// reported a clean restore. Now the whole thing goes through
    /// `mutateRemoteJSON`, which reads via the transport and publishes via
    /// `transport.writeFile` — atomic on every transport — and throws on
    /// every failure it used to swallow.
    ///
    /// Unknown keys still survive: the mutation runs over the parsed
    /// `JSONSerialization` object graph, not a Codable projection, so
    /// fields this Scarf doesn't model are re-emitted untouched.
    func reanchorProjectsRegistry(
        transport: any ServerTransport,
        hermesHome: String,
        mapping: [String: String]
    ) async throws {
        guard !mapping.isEmpty else { return }
        let registryPath = hermesHome + "/scarf/projects.json"
        // A read-modify-write of projects.json like any other, so it takes
        // the same lock (t-07e909e0 / DI-L1) — the restore's re-anchor and
        // a sidebar save landing at once would otherwise have the loser's
        // rows published away. The lock is keyed on THIS path rather than
        // `context.paths.projectsRegistry` because a restore can target a
        // home the options overrode. `mutateRemoteJSON` is synchronous, so
        // the hold does not span the `async` boundary of this function.
        let apply = {
            _ = try Self.mutateRemoteJSON(
                transport: transport,
                path: registryPath,
                label: "Path re-anchor",
                sortKeys: true,
                mutate: Self.reanchorMutation(mapping: mapping)
            )
        }
        if let lock = RegistryWriteLock(context: context, path: registryPath) {
            try lock.withLock(path: registryPath, apply)
        } else {
            try apply()
        }
    }

    /// The re-anchor itself, split out so the locked and unlocked paths
    /// cannot drift.
    private static func reanchorMutation(
        mapping: [String: String]
    ) -> (inout [String: Any]) -> Int? {
        { root in
            guard var entries = root["projects"] as? [[String: Any]] else { return nil }
            var changed = 0
            for index in entries.indices {
                guard let old = entries[index]["path"] as? String, let new = mapping[old] else { continue }
                entries[index]["path"] = new
                changed += 1
            }
            guard changed > 0 else { return nil }
            root["projects"] = entries
            return changed
        }
    }

    /// Pause every cron job in the restored home: the root home's and every
    /// named profile's. Returns the total paused (0 when no home has a
    /// `jobs.json`, or nothing in them could fire).
    ///
    /// Hermes cron is per-profile: a job authored in profile `coder` lives
    /// in `profiles/coder/cron/jobs.json` and runs under that profile's
    /// credentials (`cron/jobs.py:62-74` @ v2026.9.24), and the gateway
    /// ticks every profile's store (`gateway/run.py:5672-5685`). Pausing only
    /// the root file left every profile's restored jobs armed.
    ///
    /// Same rewrite as `reanchorProjectsRegistry`, and the same reason: a
    /// truncating write that failed used to be indistinguishable from one
    /// that worked, so a restore could report "12 cron jobs paused" — or
    /// "0", which reads as "nothing to pause" — while every restored job
    /// stayed armed with the source host's credentials. A profiles
    /// directory that is there but can't be listed throws for the same
    /// reason.
    func pauseAllCronJobs(transport: any ServerTransport, hermesHome: String) async throws -> Int {
        // Every home is tried, root first, whatever fails on the way: one
        // unreadable file must not leave the homes after it armed. Then
        // one error names every file whose jobs may still be armed.
        var total = 0
        var failures: [String] = []
        func record(_ error: Error) {
            if case RestoreError.remoteCommandFailed(let message) = error {
                failures.append(message)
            } else {
                failures.append(error.localizedDescription)
            }
        }
        var homes = [hermesHome]
        do {
            homes += try Self.profileHomes(transport: transport, hermesHome: hermesHome)
        } catch {
            record(error)
        }
        for home in homes {
            do {
                total += try Self.pauseCronJobs(transport: transport, jobsPath: home + "/cron/jobs.json")
            } catch {
                record(error)
            }
        }
        guard failures.isEmpty else {
            throw RestoreError.remoteCommandFailed(
                "Paused \(total) cron job(s), but these may still be armed: " + failures.joined(separator: " ")
            )
        }
        return total
    }

    /// Every entry under `<home>/profiles`, as a path. Absent is a home with
    /// no named profiles; present but unlistable (twice) throws. Entries that
    /// aren't profile homes simply have no `cron/jobs.json`.
    static func profileHomes(transport: any ServerTransport, hermesHome: String) throws -> [String] {
        let dir = hermesHome + "/profiles"
        var names = try? transport.listDirectory(dir)
        if names == nil {
            guard transport.stat(dir) != nil else { return [] }  // no profiles
            names = try? transport.listDirectory(dir)
            if names == nil {
                throw RestoreError.remoteCommandFailed(
                    "Cron pause failed: \(dir) exists but could not be listed, so its profiles' cron jobs may still be armed."
                )
            }
        }
        return (names ?? []).sorted().map { dir + "/" + $0 }
    }

    /// Pause, in one `jobs.json`, every job Hermes's scheduler could fire,
    /// the way `hermes cron pause` does (`cron/jobs.py:2067-2077`):
    /// `enabled: false` plus the `paused` state and `paused_at` marker, so
    /// Hermes and Scarf both show it as paused. A job without an `enabled`
    /// key is armed (Hermes defaults it to true, `cron/jobs.py:521-524`), so
    /// it is paused and counted too. A completed or errored job keeps its
    /// state; it only loses `enabled`.
    static func pauseCronJobs(transport: any ServerTransport, jobsPath: String) throws -> Int {
        let pausedAt = ISO8601DateFormatter().string(from: Date())
        return try mutateRemoteJSON(
            transport: transport,
            path: jobsPath,
            label: "Cron pause",
            sortKeys: false,
            // A bare list is a shape Hermes loads and rewrites wrapped
            // (`cron/jobs.py:1374-1376`); write it back the same way.
            wrapTopLevelArrayAs: "jobs"
        ) { root in
            var count = 0
            func pause(_ job: inout [String: Any]) {
                guard isRunnable(job) else { return }
                job["enabled"] = false
                let state = (job["state"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                if state != "completed" && state != "error" {
                    job["state"] = "paused"
                    job["paused_at"] = pausedAt
                    job["paused_reason"] = "Paused by Scarf after a server restore"
                }
                count += 1
            }
            if var jobs = root["jobs"] as? [[String: Any]] {
                for index in jobs.indices { pause(&jobs[index]) }
                guard count > 0 else { return nil }
                root["jobs"] = jobs
            } else if var jobs = root["jobs"] as? [String: Any] {
                // The id-keyed map Hermes also accepts (`cron/jobs.py:1358-1369`).
                for key in jobs.keys {
                    guard var job = jobs[key] as? [String: Any] else { continue }
                    pause(&job)
                    jobs[key] = job
                }
                guard count > 0 else { return nil }
                root["jobs"] = jobs
            } else {
                return nil
            }
            return count
        } ?? 0
    }

    /// Hermes's `is_job_runnable` (`cron/jobs.py:521-524` @ v2026.9.24):
    /// `enabled` (true when absent, Python truthiness otherwise) and no
    /// pause marker (`state == "paused"` or a truthy `paused_at`).
    static func isRunnable(_ job: [String: Any]) -> Bool {
        func truthy(_ value: Any?) -> Bool {
            switch value {
            case nil, is NSNull: return false
            case let b as Bool: return b
            case let n as NSNumber: return n.doubleValue != 0
            case let s as String: return !s.isEmpty
            case let a as [Any]: return !a.isEmpty
            case let d as [String: Any]: return !d.isEmpty
            default: return true
            }
        }
        let enabled = job.keys.contains("enabled") ? truthy(job["enabled"]) : true
        let state = (job["state"] as? String)?.trimmingCharacters(in: .whitespaces)
        return enabled && state != "paused" && !truthy(job["paused_at"])
    }

    /// Read a JSON file on the target, hand its object graph to `mutate`,
    /// and publish the result atomically. Returns whatever `mutate`
    /// reported (a count), `nil` when the file is absent or the mutation
    /// was a no-op — and THROWS on everything in between.
    ///
    /// The absent-vs-unreadable discrimination is the registry's, in
    /// miniature: a read failure only counts as damage when `stat`
    /// confirms the file and a second read also fails. Absent is a
    /// legitimate outcome here (a home restored without cron jobs);
    /// unreadable is not something to write over.
    static func mutateRemoteJSON(
        transport: any ServerTransport,
        path: String,
        label: String,
        sortKeys: Bool,
        wrapTopLevelArrayAs arrayKey: String? = nil,
        mutate: (inout [String: Any]) -> Int?
    ) throws -> Int? {
        var read = try? transport.readFile(path)
        if read == nil {
            guard transport.stat(path) != nil else { return nil }  // genuinely absent
            read = try? transport.readFile(path)
            if read == nil {
                throw RestoreError.remoteCommandFailed(
                    "\(label) failed: \(path) exists but could not be read."
                )
            }
        }
        guard let data = read, !data.isEmpty else {
            throw RestoreError.remoteCommandFailed("\(label) failed: \(path) is empty.")
        }
        let parsed = try? JSONSerialization.jsonObject(with: data)
        var root: [String: Any]
        if let object = parsed as? [String: Any] {
            root = object
        } else if let arrayKey, let array = parsed as? [Any] {
            // A file that is a bare list, when its owner accepts that shape
            // and writes it back wrapped (Hermes's `jobs.json`).
            root = [arrayKey: array]
        } else {
            throw RestoreError.remoteCommandFailed("\(label) failed: \(path) is not a JSON object.")
        }
        guard let changed = mutate(&root) else { return nil }

        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        if sortKeys { options.insert(.sortedKeys) }
        guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: options) else {
            throw RestoreError.remoteCommandFailed("\(label) failed: could not re-encode \(path).")
        }
        // One-deep backup of what we are replacing, best effort — the
        // same courtesy `saveRegistry` extends, and the only copy of the
        // pre-restore file once the write lands.
        if encoded != data {
            do {
                // UNGUARDED-WRITE(G): mutateRemoteJSON's own .bak, inside its stat+retry guard.
                try transport.unguardedWriteFile(path + ".bak", data: data)
            } catch {
                #if canImport(os)
                Self.logger.warning("Could not back up \(path, privacy: .public) before restore rewrite: \(error.localizedDescription, privacy: .public)")
                #endif
            }
        }
        do {
            // UNGUARDED-WRITE(G): mutateRemoteJSON's own guarded publish (stat+retry probe above).
            try transport.unguardedWriteFile(path, data: encoded)
        } catch {
            throw RestoreError.remoteCommandFailed("\(label) failed writing \(path): \(error.localizedDescription)")
        }
        return changed
    }

    // MARK: - Target Hermes home + live-database guard

    /// Prefix of the directory database snapshots are staged in, inside the
    /// target Hermes home, before they are renamed into place.
    public static let stagingDirPrefix = HermesDatabaseScripts.stagingDirPrefix

    /// Ceiling on a holder probe or a guarded publish (C10). The `/proc`
    /// scan and `lsof` both finish in seconds on a normal host.
    static let holderProbeTimeout: TimeInterval = 120

    /// The Hermes home a restore targets: the server's configured home, with
    /// a leading `~` expanded against the target's `$HOME`. `nil` when the
    /// configured home needs that expansion and `$HOME` is unknown.
    static func resolveTargetHermesHome(configured: String, userHome: String?) -> String? {
        if configured == "~" || configured.hasPrefix("~/") {
            guard let userHome, !userHome.isEmpty else { return nil }
            return RemoteBackupService.expandTilde(configured, home: userHome)
        }
        return configured
    }

    /// Extract the Hermes-home tarball INTO `hermesHome`, stripping the
    /// archive's single top-level directory (`archiveLeaf`) so the target
    /// directory's name doesn't have to match the source's.
    ///
    /// No database is extracted here: they are published separately,
    /// behind a holder check (``publishDatabases(transport:staging:paths:hermesHome:)``).
    /// Nor is any SQLite `-wal`/`-shm`/`-journal`, even from a hand-built
    /// or older archive that carries them: they describe some other image
    /// of their database, and SQLite would replay them over the restored
    /// one. Hermes's own import skips them for the same reason
    /// (`hermes_cli/backup.py:946-951` @ v2026.9.24). The patterns are
    /// unanchored, so they reach every subdirectory.
    static func hermesExtractCommand(hermesHome: String, archiveLeaf: String, databases: [String]) -> String {
        let home = shellQuote(hermesHome)
        // The databases by exact path (a `*.db` pattern would also drop a
        // DIRECTORY named `x.db`); sidecars and retired-WAL captures by
        // pattern.
        let patterns = databases.map { HermesDatabaseScripts.globEscape(archiveLeaf + "/" + $0) }
            + ["*.db-wal", "*.db-shm", "*.db-journal", HermesDatabaseScripts.retiredWALPattern]
        let excludes = patterns
            .map { "--exclude=\(shellQuote($0))" }
            .joined(separator: " ")
        return "{ [ -d \(home) ] || { mkdir -p \(home) && chmod 700 \(home); }; } && tar -xzf - \(excludes) --strip-components=1 -C \(home)"
    }

    /// Home-relative database paths to look for holders of at inspect time:
    /// the archive's own list, or state.db for a v1 archive (whose full list
    /// is only read when the restore runs).
    static func databasePathsForProbe(_ manifest: BackupManifest) -> [String] {
        let listed = manifest.databases?.entries.map(\.path) ?? []
        return listed.contains("state.db") ? listed : ["state.db"] + listed
    }

    static func absolute(_ relative: [String], in home: String) -> [String] {
        relative.map { home + "/" + $0 }
    }

    /// The PID Scarf itself runs as when the target is this Mac. Scarf's
    /// own read-only connection to the local state.db is not a Hermes
    /// writer and must not block the restore.
    private func ownPIDIfLocal(_ transport: any ServerTransport) -> Int32? {
        transport.isRemote ? nil : ProcessInfo.processInfo.processIdentifier
    }

    static func parseHolderOutput(_ stdout: String) -> DBHolderProbe? {
        guard let line = stdout.split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix("SCARF_HOLDERS:") }) else { return nil }
        let value = line.dropFirst("SCARF_HOLDERS:".count).trimmingCharacters(in: .whitespaces)
        if value == "UNKNOWN" {
            return .unknown("no /proc and no lsof on the server")
        }
        let pids = value.split(separator: " ").compactMap { Int32($0) }
        return pids.isEmpty ? .clear : .held(pids)
    }

    /// Look for processes holding any of `databases` open. Never throws: a
    /// probe that could not run is `.unknown`.
    func probeDatabaseHolders(transport: any ServerTransport, databases: [String]) async -> DBHolderProbe {
        let script = HermesDatabaseScripts.holderScan(databases: databases, ownPID: ownPIDIfLocal(transport))
            + "\necho \"SCARF_HOLDERS:$holders\""
        do {
            let result = try await transport.asyncRunProcess(
                executable: "/bin/bash",
                args: ["-lc", script],
                stdin: nil,
                timeout: Self.holderProbeTimeout
            )
            if let probe = Self.parseHolderOutput(result.stdoutString) { return probe }
            return .unknown("the check printed no result (exit \(result.exitCode))")
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Throw unless nothing holds any of `databases` open.
    private func requireDatabasesUnheld(transport: any ServerTransport, databases: [String]) async throws {
        switch await probeDatabaseHolders(transport: transport, databases: databases) {
        case .clear: return
        case .held(let pids): throw RestoreError.hermesRunning(pids: pids, homeRestored: false)
        case .unknown(let why): throw RestoreError.cannotConfirmHermesStopped(why, homeRestored: false)
        }
    }

    /// Publish every staged snapshot over its database, in ONE host
    /// command: re-check that nothing holds any of them, confirm every
    /// staged file is really there, then for each: make it owner-only
    /// (Hermes treats state.db as a secret, `hermes_cli/backup.py:134`),
    /// remove the old `-wal`/`-shm`/`-journal` (they describe the database
    /// being replaced; SQLite would replay them over the new one), and
    /// rename it into place. The check and the replacements share a shell,
    /// so nothing can open a database in between unseen. Mirrors Hermes's
    /// own unlink+move restore (`hermes_cli/backup.py:536-559` @ v2026.9.24).
    private func publishDatabases(
        transport: any ServerTransport,
        staging: String,
        paths: [String],
        hermesHome: String
    ) async throws {
        var lines = [
            // Defines `scarf_resolve` too: a symlinked database is replaced
            // at its real path, as Hermes's page-copy restore writes through
            // the link, rather than by swapping the link for a file.
            HermesDatabaseScripts.holderScan(
                databases: Self.absolute(paths, in: hermesHome), ownPID: ownPIDIfLocal(transport)),
            "if [ -n \"$holders\" ]; then echo \"SCARF_HOLDERS:$holders\"; exit 3; fi",
        ]
        for path in paths {
            lines.append("[ -f \(Self.shellQuote(staging + "/" + path)) ] || { echo \(Self.shellQuote("the staged snapshot of " + path + " is missing")) >&2; exit 1; }")
        }
        for path in paths {
            let staged = Self.shellQuote(staging + "/" + path)
            let db = Self.shellQuote(hermesHome + "/" + path)
            lines.append("scarf_db=$(scarf_resolve \(db))")
            lines.append("mkdir -p \"$(dirname \"$scarf_db\")\" && chmod 600 \(staged) && rm -f \"$scarf_db-wal\" \"$scarf_db-shm\" \"$scarf_db-journal\" && mv -f \(staged) \"$scarf_db\" || exit 1")
            lines.append("printf 'SCARF_PUBLISHED\\t%s\\n' \(Self.shellQuote(path))")
        }
        lines.append("echo SCARF_GUARDED_OK")
        let result: ProcessResult
        do {
            result = try await transport.asyncRunProcess(
                executable: "/bin/bash",
                args: ["-lc", lines.joined(separator: "\n")],
                stdin: nil,
                timeout: Self.holderProbeTimeout
            )
        } catch {
            throw RestoreError.remoteCommandFailed("replacing the databases failed: \(error.localizedDescription)")
        }
        if result.exitCode == 0, result.stdoutString.contains("SCARF_GUARDED_OK") { return }
        switch Self.parseHolderOutput(result.stdoutString) {
        case .held(let pids)?:
            throw RestoreError.hermesRunning(pids: pids, homeRestored: true)
        case .unknown(let why)?:
            throw RestoreError.cannotConfirmHermesStopped(why, homeRestored: true)
        case .clear?, nil:
            let why = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let published = result.stdoutString.split(separator: "\n")
                .filter { $0.hasPrefix("SCARF_PUBLISHED\t") }
                .map { String($0.dropFirst("SCARF_PUBLISHED\t".count)) }
            let pending = paths.filter { !published.contains($0) }
            let progress = published.isEmpty
                ? " No database was replaced."
                : " Replaced: \(published.joined(separator: ", ")). Not replaced: \(pending.joined(separator: ", "))."
            throw RestoreError.remoteCommandFailed(
                "replacing the databases failed (exit \(result.exitCode))" + (why.isEmpty ? "" : ": \(why)") + "." + progress)
        }
    }

    /// A database path from an archive's manifest (or a v1 tarball) is only
    /// trusted when it is a plain home-relative `*.db` path: it is spliced
    /// into `rm` and `mv` on the target.
    static func isSafeDatabasePath(_ path: String) -> Bool {
        guard path.hasSuffix(".db"), !path.hasPrefix("/"),
              !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(".retired-wal-") }
    }

    /// Lift every `*.db` out of a v1 home tarball on the Mac and re-pack
    /// them, at their home-relative paths, as one database tarball, so a v1
    /// restore publishes its databases through the same guarded path as v2.
    /// v1 archived databases other than state.db live, WITH their `-wal`
    /// when there was one; such a WAL is folded into this scratch copy (a
    /// checkpoint of Scarf's own temporary file on the Mac, never of a
    /// Hermes database) so its committed frames aren't lost, and never
    /// shipped. `nil` when the archive has no database. Bounded (C10);
    /// Mac-only, like the rest of restore.
    static func liftLegacyDatabases(from tarball: URL, leaf: String, workDir: URL) async throws -> (tarball: URL, paths: [String])? {
        #if os(iOS)
        return nil
        #else
        // Extract only databases and their WALs, then look at what landed.
        // Not a `tar -t` listing: bsdtar escapes `\\` and non-ASCII bytes in
        // it, so names read from it can't be fed back to an extract.
        let stage = workDir.appendingPathComponent("legacy-databases", isDirectory: true)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let (status, output) = try await runLocalTar(
            ["-xzf", tarball.path, "-C", stage.path, "--include", "*.db", "--include", "*.db-wal"])
        // bsdtar exits 1 when an `--include` pattern matched nothing (no
        // WAL in the archive, or no database at all). That alone is fine;
        // anything else it says is a real failure.
        let onlyUnmatched = output.components(separatedBy: " / ").allSatisfy {
            $0.contains("Not found in archive") || $0.contains("Error exit delayed")
        }
        guard status == 0 || onlyUnmatched else {
            throw RestoreError.archiveUnreadable("couldn't read the databases from the backup (tar exit \(status)): \(output)")
        }
        let root = stage.appendingPathComponent(leaf)
        var paths: [String] = []
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            while let rel = walker.nextObject() as? String {
                // Hermes's retired-WAL captures move whole or not at all;
                // the restore leaves them out, as `hermes import` never sees
                // them. A directory that merely ends in `.db` isn't one.
                guard rel.hasSuffix(".db"), isSafeDatabasePath(rel),
                      (walker.fileAttributes?[.type] as? FileAttributeType) == .typeRegular
                else { continue }
                paths.append(rel)
            }
        }
        guard !paths.isEmpty else { return nil }
        paths.sort()
        for rel in paths where FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path + "-wal") {
            try await foldLocalWAL(root.appendingPathComponent(rel).path)
        }
        let repacked = workDir.appendingPathComponent("legacy-databases.tar.gz")
        // `-C root` + plain operands: creation reads paths literally.
        let (packStatus, packOutput) = try await runLocalTar(["-czf", repacked.path, "-C", root.path] + paths)
        guard packStatus == 0 else {
            throw RestoreError.localIO("couldn't repack the databases from the backup (tar exit \(packStatus)): \(packOutput)")
        }
        return (repacked, paths)
        #endif
    }

    #if !os(iOS)
    /// Checkpoint a v1 archive's WAL into Scarf's own scratch copy of the
    /// database (in the restore's temp dir on this Mac) and delete the WAL.
    private static func foldLocalWAL(_ path: String) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [path, "PRAGMA wal_checkpoint(TRUNCATE);"]
        let errPipe = Pipe(), outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe
        do { try proc.run() } catch {
            for pipe in [errPipe, outPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw RestoreError.localIO("Couldn't launch sqlite3: \(error.localizedDescription)")
        }
        let (exited, drained) = await proc.waitDrainingAsync(timeout: unzipTimeout, pipes: [errPipe, outPipe])
        try? errPipe.fileHandleForWriting.close()
        try? outPipe.fileHandleForWriting.close()
        guard exited, proc.terminationStatus == 0 else {
            throw RestoreError.archiveUnreadable(
                "couldn't fold the archived WAL into \((path as NSString).lastPathComponent): \(outputTail(drained))")
        }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// `/usr/bin/tar` on the Mac, bounded by ``unzipTimeout`` (it reads the
    /// same multi-GB archive) and drained concurrently. `capture` returns
    /// stdout whole (a listing); otherwise the output tail.
    private static func runLocalTar(_ args: [String], capture: Bool = false) async throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = args
        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe
        let started = Date()
        do {
            try proc.run()
        } catch {
            for pipe in [errPipe, outPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw RestoreError.localIO("Couldn't launch tar: \(error.localizedDescription)")
        }
        let (exited, drained) = await proc.waitDrainingAsync(
            timeout: max(0, unzipTimeout - Date().timeIntervalSince(started)),
            pipes: [errPipe, outPipe])
        try? errPipe.fileHandleForWriting.close()
        try? outPipe.fileHandleForWriting.close()
        guard exited else {
            throw RestoreError.archiveUnreadable("tar did not finish within \(Int(unzipTimeout))s and was stopped")
        }
        if capture {
            return (proc.terminationStatus, String(decoding: drained.count > 1 ? drained[1] : Data(), as: UTF8.self))
        }
        return (proc.terminationStatus, outputTail(drained))
    }
    #endif

    private func removeStagingDir(transport: any ServerTransport, staging: String) async {
        _ = try? await transport.asyncRunProcess(
            executable: "/bin/bash",
            args: ["-lc", "rm -rf \(Self.shellQuote(staging))"],
            stdin: nil,
            timeout: 60
        )
    }

    // MARK: - Helpers

    /// Mac-only: iOS doesn't ship `/usr/bin/unzip` and Foundation's
    /// `Process` is unavailable in the iOS SDK. Restore is initiated from
    /// the Mac app; the iOS stub throws so any accidental call surfaces a
    /// clear message instead of a link-time failure.
    static func unzipArchive(
        at archive: URL,
        into dest: URL,
        timeout: TimeInterval = RemoteRestoreService.unzipTimeout
    ) async throws {
        #if os(iOS)
        throw RestoreError.archiveUnreadable("Restore unzip is not supported on iOS — run the restore from the Mac app.")
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
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", archive.path, "-d", dest.path]
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
            throw RestoreError.archiveUnreadable("Couldn't launch unzip: \(error.localizedDescription)")
        }
        // C10: bounded, and drained CONCURRENTLY with the wait — `unzip`
        // prints a line per problem entry, so a corrupt or adversarial
        // backup fills the 64 KB pipe buffer and deadlocks a parent that
        // reads only after the wait. The archive here is the USER'S file,
        // chosen in an open panel: the one input Scarf trusts least.
        let (exited, drained) = await proc.waitDrainingAsync(
            timeout: max(0, timeout - Date().timeIntervalSince(started)),
            pipes: [errPipe, outPipe])
        try? errPipe.fileHandleForWriting.close()
        try? outPipe.fileHandleForWriting.close()
        guard exited else {
            throw RestoreError.archiveUnreadable(
                "unzip did not finish within \(Int(timeout))s and was stopped")
        }
        if proc.terminationStatus != 0 {
            let tail = String(data: drained.first ?? Data(), encoding: .utf8) ?? ""
            throw RestoreError.archiveUnreadable("unzip exited \(proc.terminationStatus): \(tail)")
        }
        #endif
    }

    /// Hash a local file in 1 MB chunks. We avoid loading the whole
    /// file into memory because tarballs can be multi-GB.
    private static func verifyHash(file: URL, expected: String) async throws {
        guard let fh = try? FileHandle(forReadingFrom: file) else {
            throw RestoreError.archiveUnreadable("missing inner file: \(file.lastPathComponent)")
        }
        defer { try? fh.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if actual != expected {
            throw RestoreError.integrityCheckFailed(path: file.lastPathComponent, expected: expected, actual: actual)
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
