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

        // Unzip outer archive.
        try Self.unzipArchive(at: archiveURL, into: workDir)

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
        let homeProbe = try? transport.runProcess(
            executable: "/bin/bash",
            args: ["-lc", "echo \"$HOME\""],
            stdin: nil,
            timeout: 30
        )
        let resolvedHome = homeProbe?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionProbe = try? transport.runProcess(
            executable: "/bin/bash",
            args: ["-lc", "hermes --version 2>/dev/null || true"],
            stdin: nil,
            timeout: 30
        )
        let resolvedVersion = versionProbe?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

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
            mkdirResult = try transport.runProcess(
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
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws {
        #if os(iOS)
        throw RestoreError.remoteCommandFailed("Remote restore is not supported on iOS in this build.")
        #else
        let cmd = "tar -xzf - -C \(Self.shellQuote(target))"
        let proc = transport.makeProcess(executable: "/bin/bash", args: ["-lc", cmd])

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

        do {
            try proc.run()
        } catch {
            throw RestoreError.remoteCommandFailed("Couldn't start remote tar: \(error.localizedDescription)")
        }

        let writer = inPipe.fileHandleForWriting
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: tarball)
        } catch {
            try? writer.close()
            proc.terminate()
            throw RestoreError.localIO("Couldn't open tarball: \(error.localizedDescription)")
        }
        defer { try? reader.close() }

        var written: Int64 = 0
        let chunkSize = 64 * 1024
        do {
            while true {
                try Task.checkCancellation()
                let chunk = reader.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
                written += Int64(chunk.count)
                onProgress(written)
            }
        } catch is CancellationError {
            try? writer.close()
            proc.terminate()
            throw RestoreError.cancelled
        } catch {
            try? writer.close()
            proc.terminate()
            throw RestoreError.localIO("Couldn't pump tarball into remote: \(error.localizedDescription)")
        }
        try? writer.close() // signals EOF to the remote tar

        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let tail = (try? errPipe.fileHandleForReading.readToEnd())
                .flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } } ?? ""
            throw RestoreError.remoteCommandFailed("tar -x exited \(proc.terminationStatus): \(tail)")
        }
        #endif
    }

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
                try transport.writeFile(path + ".bak", data: data)
            } catch {
                #if canImport(os)
                Self.logger.warning("Could not back up \(path, privacy: .public) before restore rewrite: \(error.localizedDescription, privacy: .public)")
                #endif
            }
        }
        do {
            try transport.writeFile(path, data: encoded)
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
    private static func unzipArchive(at archive: URL, into dest: URL) throws {
        #if os(iOS)
        throw RestoreError.archiveUnreadable("Restore unzip is not supported on iOS — run the restore from the Mac app.")
        #else
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", archive.path, "-d", dest.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            throw RestoreError.archiveUnreadable("Couldn't launch unzip: \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let tail = (try? errPipe.fileHandleForReading.readToEnd())
                .flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } } ?? ""
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
