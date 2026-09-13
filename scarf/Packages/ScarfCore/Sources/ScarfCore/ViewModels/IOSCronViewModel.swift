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

    /// The exact bytes `load()` last saw on the host — the baseline every
    /// save is checked against.
    ///
    /// iOS rewrites `cron/jobs.json` WHOLE from the in-memory list, and the
    /// list can be minutes old (a phone that slept, a sheet left open) while
    /// Hermes has been writing `next_run_at` / `last_run_at` / `state` into
    /// the same file on every tick. Without a baseline the save silently
    /// clobbers all of it. With one, a changed file stops the write and asks
    /// for a reload — the same "never write over what you didn't read"
    /// rule `saveRegistry` enforces for `projects.json`.
    private var baseline: Data?

    /// Mirrored from the capability store by `CronListView`, exactly as the
    /// Mac's `CronView` mirrors them onto `CronViewModel`. Defaults are the
    /// pre-floor posture: refuse nothing locally, offer no re-arm, let the
    /// CLI decide — the same default the Mac VM carries.
    public var isV0206OrLater = false
    public var isV021OrLater = false
    public var isV0181OrLater = false

    /// What Scarf may offer this job. Delegates to the SAME model function
    /// the Mac's `CronViewModel.recoveryOffer(for:)` calls, so both
    /// platforms make an identical offer for an identical job and host
    /// (`HermesCronJob.recoveryOffer(hostRefusesTerminalJobs:hostRecoversErrorRecurring:hostRefusesPastOneShotResume:now:)`).
    public func recoveryOffer(for job: HermesCronJob, now: Date = Date()) -> CronRecoveryOffer {
        job.recoveryOffer(
            hostRefusesTerminalJobs: isV0206OrLater,
            hostRecoversErrorRecurring: isV021OrLater,
            hostRefusesPastOneShotResume: isV0181OrLater,
            now: now
        )
    }

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
        let result: Result<(CronJobsFile, Data), Error> = await ScarfMon.measureAsync(.diskIO, "ios.cron.load") {
            await Task.detached {
                do {
                    guard let data = ctx.readData(path) else {
                        throw LoadError.missingFile(path: path)
                    }
                    let decoded = try JSONDecoder().decode(CronJobsFile.self, from: data)
                    return .success((decoded, data))
                } catch {
                    return Result<(CronJobsFile, Data), Error>.failure(error)
                }
            }.value
        }

        switch result {
        case .success(let (file, data)):
            jobs = Self.sorted(file.jobs)
            // Every save from here on is checked against exactly these
            // bytes; a failed/absent load leaves it nil, which means
            // "we have no baseline" and blocks the whole-file rewrite.
            baseline = data
            isLoading = false

        case .failure(let err as LoadError):
            // Missing jobs.json is the common case on a fresh Hermes
            // install — don't surface as an error, show an empty
            // list + hint in the UI.
            if case .missingFile = err {
                jobs = []
                // No file → nothing to clobber; an empty baseline is the
                // truthful one and a first write is allowed.
                baseline = Data()
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
    /// carries the full upstream semantics — `resume_job`
    /// (`cron/jobs.py:1986-2003` @ v2026.9.7) recomputes `next_run_at` from now and refuses a
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

        // ONE gate, the shared offer — nothing ahead of it. Until P38 a
        // `oneShotIsUnresumable` pre-check ran FIRST, and because that
        // predicate is true for every terminal one-shot it swallowed the
        // whole `offer.canRearm` branch below: iOS said "duplicate it" where
        // the Mac said "Resume & Run Now" for the same job on the same host.
        // The past-deadline rule now lives inside
        // `HermesCronJob.recoveryOffer` as its third door, so both platforms
        // (and Bots) inherit it from one place.
        //
        // `refusesResume`, not `!canResume`: a healthy ENABLED job gets
        // `CronRecoveryOffer.none`, which carries no resume door either, and
        // `setEnabled` is documented to round-trip such a call rather than
        // refuse it.
        if enabled {
            let offer = recoveryOffer(for: prev, now: now)
            if offer.refusesResume {
                lastToggleRoute = .refused
                lastError = Self.resumeRefusalMessage(prev, offer: offer)
                return false
            }
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
                // `repeat.times` (`mark_job_run` at `cron/jobs.py:2239`
                // calls `_advance_after_run` at `:2266`, which bumps
                // `repeat.completed` at `:2203-2217` @ `v2026.9.7`).
                // Clear it and let
                // Hermes's own loader recompute (see `clearingNextRunAt`).
                next = next.clearingNextRunAt()
            }
            updated[idx] = next
            return await saveJobs(updated)
        }
    }

    /// Round-4 decision 6 — `hermes cron resume <id> --run-now`, the re-arm.
    ///
    /// Until now iOS computed `offer.canRearm` and then told the user to go
    /// to the Mac, which made the whole branch a pointer rather than a door:
    /// `rearm_oneshot` is a CLI call like any other, iOS already shells
    /// `cron resume` over the same transport, and `--run-now` is a bare
    /// switch (`_flag(cron_resume, "--run-now")`,
    /// `hermes_cli/subcommands/cron.py:147` @ `v2026.9.7`) needing no new
    /// grammar. Its floor is `hasCronResumeRunNow` (v0.20.6), already
    /// mirrored onto this VM as `isV0206OrLater` and already folded into
    /// `offer.canRearm`, so this method is unreachable on a host without it.
    ///
    /// There is **no JSON fallback** here, deliberately. `rearm_oneshot`
    /// clears `repeat.completed`, the claims and the schedule and then sets
    /// `next_run_at` (`cron/jobs.py:2036-2055`, `:2072-2075`) — a multi-field
    /// rewrite of a TERMINAL record, which is exactly the state
    /// `_reject_terminal_activation` exists to stop a client from inventing.
    /// If the CLI is unreachable the honest answer is "couldn't", not a
    /// hand-rolled write (C3's spirit: mutations go through the CLI).
    ///
    /// The success copy says "next tick", not "running now": unlike `runNow`
    /// this path never follows up with `cron tick`, so nothing dispatches
    /// until the scheduler wakes. Byte-identical to the Mac's
    /// `CronViewModel.resumeAndRunNow` success line.
    @discardableResult
    public func resumeAndRunNow(id: String, now: Date = Date()) async -> Bool {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return false }
        guard !isSaving else { return false }
        let job = jobs[idx]
        lastError = nil

        // The SHARED offer is the gate, as it is in `setEnabled` — never a
        // locally re-derived "is it a one-shot" test. `canRearm` already
        // encodes both `rearm_oneshot`'s own-schedule guard
        // (`_REARM_RECURRING_ERROR` for anything but `once`,
        // `cron/jobs.py:2040-2042`, `:2065-2066`) and the v0.20.6 floor.
        let offer = recoveryOffer(for: job, now: now)
        guard offer.canRearm else {
            lastToggleRoute = .refused
            lastError = Self.resumeRefusalMessage(job, offer: offer)
            return false
        }

        isSaving = true
        let outcome: CLIOutcome = context.isRemote
            ? await Self.runCronCLI("resume", jobID: id, context: context, extraArgs: ["--run-now"])
            : .unavailable
        isSaving = false

        switch outcome {
        case .succeeded:
            lastToggleRoute = .cli
            await load()
            return true
        case .refused(let message):
            lastToggleRoute = .refused
            lastError = message
            return false
        case .unavailable:
            lastToggleRoute = .refused
            lastError = Self.rearmUnavailableMessage(job)
            return false
        }
    }

    /// Why a re-arm that could not reach the CLI is a refusal, not a
    /// fallback. Named so both the reason and the copy live in one place.
    static func rearmUnavailableMessage(_ job: HermesCronJob) -> String {
        "Couldn't reach hermes on the host to re-arm \"\(job.name)\" — re-arming rewrites a finished job's schedule, which only Hermes may do. Try again, or duplicate the job."
    }

    /// The sentence for a terminal job whose only doors are shut. Mirrors
    /// the Mac's `CronViewModel.terminalRefusalMessage`.
    ///
    /// Round-4 decision 6 changed the `canRearm` arm: it used to point at the
    /// Mac app, because the branch was unreachable on iOS anyway. iOS now has
    /// the door (`resumeAndRunNow(id:)`), so both platforms name the same
    /// affordance for the same job — which is what
    /// `CronRecoveryOfferP30Tests`'s parity test is for.
    public static func terminalRefusalMessage(_ job: HermesCronJob, offer: CronRecoveryOffer) -> String {
        terminalRefusalParts(job, offer: offer).sentence
    }

    /// A refusal as the two pieces it is made of, so a second surface can
    /// reframe the REMEDY without having to reverse-engineer where the
    /// reason ends.
    ///
    /// P53 built ``editorEnabledLockNote`` by trimming the assembled
    /// sentence at its first `" — "`, which is only the seam on the arms
    /// whose reason happens to carry no dash of its own — the past-deadline
    /// one-shot's reason ("… — the one-shot time (…) is in the past …") got
    /// cut in half by its own punctuation. The seam is a field now.
    public struct ResumeRefusal: Sendable, Equatable {
        /// Why the door is shut. Carries no trailing punctuation.
        public let reason: String
        /// What to do about it, ending in a full stop.
        public let remedy: String
        /// The punctuation the two are joined by — an em dash where the
        /// remedy continues the sentence, a full stop where it starts a new
        /// one. Part of the copy, not of the seam.
        public let joiner: String

        public var sentence: String { reason + joiner + remedy }
    }

    static func terminalRefusalParts(
        _ job: HermesCronJob, offer: CronRecoveryOffer
    ) -> ResumeRefusal {
        let state = job.effectiveState == "error" ? "failed" : "finished"
        let lead = "\"\(job.name)\" has \(state) and can't just be resumed"
        if offer.canRearm {
            return ResumeRefusal(
                reason: lead, remedy: "use Resume & Run Now to re-arm it.", joiner: " — ")
        }
        return ResumeRefusal(
            reason: lead,
            remedy: offer.hint ?? CronRecoveryOffer.noFutureOccurrencesHint,
            joiner: ". ")
    }

    /// The sentence for any job whose Resume door the offer just shut —
    /// terminal or merely past its one-shot deadline. One entry point so the
    /// two shapes cannot be wired to the wrong wording again.
    public static func resumeRefusalMessage(_ job: HermesCronJob, offer: CronRecoveryOffer) -> String {
        resumeRefusalParts(job, offer: offer).sentence
    }

    /// The same routing, as pieces.
    static func resumeRefusalParts(
        _ job: HermesCronJob, offer: CronRecoveryOffer
    ) -> ResumeRefusal {
        job.isTerminal
            ? terminalRefusalParts(job, offer: offer)
            : oneShotRefusalParts(job, offer: offer)
    }

    /// The same refusal, worded for the MODAL EDITOR's locked `Enabled`
    /// toggle.
    ///
    /// ``resumeRefusalMessage(_:offer:)`` is written for the list's top
    /// banner, where both of its remedies are one gesture away: "Resume &
    /// Run Now" is in the row's context menu and "duplicate it" is the row's
    /// trailing swipe action (P50b put it there for exactly this reason —
    /// round-5 lesson 4, "a hint that names a remedy is walked like a
    /// button"). Inside the editor sheet NEITHER is reachable: the sheet
    /// covers the list, and its only controls are Cancel and Save. P50b's
    /// footer rendered the banner's sentence there anyway, so the copy named
    /// two gestures the user could not perform without first dismissing the
    /// thing they were reading.
    ///
    /// The cheaper honest answer of the two on offer: keep the REASON, which
    /// is what the footer is for, and point at where the remedy lives rather
    /// than duplicating the row's actions into a sheet toolbar. The reason
    /// clause is taken verbatim from the banner's sentence — one rule, two
    /// framings — by trimming at the em dash or full stop the remedy clause
    /// begins after.
    public static func editorEnabledLockNote(
        _ job: HermesCronJob, offer: CronRecoveryOffer
    ) -> String {
        // The reason is a FIELD, not a prefix guessed at by punctuation:
        // two of the three arms carry an em dash inside their own reason.
        let reason = resumeRefusalParts(job, offer: offer).reason
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if offer.canRearm {
            return reason + ". Close this editor, then press and hold the job to Resume & Run Now."
        }
        return reason + ". Close this editor, then swipe the job to Duplicate it."
    }

    static func oneShotRefusalMessage(
        _ job: HermesCronJob,
        offer: CronRecoveryOffer = .none
    ) -> String {
        oneShotRefusalParts(job, offer: offer).sentence
    }

    static func oneShotRefusalParts(
        _ job: HermesCronJob,
        offer: CronRecoveryOffer
    ) -> ResumeRefusal {
        // Keyed on the same predicate `oneShotIsUnresumable` now uses: a
        // spent one-shot is refused because its record is TERMINAL (Hermes's
        // `_reject_terminal_activation`), not merely because `last_run_at` is
        // set — a re-armed one-shot carries that timestamp and resumes fine.
        if job.isTerminal {
            return ResumeRefusal(
                reason: "\"\(job.name)\" has already finished — a completed one-shot can't be resumed",
                remedy: "Duplicate it to schedule a new run.",
                joiner: ". ")
        }
        let when = job.schedule.runAt.map { CronScheduleFormatter.formatNextRun(iso: $0) } ?? "its scheduled time"
        let lead = "Can't resume \"\(job.name)\" — the one-shot time (\(when)) is in the past and would never fire"
        // Reachable now that the past-deadline rule is a door in the shared
        // offer: `rearm_oneshot` DOES accept this job on a v0.20.6+ host, and
        // `--run-now` is a Mac affordance, so point there rather than telling
        // the user to duplicate a job Hermes can still re-arm.
        if offer.canRearm {
            return ResumeRefusal(
                reason: lead, remedy: "use Resume & Run Now to re-arm it.", joiner: " — ")
        }
        return ResumeRefusal(
            reason: lead,
            remedy: offer.hint ?? CronRecoveryOffer.pastDeadlineOneShotHint,
            joiner: ". ")
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

    /// `extraArgs` carries the flags a verb takes AFTER its positional —
    /// today only `--run-now` on `resume`. The job id stays the last
    /// POSITIONAL, which is what `cron resume` declares
    /// (`hermes_cli/subcommands/cron.py:144-147` @ `v2026.9.7`:
    /// `job_id`, then `--at`, then the `--run-now` switch), and a switch may
    /// follow a positional freely.
    static func runCronCLI(
        _ verb: String,
        jobID: String,
        context: ServerContext,
        extraArgs: [String] = []
    ) async -> CLIOutcome {
        let ctx = context
        return await { () async -> CLIOutcome in
            let result: ProcessResult
            do {
                // Round-6 decision 11: the `async` seam (charter C10).
                result = try await ctx.makeTransport().asyncRunProcess(
                    executable: ctx.paths.hermesBinary,
                    args: ["cron", verb, jobID] + extraArgs,
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
        }()
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

    /// Shared persistence path: serialize `CronJobsFile` as pretty JSON and
    /// publish it through the GUARDED shape, then update the in-memory list.
    ///
    /// This is `cron/jobs.json` — a HERMES-owned file this view model
    /// rewrites whole — so it owes three checks the bespoke version had
    /// none of (P7 addendum):
    ///
    /// 1. **Damage refusal.** A stat-confirmed, twice-failed read means the
    ///    file is there and we can't see it; writing would replace it with
    ///    a list assembled from a read that failed. `GuardedJSONStore`
    ///    refuses.
    /// 2. **Stale-clobber refusal.** The write must be based on the bytes
    ///    we actually loaded. Hermes rewrites this file on every tick
    ///    (`next_run_at`, `last_run_at`, `state`, run claims); an
    ///    hours-old in-memory list would erase all of it. A changed file
    ///    asks for a reload instead.
    /// 3. **`.bak`.** The replaced bytes land in `jobs.json.bak`, so even a
    ///    write we should not have made is recoverable.
    ///
    /// Unknown per-job keys were already safe — `HermesCronJob.extra`
    /// round-trips them — which is why this fix is about WHEN to write, not
    /// what.
    private func saveJobs(_ newJobs: [HermesCronJob]) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        lastError = nil
        let ctx = context
        let path = ctx.paths.cronJobsJSON
        let expected = baseline

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let file = CronJobsFile(jobs: newJobs, updatedAt: iso.string(from: Date()))

        enum SaveOutcome: Sendable { case saved(Data), failed(String) }

        let outcome: SaveOutcome = await Task.detached {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(file)
                let store = GuardedJSONStore(transport: ctx.makeTransport(), label: "jobs.json")
                let inspection = store.inspect(path, maxBytes: ProjectDashboardService.maxJSONBytes)

                let onDisk: Data
                switch inspection.state {
                case .absent:            onDisk = Data()
                case .present:           onDisk = inspection.bytes ?? Data()
                case .quarantined:       onDisk = inspection.bytes ?? Data()
                case .unreadable(let p):
                    return .failed("\(p) exists but couldn't be read — refusing to overwrite it. Check the connection and try again.")
                }
                // A nil baseline means this view model never loaded — the
                // staleness question has no answer, so it isn't asked. The
                // UI always loads before it can offer an edit (`CronListView`
                // has a `.task { load() }`), so this is the direct-construct
                // path in tests, not a route a user can take. The damage
                // refusal and the `.bak` still apply.
                if let expected, onDisk != expected {
                    return .failed("Cron jobs changed on the host since this list was loaded. Pull to refresh so the change isn't overwritten.")
                }
                try store.write(data, to: path, after: inspection)
                return .saved(data)
            } catch {
                return .failed("Couldn't save jobs.json — check the connection and try again.")
            }
        }.value

        isSaving = false
        switch outcome {
        case .saved(let data):
            jobs = Self.sorted(newJobs)
            baseline = data
            return true
        case .failed(let message):
            lastError = message
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

