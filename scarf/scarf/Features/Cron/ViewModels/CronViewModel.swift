import Foundation
import ScarfCore
import AppKit
import os

@Observable
final class CronViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "CronViewModel")
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }


    var jobs: [HermesCronJob] = []
    var selectedJob: HermesCronJob?
    var jobOutput: String?
    var availableSkills: [String] = []
    private(set) var message: String?

    /// How ``message`` should be read. The same string channel carries both
    /// "Resumed" and "Failed: …", and every reader used to paint it one
    /// colour — the Bots pane painted it `ScarfColor.success`, so a routine
    /// that failed to run announced itself in green and then auto-cleared
    /// (go/no-go blocking condition 1, A1-M1/A4-C1). Callers colour by this
    /// instead of sniffing the string, and failures are never auto-cleared.
    enum MessageOutcome: Equatable { case success, failure }
    private(set) var messageOutcome: MessageOutcome = .success

    /// Single write point for the message channel. Success messages keep the
    /// existing three-second auto-clear; failures stay until the user
    /// dismisses them or the next action replaces them.
    func post(_ text: String, outcome: MessageOutcome, autoClearAfter seconds: TimeInterval = 3) {
        message = text
        messageOutcome = outcome
        guard outcome == .success else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            // Only clear the message we posted; a newer one owns the channel.
            guard let self, self.message == text, self.messageOutcome == .success else { return }
            self.message = nil
        }
    }

    /// Explicit dismissal for a sticky failure message.
    func dismissMessage() {
        message = nil
        messageOutcome = .success
    }

    var showCreateSheet = false
    var editingJob: HermesCronJob?
    /// Round-4 decision 5 — the record the Duplicate sheet is pre-filled
    /// from. Deliberately a SEPARATE slot from `editingJob`: the sheet it
    /// drives runs `cron create`, and sharing the edit slot would make one
    /// state carry two different verbs.
    var duplicatingJob: HermesCronJob?
    var isLoading = false
    /// True when `jobs.json` exists but failed to decode — the Cron view
    /// warns instead of silently showing an empty board. (t-aud09)
    var loadDecodeFailed = false

    /// Classified hint for the selected job's `lastError`, computed via
    /// `ACPErrorHint.classify` so cron rows surface the same OAuth-revoked
    /// affordance that ChatView's banner offers. `nil` when the selected
    /// job has no error or the error doesn't match a known pattern — the
    /// detail pane falls back to rendering `lastError` raw.
    var selectedErrorClassification: ACPErrorHint.Classification? {
        guard let job = selectedJob, let lastError = job.lastError, !lastError.isEmpty else { return nil }
        return ACPErrorHint.classify(errorMessage: lastError, stderrTail: "")
    }

    /// Re-entry guard (t-aud24): the VM is cached in `AppCoordinator`, so a
    /// plain section switch reuses it. Skip the SSH re-read when the
    /// file-watcher token is unchanged; a real on-disk change (advanced token),
    /// a `force`, or an in-flight load still proceeds/blocks appropriately.
    @ObservationIgnored private var loadedChangeToken: Date?
    @ObservationIgnored private var hasLoaded = false

    func load(changeToken: Date? = nil, force: Bool = false) {
        if !force, hasLoaded, loadedChangeToken == changeToken { return }
        hasLoaded = true
        loadedChangeToken = changeToken
        isLoading = true
        let svc = fileService
        let selectedID = selectedJob?.id
        Task.detached { [weak self] in
            // Three sync transport ops on remote — keep them off main.
            // v2.8: instrumented so we can see how many SSH RTTs the
            // Cron tab actually costs in captures.
            await ScarfMon.measureAsync(.diskIO, "cron.load") {
                let outcome = svc.loadCronJobsOutcome()
                let jobs = outcome.jobs
                let decodeFailed = outcome.decodeFailed
                let skills = svc.loadSkills().flatMap { $0.skills.map(\.id) }.sorted()
                let refreshed = selectedID.flatMap { id in jobs.first(where: { $0.id == id }) }
                let output = refreshed.flatMap { svc.loadCronOutput(jobId: $0.id) }
                ScarfMon.event(.diskIO, "cron.load.jobs", count: jobs.count)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let previousIDs = Set(self.jobs.map(\.id))
                    self.jobs = jobs
                    // The doctor parse resolves headers against the id
                    // roster (an id may contain spaces), so a roster that
                    // arrives AFTER the doctor run — the cold-launch order,
                    // since both probes start from `onAppear` — would leave
                    // the findings parsed by the weaker `isPlausibleJobID`
                    // fallback. Re-PARSE the doctor's retained stdout against
                    // the new roster rather than re-running the verb: the
                    // roster is the only input that changed, and a re-parse
                    // provably adds no spawn on any host (C1), where the old
                    // `loadDoctor(force:)` did — and was gated on
                    // `hasLoadedDoctorFindings`, which is false at exactly
                    // the moment the cold-launch race needs it.
                    if previousIDs != Set(jobs.map(\.id)) {
                        self.reparseDoctorFindings()
                        // …and re-run the verb itself when it has already
                        // answered on this host. The roster changed because
                        // `jobs.json` changed, so the findings may be
                        // genuinely out of date and not merely mis-keyed —
                        // the file-watcher path depends on this. Gated
                        // exactly as before (C1); the re-parse above is the
                        // part that also covers the cold-launch race, when
                        // this gate is still false.
                        if self.hasLoadedDoctorFindings { self.loadDoctor(force: true) }
                    }
                    self.loadDecodeFailed = decodeFailed
                    self.availableSkills = skills
                    if let refreshed { self.selectedJob = refreshed }
                    if output != nil { self.jobOutput = output }
                    self.isLoading = false
                }
            }
        }
    }

    func selectJob(_ job: HermesCronJob) {
        selectedJob = job
        let svc = fileService
        let jobID = job.id
        Task.detached { [weak self] in
            let output = svc.loadCronOutput(jobId: jobID)
            await MainActor.run { [weak self] in self?.jobOutput = output }
        }
    }

    // MARK: - Run history (Hermes v0.19.0+, `hermes cron runs`)

    /// Durable execution attempts for the selected job. Only loaded when
    /// the (capability-gated) RUN HISTORY disclosure is expanded — the
    /// view gates on `hasCronRuns`, so pre-0.19.0 hosts never issue the call.
    var runHistory: [HermesCronRun] = []
    var isLoadingRunHistory = false
    /// Job id the current `runHistory` belongs to; stale-guard for
    /// selection changes racing a slow (remote) CLI call.
    @ObservationIgnored private var runHistoryJobID: String?

    /// `hermes cron runs <jobID> --limit 20` (text output — no --json in
    /// v0.20; parsed by `HermesCronRunsParser`).
    func loadRunHistory(jobID: String, force: Bool = false) {
        if !force, runHistoryJobID == jobID, !runHistory.isEmpty { return }
        if runHistoryJobID != jobID { runHistory = [] }  // don't flash the previous job's rows
        runHistoryJobID = jobID
        isLoadingRunHistory = true
        let svc = fileService
        let log = logger
        Task.detached { [weak self] in
            let result = svc.runHermesCLISplit(args: HermesCronRunsParser.args(jobID: jobID, limit: 20), timeout: 30)
            let runs = result.exitCode == 0 ? HermesCronRunsParser.parse(text: result.stdout) : []
            if result.exitCode != 0 {
                log.warning("cron runs failed (exit \(result.exitCode)): \(result.stderr.prefix(300))")
            }
            await MainActor.run { [weak self] in
                guard let self, self.runHistoryJobID == jobID else { return }
                self.runHistory = runs
                self.isLoadingRunHistory = false
            }
        }
    }

    // MARK: - Failure incidents (Hermes v0.20.6+, `hermes cron incidents`)

    /// Durable failure incidents across all jobs. Only loaded when the
    /// (capability-gated) INCIDENTS disclosure is expanded — pre-0.20.6
    /// hosts never issue the call and render the pane byte-identically.
    var incidents: [HermesCronIncident] = []
    var isLoadingIncidents = false
    /// Set only after a run that actually produced a listing. A failed
    /// invocation (missing binary, SSH drop, host mid-upgrade) must stay
    /// retryable — memoizing it would leave the row badges permanently
    /// blank with no way back short of an app restart.
    @ObservationIgnored private var hasLoadedIncidents = false
    /// A `loadIncidents(force:)` that arrived mid-flight. See
    /// `doctorRefreshPending`.
    @ObservationIgnored private var incidentsRefreshPending = false

    /// Whether `cron incidents` has ever answered on this host. Same
    /// gate rationale as `hasLoadedDoctorFindings`.
    var hasLoadedIncidentList: Bool { hasLoadedIncidents }

    /// Open (un-acked) incidents for one job — drives the row badge.
    func openIncidentCount(jobID: String) -> Int {
        incidents.filter { $0.jobID == jobID && $0.isOpen }.count
    }

    /// Eager (not disclosure-gated) on purpose: the open-incident count
    /// drives an always-visible per-row badge, so the listing has to be in
    /// hand before the user expands anything.
    func loadIncidents(force: Bool = false) {
        if !force, hasLoadedIncidents { return }
        if isLoadingIncidents {
            // Coalesce rather than drop (same reasoning as `loadDoctor`):
            // the in-flight probe predates the mutation the caller is
            // refreshing for, so silently returning left a stale listing.
            if force { incidentsRefreshPending = true }
            return
        }
        isLoadingIncidents = true
        let svc = fileService
        let log = logger
        Task.detached { [weak self] in
            let result = svc.runHermesCLISplit(args: HermesCronIncidentsParser.listArgs(), timeout: 30)
            let ok = result.exitCode == 0
            let parsed = ok ? HermesCronIncidentsParser.parse(text: result.stdout) : []
            if !ok {
                log.warning("cron incidents failed (exit \(result.exitCode)): \(result.stderr.prefix(300))")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.incidents = parsed
                    self.hasLoadedIncidents = true
                }
                self.isLoadingIncidents = false
                if self.incidentsRefreshPending {
                    self.incidentsRefreshPending = false
                    self.loadIncidents(force: true)
                }
            }
        }
    }

    /// `hermes cron incidents ack <id>` **exits 0 on the miss path**: when
    /// `ack_incident` returns falsy the CLI prints "Incident <id> not found
    /// or already closed." in yellow and still returns 0
    /// (`hermes_cli/cron.py::cron_incidents`, v2026.9.7 :272-290 — the miss
    /// branch prints at :287 and still falls through to `return 0`).
    /// Exit code alone would report a
    /// no-op as a success, so the output text is the discriminator.
    static func ackOutcomeMessage(exitCode: Int32, output: String) -> String {
        guard exitCode == 0 else { return "Couldn't acknowledge: \(output.prefix(160))" }
        if output.contains("not found or already closed") {
            return "That incident was already closed (or no longer exists)."
        }
        return "Incident acknowledged"
    }

    func ackIncident(_ incident: HermesCronIncident) {
        let svc = fileService
        Task.detached { [weak self] in
            let result = svc.runHermesCLI(args: HermesCronIncidentsParser.ackArgs(incidentID: incident.id), timeout: 30)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.post(
                    Self.ackOutcomeMessage(exitCode: result.exitCode, output: result.output),
                    outcome: result.exitCode == 0 ? .success : .failure
                )
                self.loadIncidents(force: true)
            }
        }
    }

    // MARK: - Health check (Hermes v0.21+, `hermes cron doctor`)

    /// `jobID → finding`, so a list/detail row can show a warning inline
    /// instead of pushing the user into a separate pane.
    var doctorFindings: [String: HermesCronDoctorFinding] = [:]
    @ObservationIgnored private var hasLoadedDoctor = false

    /// Whether `cron doctor` has ever answered on this host. Gates the
    /// post-mutation refresh: a host without the verb must not gain a
    /// spawn it never made before (C1).
    var hasLoadedDoctorFindings: Bool { hasLoadedDoctor }
    @ObservationIgnored private(set) var isLoadingDoctor = false

    /// Raw `cron doctor` stdout from the last run that produced recognizable
    /// output. Retained so the findings can be re-parsed against a roster
    /// that lands later WITHOUT re-spawning the verb — see `load`.
    @ObservationIgnored private var doctorOutput: String?
    /// A `loadDoctor(force:)` that arrived while a run was already in flight.
    /// The early return alone silently dropped it, so a post-mutation refresh
    /// that raced the initial run left the findings describing the job as it
    /// was BEFORE the edit — the very staleness
    /// `refreshDiagnosticsAfterMutation` exists to fix.
    @ObservationIgnored private var doctorRefreshPending = false

    /// Adopt one `cron doctor` run's raw stdout. Split out of `loadDoctor`'s
    /// completion so the roster-ordering contract can be driven without a
    /// CLI seam; production has exactly one caller.
    func adoptDoctorOutput(_ stdout: String) {
        doctorOutput = stdout
        hasLoadedDoctor = true
        reparseDoctorFindings()
    }

    /// Re-parse the retained `cron doctor` output against the CURRENT job
    /// roster. No spawn, no capability surface: a host that never ran the
    /// verb has no retained output and this is a no-op.
    func reparseDoctorFindings() {
        guard let doctorOutput else { return }
        doctorFindings = HermesCronDoctorParser.parse(
            text: doctorOutput, knownJobIDs: Set(jobs.map(\.id)))
    }

    func loadDoctor(force: Bool = false) {
        if !force, hasLoadedDoctor { return }
        if isLoadingDoctor {
            // Coalesce rather than drop: the in-flight run was started
            // before whatever the caller just changed.
            if force { doctorRefreshPending = true }
            return
        }
        isLoadingDoctor = true
        let svc = fileService
        let log = logger
        Task.detached { [weak self] in
            // `cron doctor` exits 1 when it FINDS issues — that's the
            // normal path, not a failure, so the exit code can't be the
            // success signal. `looksLikeDoctorOutput` checks for one of
            // the two sentinels the command always prints; anything else
            // (argparse error, traceback, empty) is a failed run and stays
            // retryable rather than being memoized as "no findings".
            let result = svc.runHermesCLISplit(args: HermesCronDoctorParser.args(), timeout: 30)
            let ok = HermesCronDoctorParser.looksLikeDoctorOutput(result.stdout)
            let stdout = result.stdout
            if !ok {
                log.warning("cron doctor produced unrecognized output (exit \(result.exitCode)): \(result.stderr.prefix(300))")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    // The doctor header is `  {id} {name}` and a job id may
                    // itself contain spaces, so the parse needs the roster to
                    // know where the id ends. Parse HERE, against whatever
                    // roster is current now, so the re-parse fires whichever
                    // of `load()` / `loadDoctor()` finishes second — parsing
                    // against a pre-hop snapshot lost every roster that
                    // landed during the run.
                    self.adoptDoctorOutput(stdout)
                }
                self.isLoadingDoctor = false
                if self.doctorRefreshPending {
                    self.doctorRefreshPending = false
                    self.loadDoctor(force: true)
                }
            }
        }
    }

    // MARK: - CLI wrappers

    func pauseJob(_ job: HermesCronJob) {
        runAndReload(["cron", "pause", job.id], success: "Paused", job: job)
    }

    /// Set by `CronView` from the capability store (`hasCronResumeRunNow`
    /// / `hasCronIncidents` / … all resolve to `isV0206OrLater`). It gates
    /// the terminal-job pre-check as well as the `--run-now` affordance —
    /// the VM has no capability store of its own.
    ///
    /// **Why the pre-check is gated.** The terminal guards Scarf is
    /// short-circuiting are a v0.20.6 addition: at tag `v2026.8.19`
    /// (v0.20.5) neither `update_job` nor `trigger_job` refuses a
    /// completed/error job, so those hosts happily resume one. Refusing
    /// client-side there would deny an operation the host would have
    /// accepted — worse than the Python tail this pre-check exists to
    /// avoid. On such a host we let the CLI decide.
    var isV0206OrLater = false

    /// Set by `CronView` from `hasCronCreatePaused` (v0.21.1). Gates the
    /// one-shot pre-check below: only a v0.21.1 host REJECTS a past one-shot
    /// (`cron/jobs.py::_next_run_or_reject_past_oneshot`, v2026.9.7 :1669,
    /// reached from `create_job` :1758) — an older one
    /// stores it, and refusing locally there would deny a write the host
    /// would have accepted. Same rule as `isV0206OrLater`.
    var isV0211OrLater = false

    /// Set by `CronView` from `hasCronRecoverableErrorResume` (v0.21.0).
    /// Hermes exempts a RECURRING job in `state = "error"` from the terminal
    /// block (`_reject_terminal_activation`'s `and not
    /// _is_recoverable_error_job(job)`, `cron/jobs.py:1865-1878` @
    /// `v2026.9.7`), so plain `cron resume` recovers it — but only from
    /// v0.21.0 on (`:2367-2375` @ `v2026.8.27` has no exemption).
    var isV021OrLater = false

    /// Set by `CronView` from `hasCronPastOneShotResumeRefusal` (v0.18.1).
    /// Gates `recoveryOffer`'s third door: `resume_job` refuses a past
    /// one-shot only from v0.18.1 on (`cron/jobs.py:1991-1996` @ `v2026.9.7`,
    /// sentence absent at `v2026.7.1`), so on an older host Scarf keeps
    /// offering plain Resume and lets the CLI decide.
    var isV0181OrLater = false

    /// What Scarf may offer this job — the shared, cross-platform answer.
    /// `IOSCronViewModel.recoveryOffer(for:)` computes the same thing from
    /// the same model function, so the two platforms cannot diverge.
    func recoveryOffer(for job: HermesCronJob, now: Date = Date()) -> CronRecoveryOffer {
        job.recoveryOffer(
            hostRefusesTerminalJobs: isV0206OrLater,
            hostRecoversErrorRecurring: isV021OrLater,
            hostRefusesPastOneShotResume: isV0181OrLater,
            now: now
        )
    }

    /// Should Scarf refuse a terminal-job **run** locally instead of
    /// round-tripping to the CLI? Only when the host is new enough to
    /// refuse it too.
    ///
    /// This stays the BARE `is_terminal_job` test on purpose: `trigger_job`
    /// checks `is_terminal_job(job)` with no recoverable-error exemption
    /// (`cron/jobs.py:2012` @ `v2026.9.7`), unlike the `update_job` door
    /// resume goes through. A recurring job in `error` is therefore
    /// resumable and NOT runnable, and the two gates must not be shared.
    func refusesTerminalJobLocally(_ job: HermesCronJob) -> Bool {
        isV0206OrLater && job.isTerminal
    }

    func resumeJob(_ job: HermesCronJob) {
        // Since v0.20.6 `update_job` refuses to re-activate a
        // completed/error job ("Cannot activate terminal cron job …",
        // `cron/jobs.py::_reject_terminal_activation`, v2026.9.7 :1865-1878,
        // armed from `update_job` :1941/:1965), and `resume_job` (:1986)
        // funnels through it.
        // Catch it before the CLI round-trip so the user gets the
        // actionable sentence instead of a Python ValueError tail.
        //
        // `offer.refusesResume`, not `job.isTerminal && !canResume`: the
        // offer's third door refuses a merely PAST-DEADLINE one-shot too
        // (`resume_job` raises before `update_job` is reached, `:1991-1996`),
        // and that shape is not terminal — so the old condition let it
        // through to the CLI and the user got the raw Python tail. `.none`
        // (a healthy running job) is deliberately not a refusal.
        let offer = recoveryOffer(for: job)
        if offer.refusesResume {
            post(Self.resumeRefusalMessage(job, offer: offer), outcome: .failure)
            return
        }
        runAndReload(["cron", "resume", job.id], success: "Resumed", job: job)
    }

    /// `hermes cron resume <id> --run-now` (v0.20.6+) — the documented
    /// escape hatch for a **one-shot**: re-arms it to fire at the next
    /// scheduler tick rather than at its (spent) schedule.
    ///
    /// **One-shot-only.** `rearm_oneshot` re-checks the job's own schedule
    /// inside `apply` and raises `_REARM_RECURRING_ERROR` for anything but
    /// `once` (`cron/jobs.py:2040-2042`, `:2065-2066` @ `v2026.9.7`), which
    /// `cron_resume` turns into exit 1 (`hermes_cli/cron.py:691-695`).
    /// Callers gate on `recoveryOffer(for:).canRearm`, never on
    /// "the job is paused".
    ///
    /// The success copy says "next tick", not "running now": `rearm_oneshot`
    /// only sets `next_run_at` to now and returns (`cron/jobs.py:2055`,
    /// `:2072-2075`), and unlike `runNow` this path does not follow up with
    /// `cron tick` — nothing dispatches until the scheduler wakes.
    func resumeAndRunNow(_ job: HermesCronJob) {
        runAndReload(["cron", "resume", job.id, "--run-now"],
                     success: "Re-armed — will run at the next scheduler tick",
                     job: job)
    }

    /// Only reachable on a v0.20.6+ host — the generation that has the
    /// `--run-now` escape hatch — so the wording may name it, but ONLY when
    /// the offer actually includes it: naming a button that
    /// `_REARM_RECURRING_ERROR` would refuse is the dead end this phase
    /// removed.
    static func terminalRefusalMessage(_ job: HermesCronJob, offer: CronRecoveryOffer) -> String {
        let state = job.effectiveState == "error" ? "failed" : "finished"
        let lead = "\"\(job.name)\" has \(state) and can't just be resumed"
        if offer.canRearm {
            return lead + " — use Resume & Run Now to re-arm it."
        }
        return lead + ". " + (offer.hint ?? CronRecoveryOffer.noFutureOccurrencesHint)
    }

    /// The sentence for ANY job whose Resume door the offer shut — terminal,
    /// or a one-shot merely past its deadline. The iOS twin is
    /// `IOSCronViewModel.resumeRefusalMessage`; both take the same two shapes
    /// so the two platforms cannot word the same refusal differently.
    static func resumeRefusalMessage(_ job: HermesCronJob, offer: CronRecoveryOffer) -> String {
        guard !job.isTerminal else { return terminalRefusalMessage(job, offer: offer) }
        let when = job.schedule.runAt.map { CronScheduleFormatter.formatNextRun(iso: $0) }
            ?? "its scheduled time"
        let lead = "Can't resume \"\(job.name)\" — the one-shot time (\(when)) is in the past and would never fire"
        if offer.canRearm {
            return lead + " — use Resume & Run Now to re-arm it."
        }
        return lead + ". " + (offer.hint ?? CronRecoveryOffer.pastDeadlineOneShotHint)
    }

    /// The verdict on `hermes cron run <id>`, judged by what it printed.
    ///
    /// `_job_action` (hermes_cli/cron.py:635-663 at v2026.9.7) returns 0 for a
    /// run that FAILED: it prints the green `Triggered job: <name> (<id>)`
    /// line (:658, verb from `_JOB_ACTIONS`, :763) and then `_run_outcome`'s
    /// verdict (:662), which for a synchronous failure is
    /// `  Ran now: failed.` (:677) — and still `return 0`. So this is the one
    /// site where a failure marker must beat a success marker that is also
    /// present. `Ran now:` first appears at v2026.7.1:411, so on a v0.17 host
    /// the marker never fires and the verdict is unchanged (charter C1).
    static func runOutcome(exitCode: Int32, output: String) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.cronRunSuccess,
            failureMarkers: HermesCLIMarkers.cronRunFailure,
            failureWins: true,
            // `_job_action` prints it at column 0 (cron.py:658).
            successAnchored: true
        )
    }

    /// Translate the Hermes terminal-job refusals into one plain sentence.
    /// Both `update_job` ("Cannot activate terminal cron job") and
    /// `trigger_job` ("Cannot run: … is completed (terminal)") land here
    /// via `runAndReload`/`runNow` when the pre-check above is bypassed
    /// (e.g. a job that turned terminal between load and click).
    ///
    /// `offer` is the job's `recoveryOffer` where the caller knows which job
    /// it ran for. It has to be: `rearm_oneshot` raises
    /// `_REARM_RECURRING_ERROR` for anything but `kind == "once"`
    /// (`cron/jobs.py:2040-2042`, `:2065-2066` @ `v2026.9.7`), so naming
    /// "Resume & Run Now" unconditionally sent every recurring job to a
    /// guaranteed exit 1 — the dead end P30 removed from the buttons and left
    /// standing in this sentence.
    static func friendlyCronFailure(
        _ output: String,
        offer: CronRecoveryOffer? = nil
    ) -> String? {
        if output.contains("Cannot activate terminal cron job")
            || (output.contains("(terminal)") && output.contains("Cannot run")) {
            // Three arms, because there are three things Scarf can know.
            //
            // `offer.canRearm` already folds the host floor
            // (`hasCronResumeRunNow`, v0.20.6) together with
            // `rearm_oneshot`'s own-schedule guard — it raises
            // `_REARM_RECURRING_ERROR` for anything but `once`
            // (`cron/jobs.py:2040-2042`, `:2065-2066` @ `v2026.9.7`, exit 1
            // through `cron_resume`, `hermes_cli/cron.py:691-695`) — so it is
            // the predicate to key on, not "the job is terminal".
            //
            // With NO offer (the `cron edit` race: the record turned terminal
            // between load and click, so `jobs.first { $0.id == id }` came
            // back nil) this used to default to naming "Resume & Run Now"
            // anyway. That is the one arm that can be WRONG in the unsafe
            // direction: it points a recurring job at a button Hermes
            // refuses. Assert only what holds for every terminal record —
            // duplicating is an ordinary `cron create`, which no terminal
            // guard touches — and stay silent about a door we cannot prove.
            guard let offer else {
                return String(localized: "That job already finished — duplicate it to schedule a new one.")
            }
            return offer.canRearm
                ? String(localized: "That job already finished — use Resume & Run Now to re-arm it, or duplicate it.")
                : String(localized: "That job already finished and can't be re-armed — duplicate it to schedule a new one.")
        }
        // `rearm_oneshot`'s own two refusal families, both of which used to
        // fall through to the generic `prefix(200)` truncation of raw CLI text.
        //
        // 1. `_REARM_RECURRING_ERROR` (`cron/jobs.py:2040-2042` @ `v2026.9.7`,
        //    raised at `:2054` on the parsed schedule and again at `:2066` on
        //    the stored record) — re-arm is one-shot-only. Exit 1 through
        //    `cron_resume`'s `except (AmbiguousJobReference, ValueError)`
        //    (`hermes_cli/cron.py:693-695`). Reachable when the offer was
        //    computed against a record that has since been edited to a
        //    recurring schedule.
        if output.contains("Cannot re-arm recurring jobs") {
            return String(localized: "Re-arm is for one-shot jobs only — this one repeats. Use Resume, or Run Now for a single extra run.")
        }
        // 2. The live-claim refusals (`:2061-2064`): `_claim_is_live`
        //    (`:2031-2037`) is true only for a well-formed claim aged within
        //    `[0, ttl)` — a run claim's TTL is at least 1800s
        //    (`ONESHOT_RUN_CLAIM_TTL_SECONDS = 1800`, `:154`, which
        //    `_oneshot_run_claim_ttl_seconds` applies as a FLOOR:
        //    `max(timeout * 3, 1800)`, `:174`; the 600 nearby is
        //    `_DEFAULT_CRON_INACTIVITY_TIMEOUT`, `:161`, an inactivity limit,
        //    not the TTL) and a fire claim's
        //    is `FIRE_CLAIM_TTL_SECONDS = 300` (`:891`) — and a future-dated
        //    or malformed claim counts as STALE so it can never wedge a job.
        //    So the remedy really is "wait": the claim goes when the run
        //    clears it, and lapses on its own if the run dies. Verified
        //    against the claim logic before naming it.
        if output.contains("Cannot re-arm one-shot over a live") {
            return String(localized: "That job has a run in progress — try again after it finishes.")
        }
        // v0.21.1 (A9): the cron lifecycle guard refuses a `--script` that
        // lives on a cloud-synced FileProvider path WITHOUT opening it
        // (`cron/lifecycle_guard.py:981-994`), and the same wording covers
        // the older gateway-lifecycle refusal. Both sentences END in the
        // remedy, so the generic `prefix(200)` truncation would cut off
        // exactly the actionable half — hand back the whole sentence.
        if let blocked = blockedSentence(in: output) { return blocked }
        // v0.21.1 (A8): `create_job` rejects a past one-shot outright
        // (`_oneshot_past_grace_error`). Reachable when the create-sheet
        // pre-check couldn't decide (a naive timestamp, or an older host's
        // job edited into the past).
        if output.contains("cannot be scheduled"), output.contains("in the past") {
            return "That one-shot time is already in the past — pick a future time."
        }
        return nil
    }

    /// The full `Blocked: …` sentence Hermes printed, verbatim, or `nil`.
    ///
    /// The CLI prints it as `Failed to create job: Blocked: …` on STDOUT
    /// (`hermes_cli/cron.py::cron_create`, v2026.9.7 :578-580) — not stderr —
    /// because the guard's
    /// `ValueError` is caught by `tools/cronjob_tools.py::cronjob` and
    /// returned as a JSON `error` payload. `runHermesCLI` merges both
    /// streams, so matching on the text is what works either way.
    static func blockedSentence(in output: String) -> String? {
        guard let start = output.range(of: "Blocked: ") else { return nil }
        let rest = output[start.lowerBound...]
        let line = rest.prefix { $0 != "\n" }
        return line.trimmingCharacters(in: .whitespaces)
    }

    func runNow(_ job: HermesCronJob) {
        // `hermes cron run <id>` only marks the job as due on the next
        // scheduler tick — it doesn't actually execute. If the Hermes
        // gateway's scheduler isn't running (common during dev + right
        // after install), the user's "Run now" click results in zero
        // visible effect because the tick never comes. We follow up
        // with `hermes cron tick` which runs all due jobs once and
        // exits. Redundant-but-harmless when the gateway is running;
        // the actual trigger when it isn't.
        //
        // Feedback model: show a "Agent started" toast as soon as
        // `cron run` succeeds, WITHOUT waiting for `cron tick` to
        // return. Agent jobs routinely run past a minute (network IO +
        // an LLM call + a file rewrite), and earlier versions with a
        // 60s tick timeout surfaced a misleading "Run failed" toast
        // every time while the job kept running in the background.
        // The app's HermesFileWatcher picks up the dashboard.json
        // rewrite that the agent lands at the end — that's what the
        // user actually watches for, not this toast.
        // `trigger_job` refuses terminal jobs outright
        // (`cron/jobs.py::trigger_job`, v2026.9.7 :2012-2017)
        // — but only from v0.20.6 on; see `refusesTerminalJobLocally`.
        if refusesTerminalJobLocally(job) {
            post(Self.terminalRefusalMessage(job, offer: recoveryOffer(for: job)), outcome: .failure)
            return
        }
        let svc = fileService
        let jobID = job.id
        let offer = recoveryOffer(for: job)
        Task.detached { [weak self] in
            let runResult = svc.runHermesCLI(args: ["cron", "run", jobID], timeout: 30)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let outcome = Self.runOutcome(
                    exitCode: runResult.exitCode,
                    output: runResult.output
                )
                if !outcome.succeeded {
                    self.post(
                        Self.friendlyCronFailure(runResult.output, offer: offer)
                            ?? outcome.detail
                            ?? "Run failed to queue: \(runResult.output.prefix(200))",
                        outcome: .failure
                    )
                    self.logger.warning("cron run failed: \(runResult.output)")
                    self.load(force: true)
                    return
                }
                self.post("Agent started — dashboard will update when it finishes", outcome: .success)
                self.load(force: true)
            }
            // `cron run` is queued; now force the tick. The 300s
            // timeout catches truly stuck processes without killing
            // the long-but-valid agent case that blew up the 60s
            // version. A timeout here is survivable — the Hermes
            // scheduler re-runs due jobs on its own cadence — so we
            // log but don't surface it as a failure toast.
            try? await Task.sleep(for: .milliseconds(250))
            let tickResult = svc.runHermesCLI(args: ["cron", "tick"], timeout: 300)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if tickResult.exitCode != 0 {
                    self.logger.warning("cron tick exited non-zero (job may still complete via scheduler): \(tickResult.output)")
                }
                self.load(force: true)
            }
        }
    }

    func deleteJob(_ job: HermesCronJob, onOutcome: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        runAndReload(["cron", "remove", job.id], success: "Removed", job: job, onOutcome: onOutcome)
        if selectedJob?.id == job.id {
            selectedJob = nil
            jobOutput = nil
        }
    }

    func createJob(schedule: String, prompt: String, name: String, deliver: String, skills: [String], script: String, repeatCount: String, workdir: String = "", noAgent: Bool = false, failureDeliver: String = "", onOutcome: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        // A8 (v0.21.1): Hermes rejects a one-shot whose `run_at` is past the
        // grace window with a non-zero exit. Say so before the round-trip —
        // and only on a host that would actually refuse (see `isV0211OrLater`).
        if isV0211OrLater, HermesCronJob.oneShotScheduleIsPastGrace(schedule) {
            post(
                "That one-shot time is already in the past (more than \(Int(HermesCronJob.oneShotGraceSeconds))s) — pick a future time.",
                outcome: .failure
            )
            onOutcome?(false)
            return
        }
        runAndReload(
            Self.createJobArguments(
                schedule: schedule, prompt: prompt, name: name, deliver: deliver,
                skills: skills, script: script, repeatCount: repeatCount,
                workdir: workdir, noAgent: noAgent, failureDeliver: failureDeliver
            ),
            success: "Job created",
            onOutcome: onOutcome
        )
    }

    /// The exact argv `createJob` runs. Split out (not duplicated) so callers
    /// that compose a create — and the tests that pin their composition —
    /// assert the PRODUCTION command line rather than a parallel builder that
    /// can drift from it.
    nonisolated static func createJobArguments(schedule: String, prompt: String, name: String, deliver: String, skills: [String], script: String, repeatCount: String, workdir: String = "", noAgent: Bool = false, failureDeliver: String = "") -> [String] {
        var args = ["cron", "create"]
        if !name.isEmpty { args.append(HermesCLIOption.joined("--name", name)) }
        if !deliver.isEmpty { args.append(HermesCLIOption.joined("--deliver", deliver)) }
        // v0.21.1 `--failure-deliver`. The caller (CronView) clears the form
        // value on a host without `hasCronFailureDeliver`, so the unknown flag
        // is never emitted — argparse would fail the whole create.
        if !failureDeliver.isEmpty { args.append(HermesCLIOption.joined("--failure-deliver", failureDeliver)) }
        if !repeatCount.isEmpty { args.append(HermesCLIOption.joined("--repeat", repeatCount)) }
        for skill in skills where !skill.isEmpty { args.append(HermesCLIOption.joined("--skill", skill)) }
        if !script.isEmpty { args.append(HermesCLIOption.joined("--script", script)) }
        // v0.12+: --workdir injects AGENTS.md/CLAUDE.md context and pins
        // cwd for terminal/file/code_exec tools. Hermes pre-v0.12 doesn't
        // know the flag — argparse rejects unknown args, so the form
        // omits the flag when the field is empty.
        if !workdir.isEmpty { args.append(HermesCLIOption.joined("--workdir", workdir)) }
        // v0.13+: --no-agent runs the pre-run script and skips the AI turn.
        // Caller (CronView) strips this on pre-v0.13 hosts so the flag is
        // never emitted to a Hermes that can't parse it.
        if noAgent { args.append("--no-agent") }
        // End-of-options before the positionals (`schedule`, optional
        // `prompt`). A prompt that legitimately opens with a dash —
        // "--deliver isn't working, investigate" — is otherwise claimed by
        // argparse as an option and the create dies at exit 2. `--` must
        // come after every flag: argparse reads every later token as a
        // positional. (HermesPeerCLI.dmArgs is the precedent.)
        args.append("--")
        args.append(schedule)
        if noAgent {
            args.append("")
        } else if !prompt.isEmpty {
            args.append(prompt)
        }
        return args
    }

    /// The `--clear-skills` / `--add-skill` / `--remove-skill` tail of a
    /// `cron edit`, given the job's stored skills and the set the editor
    /// is saving.
    ///
    /// **Why a diff and not just `--skill`.** `cron edit`'s skill flags are
    /// resolved by `hermes_cli/cron.py::cron_edit` (v2026.9.7 :606-618):
    /// `_normalize_skills` returns **None** for an empty/absent `--skill`
    /// list, and `final_skills` stays `None` unless `--clear-skills`, a
    /// non-empty replacement, or an add/remove pair is present — a `None`
    /// is then passed straight through to `update_job`, which leaves the
    /// field untouched. So "the user unticked every skill" and "the user
    /// didn't touch skills" were the SAME argv: sending zero `--skill`
    /// flags silently kept the job's existing skills.
    ///
    /// An empty target set therefore has to be spelled `--clear-skills`.
    /// For a non-empty one we send the DIFF rather than a full `--skill`
    /// replacement: replacement is computed against the form's snapshot,
    /// so a skill added to the job between load and save would be wiped,
    /// while `--add-skill`/`--remove-skill` are applied against the
    /// `existing_skills` Hermes reads at edit time (:606).
    ///
    /// Ungated. All three flags are `cron edit` arguments from **v0.3.0**
    /// (`hermes_cli/main.py:2854-2857` at tag `v2026.3.17`; absent at
    /// `v2026.3.12`/v0.2.0), moved to `hermes_cli/subcommands/cron.py:98-104`
    /// by the v0.17 modularisation and unchanged at `v2026.9.7`. That is
    /// below Scarf's minimum supported Hermes (v0.6.0), so there is no
    /// host generation that could reject them and nothing to gate on.
    nonisolated static func skillEditArguments(
        existing: [String], newSkills: [String]?, clearSkills: Bool
    ) -> [String] {
        let existingSet = existing.filter { !$0.isEmpty }
        guard !clearSkills else { return ["--clear-skills"] }
        guard let newSkills else { return [] }   // caller didn't touch skills
        let target = newSkills.filter { !$0.isEmpty }
        if target.isEmpty {
            // Nothing to clear on a job that already has none — sending
            // the flag would be a no-op write.
            return existingSet.isEmpty ? [] : ["--clear-skills"]
        }
        var args: [String] = []
        for skill in existingSet where !target.contains(skill) {
            args.append(HermesCLIOption.joined("--remove-skill", skill))
        }
        for skill in target where !existingSet.contains(skill) {
            args.append(HermesCLIOption.joined("--add-skill", skill))
        }
        return args
    }

    /// The `--prompt` tail of a `cron edit`.
    ///
    /// Same "an emptied field is a real gesture" rule `skillEditArguments`
    /// applies to skills. Hermes's update guard is `if prompt is not None`
    /// (`tools/cronjob_tools.py::_update_core_fields`, v2026.9.7 :689-697),
    /// so `--prompt ""` genuinely CLEARS the prompt — dropping the flag on
    /// an empty string, as this did, made "the user deleted the prompt" and
    /// "the user didn't touch the prompt" the same argv and the job kept
    /// running the old instruction under a success toast.
    ///
    /// Only an ACTUAL emptying is forwarded: `existing` is the value the
    /// editor was seeded with, so a form that opened blank and stayed blank
    /// sends nothing rather than a write. Whether the clear is *accepted* is
    /// Hermes's call — `update_job` refuses a job left with no runnable
    /// payload at all (`cron/jobs.py::job_payload_is_empty` :428-436, armed
    /// at :1949), and that refusal is surfaced verbatim rather than
    /// second-guessed here.
    ///
    /// Ungated. `cron edit --prompt` is registered at Scarf's minimum
    /// supported Hermes v0.6.0 (`hermes_cli/main.py:3943` at tag
    /// `v2026.3.30`), moved to `hermes_cli/subcommands/cron.py:91` by the
    /// v0.17 modularisation and unchanged at `v2026.9.7`.
    nonisolated static func promptEditArguments(existing: String, newValue: String?) -> [String] {
        guard let newValue else { return [] }   // caller didn't touch the prompt
        if newValue.isEmpty {
            return existing.isEmpty ? [] : [HermesCLIOption.joined("--prompt", "")]
        }
        return [HermesCLIOption.joined("--prompt", newValue)]
    }

    /// The `--repeat` tail of a `cron edit`.
    ///
    /// The clear gesture is `--repeat 0`, not an omitted flag:
    /// `normalize_repeat_value` folds `<= 0` to `None` = run forever
    /// (`cron/jobs.py:591-617` at `v2026.9.7`, reached from
    /// `tools/cronjob_tools.py::_update_run_fields` :787-792, whose guard is
    /// `if a["repeat"] is not None` — `0` passes it). Dropping the flag on an
    /// empty string left the old count in place, so a user who cleared
    /// "Repeat" to mean "forever" got "Updated" and a job that still went
    /// terminal after N runs.
    ///
    /// Only an ACTUAL emptying is forwarded, compared against the value the
    /// editor was seeded with (`HermesCronJob.repeatEditValue`) — an
    /// untouched blank field writes nothing.
    ///
    /// Ungated. `cron edit --repeat` is registered at Scarf's minimum
    /// supported Hermes v0.6.0 (`hermes_cli/main.py:3946` at `v2026.3.30`),
    /// moved to `hermes_cli/subcommands/cron.py:97` by the v0.17
    /// modularisation and unchanged at `v2026.9.7`; the `<= 0 -> forever`
    /// fold is present from v0.4.0 (`v2026.3.23`), also below the floor.
    nonisolated static func repeatEditArguments(existing: String, newValue: String?) -> [String] {
        guard let newValue else { return [] }   // caller didn't touch the field
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return existing.isEmpty ? [] : [HermesCLIOption.joined("--repeat", "0")]
        }
        return [HermesCLIOption.joined("--repeat", trimmed)]
    }

    func updateJob(id: String, schedule: String?, prompt: String?, existingPrompt: String, name: String?, deliver: String?, repeatCount: String?, existingRepeatCount: String, existingSkills: [String], newSkills: [String]?, clearSkills: Bool, script: String?, workdir: String? = nil, noAgent: Bool? = nil, failureDeliver: String? = nil) {
        // `job_id` is `cron edit`'s only positional, so it moves to the very
        // end behind `--` — every flag has to precede the marker, since
        // argparse treats each token after it as a positional.
        var args = ["cron", "edit"]
        if let schedule, !schedule.isEmpty { args.append(HermesCLIOption.joined("--schedule", schedule)) }
        args += Self.promptEditArguments(existing: existingPrompt, newValue: prompt)
        if let name, !name.isEmpty { args.append(HermesCLIOption.joined("--name", name)) }
        if let deliver { args.append(HermesCLIOption.joined("--deliver", deliver)) }
        // v0.21.1: `nil` = untouched (omit the flag); `""` is Hermes's own
        // documented "clear the override" gesture on edit, so it is passed
        // through rather than dropped like an empty create value.
        if let failureDeliver { args.append(HermesCLIOption.joined("--failure-deliver", failureDeliver)) }
        args += Self.repeatEditArguments(existing: existingRepeatCount, newValue: repeatCount)
        args += Self.skillEditArguments(
            existing: existingSkills, newSkills: newSkills, clearSkills: clearSkills
        )
        if let script { args.append(HermesCLIOption.joined("--script", script)) }
        // `nil` = caller didn't touch the field (omit the flag). Empty string
        // = user cleared an existing workdir; Hermes documents `--workdir ""`
        // on edit as the explicit clear gesture, mirroring the `--script` shape.
        if let workdir { args.append(HermesCLIOption.joined("--workdir", workdir)) }
        if let noAgent {
            if noAgent { args.append("--no-agent") }
            else { args.append("--agent") }
        }
        args.append(contentsOf: ["--", id])
        // The record `cron edit` addresses, when it is still on screen —
        // so a refusal on a RECURRING job does not name a re-arm
        // `_REARM_RECURRING_ERROR` would refuse.
        runAndReload(args, success: "Updated", job: jobs.first { $0.id == id })
    }

    // MARK: - Private

    /// Re-run the two diagnostic verbs after a job mutation.
    ///
    /// `load(force:)` only re-reads `jobs.json`, so before this the
    /// doctor findings and incident badges kept describing the job as it
    /// was BEFORE the edit — a user who fixed the very thing `cron doctor`
    /// flagged still saw the warning until they left the section.
    ///
    /// Deliberately conditional on each verb having already ANSWERED once
    /// (`hasLoadedDoctorFindings` / `hasLoadedIncidentList`): those are the
    /// capability-gated probes, and a pre-v0.20.6 / pre-v0.21 host that
    /// never ran them must not start spawning them here (C1). It also runs
    /// on the FAILURE path on purpose — a refused edit can still have
    /// changed run state (`cron run` prints a green line and then
    /// `Ran now: failed.`).
    func refreshDiagnosticsAfterMutation() {
        // `|| isLoading…`: a probe in flight is a probe this host ALREADY
        // received, so refreshing behind it adds no spawn a pre-target host
        // would not have made (C1) — and on a cold launch the in-flight run
        // is the only reason `hasLoaded…` is still false. `loadIncidents` /
        // `loadDoctor` coalesce the mid-flight case internally.
        if hasLoadedIncidentList || isLoadingIncidents { loadIncidents(force: true) }
        if hasLoadedDoctorFindings || isLoadingDoctor { loadDoctor(force: true) }
    }

    /// `onOutcome` (main-actor, success flag only) exists so a wrapper like
    /// `BotRoutinesViewModel` can observe whether the verb landed — e.g. to
    /// record a typed analytics event — without re-running or re-parsing the
    /// CLI. It carries no CLI text, deliberately.
    /// `job` is the record the argv addresses, where there is one. It is used
    /// only to compute the recovery offer `friendlyCronFailure` needs so the
    /// refusal sentence cannot name an affordance Hermes would refuse.
    private func runAndReload(
        _ arguments: [String],
        success: String,
        job: HermesCronJob? = nil,
        onOutcome: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let offer = job.map { recoveryOffer(for: $0) }
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: arguments, timeout: 60)
            await MainActor.run {
                onOutcome?(result.exitCode == 0)
                if result.exitCode == 0 {
                    self.post(success, outcome: .success)
                } else {
                    self.post(
                        Self.friendlyCronFailure(result.output, offer: offer)
                            ?? "Failed: \(result.output.prefix(200))",
                        outcome: .failure
                    )
                    // `.private`: the argv carries the job's prompt and the
                    // output can echo it back. Only the verb is safe to log
                    // in the clear — a cron prompt is user content, not
                    // diagnostics.
                    self.logger.warning(
                        "cron command failed: verb=\(arguments.dropFirst().first ?? "?", privacy: .public) args=\(arguments, privacy: .private) output=\(result.output, privacy: .private)"
                    )
                }
                self.load(force: true)
                self.refreshDiagnosticsAfterMutation()
            }
        }
    }
}
