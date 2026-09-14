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
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .archiveUnreadable(let m): return "Couldn't read the backup archive: \(m)"
            case .unsupportedSchema(let v): return "Backup uses schema v\(v), which this version of Scarf doesn't recognize."
            case .wrongKind(let k): return "This file isn't a Scarf server backup (kind: \(k))."
            case .integrityCheckFailed(let p, let exp, let act): return "Backup is corrupt — \(p) hash mismatch (expected \(exp.prefix(12))…, got \(act.prefix(12))…)."
            case .remoteCommandFailed(let m): return "Remote command failed during restore: \(m)"
            case .localIO(let m): return "Local file I/O failed during restore: \(m)"
            case .cancelled: return "Restore cancelled."
            }
        }
    }

    /// What `inspect()` returns to drive the restore-plan sheet. The
    /// caller picks `targetProjectsRoot`, optionally tweaks the cron
    /// pause toggle, then calls `run()` with the same archive URL.
    public struct InspectionResult: Sendable {
        public var manifest: BackupManifest
        public var workDir: URL          // unzipped temp dir; reused by run()
        public var targetHomeResolved: String?
        public var targetHermesVersion: String?
    }

    public struct RestoreOptions: Sendable {
        /// Where to drop project tarballs. Each project lands at
        /// `<targetProjectsRoot>/<basename>`. Defaults to
        /// `<targetHome>/projects` when not specified.
        public var targetProjectsRoot: String?
        /// Override the resolved target home (rarely needed; the
        /// default is whatever `bash -lc 'echo $HOME'` returned).
        public var targetHomeOverride: String?
        /// Pause every cron job after restore. Strongly recommended
        /// (the user re-enables intentionally).
        public var pauseCronJobs: Bool

        public init(
            targetProjectsRoot: String? = nil,
            targetHomeOverride: String? = nil,
            pauseCronJobs: Bool = true
        ) {
            self.targetProjectsRoot = targetProjectsRoot
            self.targetHomeOverride = targetHomeOverride
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
        guard manifest.schemaVersion == BackupManifest.currentSchemaVersion else {
            throw RestoreError.unsupportedSchema(manifest.schemaVersion)
        }

        // Hash-verify every inner tarball before any remote bytes are
        // pushed.
        try await Self.verifyHash(file: workDir.appendingPathComponent(manifest.hermes.tarballPath), expected: manifest.hermes.tarballSHA256)
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

        handedToCaller = true
        return InspectionResult(
            manifest: manifest,
            workDir: workDir,
            targetHomeResolved: (resolvedHome?.isEmpty == false) ? resolvedHome : nil,
            targetHermesVersion: (resolvedVersion?.isEmpty == false) ? resolvedVersion : nil
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

        let targetHome = options.targetHomeOverride
            ?? inspection.targetHomeResolved
            ?? (manifest.hermes.homePath as NSString).deletingLastPathComponent
        let projectsRoot = options.targetProjectsRoot ?? (targetHome + "/projects")

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

        // Stage 1: hermes home. Pushes into $HOME so the inner
        // `.hermes/...` paths land at `<targetHome>/.hermes/...`.
        try Task.checkCancellation()
        let hermesTar = inspection.workDir.appendingPathComponent(manifest.hermes.tarballPath)
        try await pushTarball(
            transport: transport,
            tarball: hermesTar,
            extractInto: targetHome
        ) { written in
            progress(.restoringHermes(bytesPushed: written))
        }

        // Stage 2: per-project tarballs.
        var restoredProjects: [RestoreResult.RestoredProject] = []
        for project in manifest.projects {
            try Task.checkCancellation()
            let tar = inspection.workDir.appendingPathComponent(project.tarballPath)
            try await pushTarball(
                transport: transport,
                tarball: tar,
                extractInto: projectsRoot
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
            targetHome: targetHome,
            mapping: Dictionary(
                uniqueKeysWithValues: restoredProjects.map { ($0.sourcePath, $0.targetPath) }
            )
        )

        // Stage 4: pause cron jobs.
        var paused = 0
        if options.pauseCronJobs {
            try Task.checkCancellation()
            progress(.pausingCron)
            paused = try await pauseAllCronJobs(transport: transport, targetHome: targetHome)
        }

        progress(.finalizing)
        return RestoreResult(
            manifest: manifest,
            hermesHome: targetHome + "/.hermes",
            projectsRestored: restoredProjects,
            cronJobsPaused: paused
        )
    }

    // MARK: - Push (tarball -> remote stdin)

    /// Stream a local `.tar.gz` into `tar -xzf - -C <target>` on the
    /// destination. We use `transport.makeProcess` so the command is
    /// shell-wrapped the same way the rest of the app talks to remotes
    /// (`bash -lc` for SSH, direct invocation for local).
    private func pushTarball(
        transport: any ServerTransport,
        tarball: URL,
        extractInto target: String,
        extractTimeout: TimeInterval = RemoteRestoreService.remoteExtractTimeout,
        stallTimeout: TimeInterval = RemoteRestoreService.pumpStallTimeout,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws {
        #if os(iOS)
        throw RestoreError.remoteCommandFailed("Remote restore is not supported on iOS in this build.")
        #else
        let cmd = "tar -xzf - -C \(Self.shellQuote(target))"
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
        targetHome: String,
        mapping: [String: String]
    ) async throws {
        guard !mapping.isEmpty else { return }
        let registryPath = targetHome + "/.hermes/scarf/projects.json"
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
    func pauseAllCronJobs(transport: any ServerTransport, targetHome: String) async throws -> Int {
        let path = targetHome + "/.hermes/cron/jobs.json"
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

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
