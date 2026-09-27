import Foundation
#if canImport(os)
import os
#endif

/// The side effects of a project's lifecycle transitions — the ones that
/// live OUTSIDE `projects.json`.
///
/// **Why this exists.** Adding a project touches half a dozen stores; for a
/// long time removing one touched exactly one. A row deleted from the
/// registry left behind:
///
/// - the Scarf-managed AGENTS.md block, still describing the project (its
///   template, its cron ids, its slash commands) to every agent that opens
///   the folder;
/// - every mini-app permission grant the user ever approved — and because
///   project ids are DERIVED from (host, path), re-using the folder later
///   resurrects them under a new project;
/// - the project's cron jobs, still scheduled.
///
/// And archiving touched nothing at all: `archived` was a display bool the
/// sidebar filtered on while the watchers kept polling, the cron kept
/// firing, and the grants kept resolving. "Archived" said something to the
/// user that was not true of the system.
///
/// This service is the one place those transitions are spelled out, so a
/// new caller gets the whole set rather than the half it remembered.
/// Everything here is BEST-EFFORT and reports rather than throws: none of
/// it may be allowed to fail a removal the user asked for and the registry
/// already committed. What went wrong comes back as warnings the caller can
/// show or log.
public struct ProjectLifecycleService: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectLifecycleService")
    #endif

    public let context: ServerContext
    private let transport: any ServerTransport

    /// Runs one `hermes cron <verb> <id>` and answers whether it exited 0.
    /// Tests inject one; `nil` runs the real CLI through the transport.
    public typealias CronVerbRunner = @Sendable (_ args: [String]) -> Bool
    private let cronRunner: CronVerbRunner?

    public nonisolated init(context: ServerContext = .local, cronRunner: CronVerbRunner? = nil) {
        self.context = context
        self.transport = context.makeTransport()
        self.cronRunner = cronRunner
    }

    // MARK: - Identity

    /// The id a project's grants and `[proj:…]` cron tags are keyed on.
    /// The registry row's `uuid` when it has one, otherwise the same
    /// deterministic (host, path) id every other reader derives — so
    /// cleanup finds the state a pre-uuid row's project wrote.
    public nonisolated func projectID(for entry: ProjectEntry) -> UUID {
        entry.uuid ?? ProjectIdentity.deterministicID(
            forProjectPath: entry.path,
            hostKey: ProjectIdentity.hostKey(for: context)
        )
    }

    // MARK: - Removal

    /// What a cleanup pass did and what it couldn't do.
    public struct CleanupResult: Sendable, Equatable {
        /// Mini-app permission grants revoked.
        public var grantsRevoked: Int = 0
        /// Whether the managed AGENTS.md block was found and stripped.
        public var contextBlockStripped: Bool = false
        /// Human-readable reasons individual steps didn't complete. Never a
        /// reason to call the removal itself failed.
        public var warnings: [String] = []
    }

    /// Undo the state a project accumulated outside the registry, after its
    /// row has already been removed.
    ///
    /// Deliberately does NOT touch the project's files beyond the AGENTS.md
    /// block, and does NOT remove cron jobs: "remove from my projects list"
    /// is not "delete my work", and a scheduled job the user set up is work.
    /// Template UNINSTALL is the flow that removes cron jobs, and it does so
    /// from the lock that recorded them.
    @discardableResult
    public nonisolated func cleanUpAfterRemoval(of entry: ProjectEntry) -> CleanupResult {
        var result = CleanupResult()

        do {
            result.grantsRevoked = try MiniAppGrantStore(context: context)
                .revokeAll(projectId: projectID(for: entry).uuidString)
        } catch {
            result.warnings.append(
                "Couldn't revoke this project's mini-app permissions: \(error.localizedDescription)"
            )
        }

        // A project removed BECAUSE its folder is gone must not have the
        // removal report a failure to edit a file inside it — which is why
        // this used to open with `fileExists`. That gate was INFERENCE
        // (GW-F2, audit DI M4): one dropped SSH round-trip answered `false`
        // and the block was silently left in the user's AGENTS.md, reported
        // as a clean removal. It also bracketed the call with two `try?`
        // reads to guess whether anything changed, so a failed read on
        // either side became "nothing was stripped".
        //
        // `removeBlock` already carries the guard: absence is its no-op,
        // non-UTF-8 bytes are left alone, and only a stat-confirmed
        // unreadable file throws. It now also REPORTS whether it rewrote
        // anything, so the outcome comes from the publisher instead of a
        // before/after diff nobody could trust.
        do {
            result.contextBlockStripped = try ProjectContextBlock.removeBlock(
                forProjectAt: entry.path, context: context
            )
        } catch {
            result.warnings.append(
                "Couldn't remove Scarf's section from \(entry.path)/AGENTS.md: \(error.localizedDescription)"
            )
        }

        #if canImport(os)
        for warning in result.warnings {
            Self.logger.warning("removal cleanup: \(warning, privacy: .public)")
        }
        #endif
        return result
    }

    // MARK: - Archive

    /// Ids of the cron jobs attributed to this project — the `[proj:<uuid>]`
    /// tag, plus the legacy `[tmpl:<templateId>]` prefix for template
    /// installs that predate project tagging. Same rule `ProjectStore.derive`
    /// applies, so archive acts on exactly the jobs the project record
    /// claims.
    public nonisolated func cronJobIDs(for entry: ProjectEntry) -> [String] {
        attributed(loadCronJobs(), to: entry).map(\.id)
    }

    /// The attributed jobs the scheduler would fire right now — `enabled`
    /// and carrying no pause marker, Hermes's own `is_job_runnable`
    /// (`cron/jobs.py:521-524` @ v2026.9.24). These, and only these, are the
    /// jobs archiving pauses and records; a job that was already paused
    /// (a template job created paused and never reviewed, say) is left
    /// alone so restoring the project can't switch it on.
    ///
    /// `nil` when `jobs.json` exists but can't be read or decoded (a remote
    /// that is down, a half-written file): the caller must say so rather
    /// than archive as if the project had no jobs. A missing file is `[]`.
    public nonisolated func runnableCronJobIDs(for entry: ProjectEntry) -> [String]? {
        guard let jobs = loadCronJobsIfReadable() else { return nil }
        return attributed(jobs, to: entry).compactMap { job in
            guard job.enabled,
                  job.state.trimmingCharacters(in: .whitespaces) != "paused",
                  !HermesCronJob.isTruthyPauseMarker(job.extra["paused_at"])
            else { return nil }
            return job.id
        }
    }

    private nonisolated func attributed(_ jobs: [HermesCronJob], to entry: ProjectEntry) -> [HermesCronJob] {
        guard !jobs.isEmpty else { return [] }
        let projPrefix = "[proj:\(projectID(for: entry).uuidString)]"
        let templateId = ProjectStore(context: context).templateInfo(projectPath: entry.path)?.id
        let tmplPrefix = templateId.map { "[tmpl:\($0)]" }
        return jobs.filter { job in
            if job.name.hasPrefix(projPrefix) { return true }
            if let tmplPrefix, job.name.hasPrefix(tmplPrefix) { return true }
            return false
        }
    }

    /// Pause each job via `hermes cron pause <id>` — the same invocation
    /// `ProjectTemplateInstaller` and the Cron feature use. Returns the ids
    /// it could not pause, which the caller must show: those jobs are
    /// still scheduled although the project reads as archived.
    @discardableResult
    public nonisolated func pauseCronJobs(_ ids: [String]) -> [String] {
        ids.filter { !runCron(["cron", "pause", $0]) }
    }

    /// Resume the jobs archiving paused (the ids recorded on the registry
    /// row), skipping any that no longer exist or are no longer paused —
    /// the user deleted or resumed it themselves while the project was
    /// archived. Returns the ids it tried and could not resume.
    @discardableResult
    public nonisolated func resumeArchivedCronJobs(_ ids: [String]) -> [String] {
        guard !ids.isEmpty else { return [] }
        let stillPaused = Set(loadCronJobs().filter { $0.effectiveState == "paused" }.map(\.id))
        return ids.filter { stillPaused.contains($0) }.filter { !runCron(["cron", "resume", $0]) }
    }

    /// One cron verb, exit 0 or not. Through the transport, not a Mac-only
    /// helper: this runs on iOS over SSH too, and every subprocess Scarf
    /// spawns carries a timeout (charter C10).
    private nonisolated func runCron(_ args: [String]) -> Bool {
        if let cronRunner { return cronRunner(args) }
        let result = try? transport.runProcess(
            executable: context.paths.hermesBinary,
            args: args,
            stdin: nil,
            timeout: 30
        )
        guard let result, result.exitCode == 0 else {
            #if canImport(os)
            Self.logger.warning(
                "hermes \(args.joined(separator: " "), privacy: .public) failed: \(result?.stderrString ?? "no result", privacy: .public)"
            )
            #endif
            return false
        }
        return true
    }

    // MARK: - Private

    private nonisolated func loadCronJobs() -> [HermesCronJob] {
        loadCronJobsIfReadable() ?? []
    }

    /// `[]` when there is no `jobs.json` (no cron on this host), `nil` when
    /// there is one Scarf can't read or decode.
    private nonisolated func loadCronJobsIfReadable() -> [HermesCronJob]? {
        let path = context.paths.cronJobsJSON
        guard let data = try? transport.readFile(path) else {
            return transport.fileExists(path) ? nil : []
        }
        guard data.count <= ProjectStore.maxJSONBytes,
              let file = try? JSONDecoder().decode(CronJobsFile.self, from: data)
        else { return nil }
        return file.jobs
    }
}

// MARK: - Archive record

extension ProjectEntry {
    /// Registry key holding the cron job ids archiving paused, so restoring
    /// resumes exactly those. Stored through `extra`, which every Scarf
    /// since the registry's unknown-key contract carries through unchanged.
    static let archivePausedCronJobIDsKey = "archivePausedCronJobIds"

    /// The ids archiving paused, or `nil` when there is no record: the row
    /// isn't archived, archiving paused nothing, or an older Scarf archived
    /// it (it recorded nothing, so restoring resumes nothing).
    public var archivePausedCronJobIDs: [String]? {
        get {
            guard case .array(let values)? = extra[Self.archivePausedCronJobIDsKey] else { return nil }
            let ids = values.compactMap { value -> String? in
                if case .string(let id) = value { return id }
                return nil
            }
            return ids.isEmpty ? nil : ids
        }
        set {
            if let newValue, !newValue.isEmpty {
                extra[Self.archivePausedCronJobIDsKey] = .array(newValue.map { .string($0) })
            } else {
                extra.removeValue(forKey: Self.archivePausedCronJobIDsKey)
            }
        }
    }
}
