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

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
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

        // Only when the folder is still there. A project removed BECAUSE its
        // folder is gone must not have the removal report a failure to edit
        // a file inside it.
        if transport.fileExists(entry.path + "/AGENTS.md") {
            do {
                let before = try? transport.readFile(entry.path + "/AGENTS.md")
                try ProjectContextBlock.removeBlock(forProjectAt: entry.path, context: context)
                let after = try? transport.readFile(entry.path + "/AGENTS.md")
                result.contextBlockStripped = before != after
            } catch {
                result.warnings.append(
                    "Couldn't remove Scarf's section from \(entry.path)/AGENTS.md: \(error.localizedDescription)"
                )
            }
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
        let jobs = loadCronJobs()
        guard !jobs.isEmpty else { return [] }
        let projPrefix = "[proj:\(projectID(for: entry).uuidString)]"
        let templateId = ProjectStore(context: context).templateInfo(projectPath: entry.path)?.id
        let tmplPrefix = templateId.map { "[tmpl:\($0)]" }
        return jobs.compactMap { job in
            if job.name.hasPrefix(projPrefix) { return job.id }
            if let tmplPrefix, job.name.hasPrefix(tmplPrefix) { return job.id }
            return nil
        }
    }

    /// Pause (`archiving: true`) or resume (`false`) the project's cron jobs
    /// via `hermes cron pause|resume <id>` — the same invocation
    /// `ProjectTemplateInstaller` and the Cron feature already use, never a
    /// second way of saying it.
    ///
    /// Archiving used to be a bool the sidebar filtered on: the jobs kept
    /// firing, writing into a project the user had put away and believed was
    /// quiet. Resume on unarchive is the symmetric half — without it,
    /// archiving would be a one-way door dressed as a toggle.
    ///
    /// Returns the ids it could not change. Best effort: a host that is down
    /// must not block the archive, and a job that is already paused answers
    /// non-zero on some Hermes versions, which is not a failure worth
    /// stopping for.
    @discardableResult
    public nonisolated func setCronPaused(_ paused: Bool, for entry: ProjectEntry) -> [String] {
        let ids = cronJobIDs(for: entry)
        guard !ids.isEmpty else { return [] }
        let verb = paused ? "pause" : "resume"
        var failed: [String] = []
        for id in ids {
            // Through the transport, not a Mac-only helper: this runs on
            // iOS over SSH too, and every subprocess Scarf spawns carries a
            // timeout (charter C10).
            let result = try? transport.runProcess(
                executable: context.paths.hermesBinary,
                args: ["cron", verb, id],
                stdin: nil,
                timeout: 30
            )
            guard let result, result.exitCode == 0 else {
                failed.append(id)
                #if canImport(os)
                Self.logger.warning(
                    "couldn't \(verb, privacy: .public) cron job \(id, privacy: .public): \(result?.stderrString ?? "no result", privacy: .public)"
                )
                #endif
                continue
            }
        }
        return failed
    }

    // MARK: - Private

    private nonisolated func loadCronJobs() -> [HermesCronJob] {
        guard let data = try? transport.readFile(context.paths.cronJobsJSON),
              data.count <= ProjectStore.maxJSONBytes
        else { return [] }
        return (try? JSONDecoder().decode(CronJobsFile.self, from: data))?.jobs ?? []
    }
}
