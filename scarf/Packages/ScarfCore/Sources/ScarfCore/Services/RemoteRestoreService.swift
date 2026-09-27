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
                return "Hermes is running on this server: process \(list) has state.db open. Restoring over a database that is in use can corrupt it or lose sessions. Stop the Hermes gateway and close any Hermes chats on this server (including Scarf chat windows), then restore again. \(Self.outcome(homeRestored))"
            case .cannotConfirmHermesStopped(let m, let homeRestored):
                return "Couldn't confirm that Hermes is stopped on this server (\(m)). Stop the Hermes gateway and any Hermes chats there, then restore again. \(Self.outcome(homeRestored))"
            case .cancelled: return "Restore cancelled."
            }
        }

        private static func outcome(_ homeRestored: Bool) -> String {
            homeRestored
                ? "The rest of the Hermes home was restored, but state.db was left as it was."
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
        if let state = manifest.stateDB {
            try await Self.verifyHash(file: workDir.appendingPathComponent(state.tarballPath), expected: state.tarballSHA256)
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
            holders = await probeStateDBHolders(transport: transport, hermesHome: hermesHome)
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

        // Refuse BEFORE writing anything when something holds state.db
        // open. Checked again right before state.db itself is replaced.
        try await requireStateDBUnheld(transport: transport, hermesHome: hermesHome)

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

        // Stage 1: hermes home. The tarball's single top-level directory
        // (`.hermes/` in v1, the source home's own name in v2) is stripped
        // so its contents land directly in `hermesHome`, whatever that
        // directory is called on the target.
        try Task.checkCancellation()
        if manifest.stateDB == nil {
            // v1 (or a source without state.db): if the tarball carries a
            // state.db, `tar` replaces the file. The old database's
            // -wal/-shm/-journal must go first, or SQLite would replay that
            // foreign WAL over the restored file, and the guard re-checks
            // that nothing holds it (`hermes_cli/backup.py:550-555`).
            try await runStateDBGuarded(
                transport: transport, hermesHome: hermesHome, homeRestored: false, then: nil)
        }
        let hermesTar = inspection.workDir.appendingPathComponent(manifest.hermes.tarballPath)
        try await pushTarball(
            transport: transport,
            tarball: hermesTar,
            extractCommand: Self.hermesExtractCommand(
                hermesHome: hermesHome,
                // v1 always archived `.hermes/`; v2 archives the source
                // home's own directory name.
                archiveLeaf: manifest.schemaVersion >= 2
                    ? (manifest.hermes.homePath as NSString).lastPathComponent
                    : ".hermes")
        ) { written in
            progress(.restoringHermes(bytesPushed: written))
        }

        // Stage 1b (v2): the state.db snapshot. Extracted into a staging
        // directory beside the database (same filesystem, so the publish
        // is a rename), then published only after a last holder check,
        // with the old sidecars removed first.
        if let state = manifest.stateDB {
            try Task.checkCancellation()
            let staging = hermesHome + "/" + Self.stagingDirPrefix + UUID().uuidString
            do {
                try await pushTarball(
                    transport: transport,
                    tarball: inspection.workDir.appendingPathComponent(state.tarballPath),
                    extractCommand: "mkdir -p \(Self.shellQuote(staging)) && tar -xzf - -C \(Self.shellQuote(staging))"
                ) { _ in }
                try await runStateDBGuarded(
                    transport: transport,
                    hermesHome: hermesHome,
                    homeRestored: true,
                    then: "mv -f \(Self.shellQuote(staging + "/state.db")) \(Self.shellQuote(hermesHome + "/state.db"))"
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

        // Stage 4: pause cron jobs.
        var paused = 0
        if options.pauseCronJobs {
            try Task.checkCancellation()
            progress(.pausingCron)
            paused = try await pauseAllCronJobs(transport: transport, hermesHome: hermesHome)
        }

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

    /// Set `enabled: false` on every cron job. Returns the count
    /// flipped (0 if jobs.json is absent).
    ///
    /// Same rewrite as `reanchorProjectsRegistry`, and the same reason: a
    /// truncating write that failed used to be indistinguishable from one
    /// that worked, so a restore could report "12 cron jobs paused" — or
    /// "0", which reads as "nothing to pause" — while every restored job
    /// stayed armed with the source host's credentials.
    func pauseAllCronJobs(transport: any ServerTransport, hermesHome: String) async throws -> Int {
        let path = hermesHome + "/cron/jobs.json"
        return try Self.mutateRemoteJSON(
            transport: transport,
            path: path,
            label: "Cron pause",
            sortKeys: false
        ) { root in
            guard var jobs = root["jobs"] as? [[String: Any]] else { return nil }
            var count = 0
            for index in jobs.indices where (jobs[index]["enabled"] as? Bool) == true {
                jobs[index]["enabled"] = false
                count += 1
            }
            guard count > 0 else { return nil }
            root["jobs"] = jobs
            return count
        } ?? 0
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
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
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

    /// Prefix of the directory a v2 state.db snapshot is staged in, inside
    /// the target Hermes home, before it is renamed over `state.db`.
    public static let stagingDirPrefix = ".scarf-restore-staging-"

    /// Ceiling on a holder probe or a guarded state.db publish (C10). The
    /// `/proc` scan and `lsof` both finish in well under a second on a
    /// normal host.
    static let holderProbeTimeout: TimeInterval = 60

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
    /// The database's `-wal`/`-shm`/`-journal` are never extracted, even
    /// from a hand-built or older archive that carries them: they describe
    /// some other image of the database, and SQLite would replay them over
    /// the restored one. Hermes's own import skips them for the same reason
    /// (`hermes_cli/backup.py:946-951` @ v2026.9.24).
    static func hermesExtractCommand(hermesHome: String, archiveLeaf: String) -> String {
        let home = shellQuote(hermesHome)
        let excludes = ["-wal", "-shm", "-journal"]
            .map { "--exclude=\(shellQuote(archiveLeaf + "/state.db" + $0))" }
            .joined(separator: " ")
        return "{ [ -d \(home) ] || { mkdir -p \(home) && chmod 700 \(home); }; } && tar -xzf - \(excludes) --strip-components=1 -C \(home)"
    }

    /// A bash snippet that sets `holders` to the PIDs of the processes
    /// (other than `ownPID`) holding `<hermesHome>/state.db`, `-wal` or
    /// `-shm` open, or to `UNKNOWN` when the host offers no way to tell.
    ///
    /// Linux: every `/proc/<pid>/fd` link, read with one `ls -l`; an
    /// already-unlinked `(deleted)` target still counts as held, the
    /// split-brain fingerprint Hermes checks for
    /// (`hermes_cli/backup.py:469-506` @ v2026.9.24). The database path is
    /// resolved with `pwd -P` first because `/proc` links name the real
    /// path. Elsewhere (the Mac's own local server): `lsof -t` on the files
    /// that exist. Other users' processes are invisible without root,
    /// exactly as they are to Hermes's own check.
    static func holderScanScript(hermesHome: String, ownPID: Int32?) -> String {
        """
        scarf_db_dir=\(shellQuote(hermesHome))
        if [ -d "$scarf_db_dir" ]; then scarf_db_dir=$(cd "$scarf_db_dir" && pwd -P); fi
        scarf_db="$scarf_db_dir/state.db"
        scarf_own=\(ownPID.map(String.init) ?? "")
        holders=""
        scarf_found=""
        if [ "$(uname -s 2>/dev/null)" = Linux ] && [ -d /proc/self/fd ]; then
          scarf_found=$(ls -l /proc/[0-9]*/fd 2>/dev/null | SCARF_DB="$scarf_db" awk \(shellQuote(procFDAwkProgram)) | sort -u)
        elif command -v lsof >/dev/null 2>&1 || [ -x /usr/sbin/lsof ]; then
          scarf_lsof=$(command -v lsof 2>/dev/null || echo /usr/sbin/lsof)
          set --
          for f in "$scarf_db" "$scarf_db-wal" "$scarf_db-shm"; do [ -e "$f" ] && set -- "$@" "$f"; done
          if [ $# -gt 0 ]; then scarf_found=$("$scarf_lsof" -t -- "$@" 2>/dev/null | sort -u); fi
        else
          holders=UNKNOWN
        fi
        if [ "$holders" != UNKNOWN ]; then
          for p in $scarf_found; do [ "$p" = "$scarf_own" ] || holders="$holders $p"; done
        fi
        """
    }

    /// Reads `ls -l /proc/[0-9]*/fd` and prints the PID of every directory
    /// holding a link to `$SCARF_DB`, `-wal` or `-shm` (a ` (deleted)`
    /// suffix still matches). Kept separate so the tests can feed it a
    /// captured `/proc` listing on a Mac.
    static let procFDAwkProgram = #"""
    /^\/proc\/[0-9]+\/fd:$/ { pid = $0; sub(/^\/proc\//, "", pid); sub(/\/fd:$/, "", pid); next }
    {
      i = index($0, " -> ")
      if (i > 0) {
        t = substr($0, i + 4)
        sub(/ \(deleted\)$/, "", t)
        db = ENVIRON["SCARF_DB"]
        if (t == db || t == db "-wal" || t == db "-shm") print pid
      }
    }
    """#

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

    /// Look for processes holding the target's state.db open. Never throws:
    /// a probe that could not run is `.unknown`.
    func probeStateDBHolders(transport: any ServerTransport, hermesHome: String) async -> DBHolderProbe {
        let script = Self.holderScanScript(hermesHome: hermesHome, ownPID: ownPIDIfLocal(transport))
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

    /// Throw unless nothing holds the target's state.db open.
    private func requireStateDBUnheld(transport: any ServerTransport, hermesHome: String) async throws {
        switch await probeStateDBHolders(transport: transport, hermesHome: hermesHome) {
        case .clear: return
        case .held(let pids): throw RestoreError.hermesRunning(pids: pids, homeRestored: false)
        case .unknown(let why): throw RestoreError.cannotConfirmHermesStopped(why, homeRestored: false)
        }
    }

    /// In ONE host command: re-check that nothing holds state.db, remove
    /// its `-wal`/`-shm`/`-journal` (they describe the database being
    /// replaced), then run `publish`, if any. The check and the replacement
    /// share a shell, so nothing can open the database in between unseen.
    /// Mirrors Hermes's own unlink+move restore
    /// (`hermes_cli/backup.py:536-559` @ v2026.9.24).
    private func runStateDBGuarded(
        transport: any ServerTransport,
        hermesHome: String,
        homeRestored: Bool,
        then publish: String?
    ) async throws {
        let db = Self.shellQuote(hermesHome + "/state.db")
        var lines = [
            Self.holderScanScript(hermesHome: hermesHome, ownPID: ownPIDIfLocal(transport)),
            "if [ -n \"$holders\" ]; then echo \"SCARF_HOLDERS:$holders\"; exit 3; fi",
            "rm -f \(db)-wal \(db)-shm \(db)-journal || exit 1",
        ]
        if let publish { lines.append("\(publish) || exit 1") }
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
            throw RestoreError.remoteCommandFailed("state.db safety check failed: \(error.localizedDescription)")
        }
        if result.exitCode == 0, result.stdoutString.contains("SCARF_GUARDED_OK") { return }
        switch Self.parseHolderOutput(result.stdoutString) {
        case .held(let pids)?:
            throw RestoreError.hermesRunning(pids: pids, homeRestored: homeRestored)
        case .unknown(let why)?:
            throw RestoreError.cannotConfirmHermesStopped(why, homeRestored: homeRestored)
        case .clear?, nil:
            let why = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RestoreError.remoteCommandFailed(
                "replacing state.db failed (exit \(result.exitCode))" + (why.isEmpty ? "" : ": \(why)"))
        }
    }

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
