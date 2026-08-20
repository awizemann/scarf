import Foundation
import Observation

/// iOS Cron view-state. Loads `~/.hermes/cron/jobs.json` via the
/// transport, decodes into `CronJobsFile` (Codable, from M0a),
/// exposes the sorted list for SwiftUI.
///
/// M6 adds write paths: toggle enabled, delete, and upsert (add or
/// replace a job by id). All writes re-encode the full file with a
/// fresh `updatedAt` and call `transport.writeFile` — which on iOS
/// dispatches to Citadel SFTP with atomic rename semantics.
@Observable
@MainActor
public final class IOSCronViewModel {
    public let context: ServerContext

    public private(set) var jobs: [HermesCronJob] = []
    public private(set) var isLoading: Bool = true
    public private(set) var isSaving: Bool = false
    public private(set) var lastError: String?

    public init(context: ServerContext) {
        self.context = context
    }

    public func load() async {
        isLoading = true
        lastError = nil
        let ctx = context
        let path = ctx.paths.cronJobsJSON

        // v2.7 — instrumented for parity with Mac `cron.load`. iOS
        // Cron load is a single SFTP read of jobs.json so should be
        // snappy on most remotes; this measure point makes the cost
        // visible in ScarfMon traces alongside the rest of the iOS
        // load paths.
        let result: Result<CronJobsFile, Error> = await ScarfMon.measureAsync(.diskIO, "ios.cron.load") {
            await Task.detached {
                do {
                    guard let data = ctx.readData(path) else {
                        throw LoadError.missingFile(path: path)
                    }
                    let decoded = try JSONDecoder().decode(CronJobsFile.self, from: data)
                    return .success(decoded)
                } catch {
                    return Result<CronJobsFile, Error>.failure(error)
                }
            }.value
        }

        switch result {
        case .success(let file):
            jobs = Self.sorted(file.jobs)
            isLoading = false

        case .failure(let err as LoadError):
            // Missing jobs.json is the common case on a fresh Hermes
            // install — don't surface as an error, show an empty
            // list + hint in the UI.
            if case .missingFile = err {
                jobs = []
            } else {
                lastError = err.localizedDescription
            }
            isLoading = false

        case .failure(let err):
            lastError = "Couldn't parse jobs.json: \(err.localizedDescription)"
            isLoading = false
        }
    }

    /// Which route the last `toggleEnabled` / `setEnabled` call took.
    /// Diagnostic surface for tests and the "why is this stale" support
    /// path — the CLI route carries full Hermes semantics, the JSON
    /// route is the degraded fallback.
    public private(set) var lastToggleRoute: ToggleRoute?

    public enum ToggleRoute: String, Sendable {
        /// `hermes cron pause|resume <id>` ran on the host.
        case cli
        /// The CLI was unreachable; Scarf rewrote jobs.json itself.
        case jsonFallback
        /// Hermes (or Scarf's port of its precondition) refused the change.
        case refused
    }

    /// Toggle `enabled` on the job with the given id.
    ///
    /// **Preferred route: the Hermes CLI.** `hermes cron pause|resume <id>`
    /// carries the full upstream semantics — `resume_job` (cron/jobs.py:
    /// 2212-2233) recomputes `next_run_at` from now and refuses a
    /// past-deadline one-shot — which a jobs.json rewrite can't reproduce.
    /// iOS reaches it the same way macOS's `CronViewModel` does
    /// (CronViewModel.swift:126-130): `ServerTransport.runProcess`, which
    /// `CitadelServerTransport` implements over an SSH exec channel with
    /// the PATH + `HERMES_HOME` guards already in place.
    ///
    /// **Fallback: the jobs.json marker write.** Only when the CLI is
    /// genuinely unreachable (transport error, or `hermes` not on the
    /// host's PATH). A refusal from the CLI is NOT a fallback trigger —
    /// falling back there would write precisely the state Hermes declines
    /// to produce.
    @discardableResult
    public func toggleEnabled(id: String) async -> Bool {
        guard let prev = jobs.first(where: { $0.id == id }) else { return false }
        return await setEnabled(id: id, enabled: !prev.enabled)
    }

    /// Explicit-target variant of `toggleEnabled`. Idempotent: setting a
    /// job to the state it already holds still round-trips through Hermes
    /// (matching `hermes cron resume` on an already-running job).
    @discardableResult
    public func setEnabled(id: String, enabled: Bool, now: Date = Date()) async -> Bool {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return false }
        guard !isSaving else { return false }
        let prev = jobs[idx]
        lastError = nil

        // Scarf-side port of `resume_job`'s precondition. Checked BEFORE
        // either route so the refusal reads the same whether or not the
        // host's CLI is reachable.
        if enabled, prev.oneShotIsUnresumable(now: now) {
            lastToggleRoute = .refused
            lastError = Self.oneShotRefusalMessage(prev)
            return false
        }

        // The CLI route is remote-only. On iOS every real context is
        // `.ssh` (there is no local Hermes on a phone); a `.local`
        // context here only ever comes from a macOS-hosted unit test,
        // where spawning the developer's real `hermes` would be both
        // wrong and non-deterministic. Local → straight to the fallback.
        isSaving = true
        let outcome: CLIOutcome = context.isRemote
            ? await Self.runCronCLI(enabled ? "resume" : "pause", jobID: id, context: context)
            : .unavailable
        isSaving = false

        switch outcome {
        case .succeeded:
            lastToggleRoute = .cli
            // Hermes just rewrote jobs.json (next_run_at, paused_at,
            // state); re-read rather than guessing what it wrote.
            await load()
            return true

        case .refused(let message):
            lastToggleRoute = .refused
            lastError = message
            return false

        case .unavailable:
            lastToggleRoute = .jsonFallback
            var updated = jobs
            var next = prev.withEnabled(enabled, now: now)
            if enabled {
                // A stale past `next_run_at` would make the scheduler fire a
                // spurious catch-up run on the very next tick — and that fire
                // flows through `mark_job_run`, consuming one of the job's
                // `repeat.times` (cron/jobs.py:3019-3032). Clear it and let
                // Hermes's own loader recompute (see `clearingNextRunAt`).
                next = next.clearingNextRunAt()
            }
            updated[idx] = next
            return await saveJobs(updated)
        }
    }

    static func oneShotRefusalMessage(_ job: HermesCronJob) -> String {
        if let lastRunAt = job.lastRunAt, !lastRunAt.isEmpty {
            return "\"\(job.name)\" already ran — a one-shot job can't be resumed. Duplicate it to schedule a new run."
        }
        let when = job.schedule.runAt.map { CronScheduleFormatter.formatNextRun(iso: $0) } ?? "its scheduled time"
        return "Can't resume \"\(job.name)\" — the one-shot time (\(when)) is in the past and would never fire. Duplicate it with a new time instead."
    }

    // MARK: - CLI route

    enum CLIOutcome: Sendable {
        /// The command ran and exited 0.
        case succeeded
        /// The command ran and exited non-zero — Hermes refused. Never
        /// fall back to a JSON write on this.
        case refused(String)
        /// The command could not be run at all (transport failure, or
        /// `hermes` isn't on the host). Fall back to the JSON write.
        case unavailable
    }

    static func runCronCLI(_ verb: String, jobID: String, context: ServerContext) async -> CLIOutcome {
        let ctx = context
        return await Task.detached {
            let result: ProcessResult
            do {
                result = try ctx.makeTransport().runProcess(
                    executable: ctx.paths.hermesBinary,
                    args: ["cron", verb, jobID],
                    stdin: nil,
                    timeout: 30
                )
            } catch {
                return .unavailable
            }
            if result.exitCode == 0 { return .succeeded }
            let combined = result.stderrString + "\n" + result.stdoutString
            if result.exitCode == 127 || Self.looksLikeMissingBinary(combined) {
                return .unavailable
            }
            return .refused(Self.refusalMessage(verb: verb, output: combined, exitCode: result.exitCode))
        }.value
    }

    /// A shell that can't find `hermes` is "CLI unavailable", not a
    /// refusal — the JSON fallback is the right answer there.
    nonisolated static func looksLikeMissingBinary(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("command not found")
            || lower.contains("hermes: not found")
            || lower.contains("no such file or directory")
    }

    /// Surface Hermes's own wording when it gave any (its `resume_job`
    /// ValueError explains the past-deadline one-shot far better than a
    /// generic failure line), else a generic fallback.
    nonisolated static func refusalMessage(verb: String, output: String, exitCode: Int32) -> String {
        let line = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        if let line, !line.isEmpty { return line }
        return "hermes cron \(verb) failed (exit \(exitCode))."
    }

    /// Remove the job with `id` and save.
    @discardableResult
    public func delete(id: String) async -> Bool {
        let updated = jobs.filter { $0.id != id }
        guard updated.count != jobs.count else { return false }
        return await saveJobs(updated)
    }

    /// Add a new job or replace an existing one with matching id.
    @discardableResult
    public func upsert(_ job: HermesCronJob) async -> Bool {
        var updated = jobs
        if let idx = updated.firstIndex(where: { $0.id == job.id }) {
            updated[idx] = job
        } else {
            updated.append(job)
        }
        return await saveJobs(updated)
    }

    // MARK: - Internal

    /// Shared persistence path: serialize `CronJobsFile` as pretty
    /// JSON, write it atomically through the transport, and update
    /// the in-memory list on success.
    private func saveJobs(_ newJobs: [HermesCronJob]) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        lastError = nil
        let ctx = context
        let path = ctx.paths.cronJobsJSON

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let file = CronJobsFile(jobs: newJobs, updatedAt: iso.string(from: Date()))

        let ok: Bool = await Task.detached {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(file)
                let transport = ctx.makeTransport()
                // Ensure the cron/ directory exists — on a fresh
                // Hermes install this file won't be present.
                // `createDirectory` is mkdir -p across all transports;
                // call unconditionally and let writeFile surface any
                // real failure.
                let parent = (path as NSString).deletingLastPathComponent
                try? transport.createDirectory(parent)
                try transport.writeFile(path, data: data)
                return true
            } catch {
                return false
            }
        }.value

        isSaving = false
        if ok {
            jobs = Self.sorted(newJobs)
            return true
        } else {
            lastError = "Couldn't save jobs.json — check the connection and try again."
            return false
        }
    }

    /// Sort: enabled first, then by `nextRunAt` ascending (nil last,
    /// then by name). Matches the Mac app's list rendering.
    private static func sorted(_ jobs: [HermesCronJob]) -> [HermesCronJob] {
        jobs.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled }
            switch (lhs.nextRunAt, rhs.nextRunAt) {
            case (let l?, let r?): return l < r
            case (_?, nil):        return true
            case (nil, _?):        return false
            case (nil, nil):       return lhs.name < rhs.name
            }
        }
    }

    public enum LoadError: Error, LocalizedError {
        case missingFile(path: String)

        public var errorDescription: String? {
            switch self {
            case .missingFile(let p): return "No cron jobs defined (\(p) doesn't exist yet)"
            }
        }
    }
}

