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
                    self.jobs = jobs
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

    // MARK: - Run history (Hermes v0.20+, `hermes cron runs`)

    /// Durable execution attempts for the selected job. Only loaded when
    /// the (capability-gated) RUN HISTORY disclosure is expanded — the
    /// view gates on `hasCronRuns`, so pre-0.20 hosts never issue the call.
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

    /// Open (un-acked) incidents for one job — drives the row badge.
    func openIncidentCount(jobID: String) -> Int {
        incidents.filter { $0.jobID == jobID && $0.isOpen }.count
    }

    /// Eager (not disclosure-gated) on purpose: the open-incident count
    /// drives an always-visible per-row badge, so the listing has to be in
    /// hand before the user expands anything.
    func loadIncidents(force: Bool = false) {
        if !force, hasLoadedIncidents { return }
        if isLoadingIncidents { return }   // don't stack duplicate in-flight probes
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
            }
        }
    }

    /// `hermes cron incidents ack <id>` **exits 0 on the miss path**: when
    /// `ack_incident` returns falsy the CLI prints "Incident <id> not found
    /// or already closed." in yellow and still returns 0
    /// (`hermes_cli/cron.py:322-335`). Exit code alone would report a
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
    @ObservationIgnored private var isLoadingDoctor = false

    func loadDoctor(force: Bool = false) {
        if !force, hasLoadedDoctor { return }
        if isLoadingDoctor { return }
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
            let parsed = ok ? HermesCronDoctorParser.parse(text: result.stdout) : [:]
            if !ok {
                log.warning("cron doctor produced unrecognized output (exit \(result.exitCode)): \(result.stderr.prefix(300))")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.doctorFindings = parsed
                    self.hasLoadedDoctor = true
                }
                self.isLoadingDoctor = false
            }
        }
    }

    // MARK: - CLI wrappers

    func pauseJob(_ job: HermesCronJob) {
        runAndReload(["cron", "pause", job.id], success: "Paused")
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

    /// Should Scarf refuse a terminal-job resume/run locally instead of
    /// round-tripping to the CLI? Only when the host is new enough to
    /// refuse it too. Factored out so both call sites — and the tests —
    /// share one contract.
    func refusesTerminalJobLocally(_ job: HermesCronJob) -> Bool {
        isV0206OrLater && job.isTerminal
    }

    func resumeJob(_ job: HermesCronJob) {
        // Since v0.20.6 `update_job` refuses to re-activate a
        // completed/error job ("Cannot activate terminal cron job …",
        // cron/jobs.py:2593/2694), and `resume_job` funnels through it.
        // Catch it before the CLI round-trip so the user gets the
        // actionable sentence instead of a Python ValueError tail.
        if refusesTerminalJobLocally(job) {
            post(terminalRefusalMessage(job), outcome: .failure)
            return
        }
        runAndReload(["cron", "resume", job.id], success: "Resumed")
    }

    /// `hermes cron resume <id> --run-now` (v0.20.6+) — the documented
    /// escape hatch for a terminal job: re-arms it to fire immediately
    /// rather than at its (spent) schedule. Callers gate on
    /// `hasCronResumeRunNow`.
    func resumeAndRunNow(_ job: HermesCronJob) {
        runAndReload(["cron", "resume", job.id, "--run-now"], success: "Resumed — running now")
    }

    /// Only reachable when `refusesTerminalJobLocally` said yes, i.e. on a
    /// v0.20.6+ host — which is exactly the generation that has the
    /// `--run-now` escape hatch, so the wording can name it outright.
    private func terminalRefusalMessage(_ job: HermesCronJob) -> String {
        let state = job.effectiveState == "error" ? "failed" : "finished"
        return "\"\(job.name)\" has \(state) and can't just be resumed — use Resume & Run Now to re-arm it."
    }

    /// Translate the Hermes terminal-job refusals into one plain sentence.
    /// Both `update_job` ("Cannot activate terminal cron job") and
    /// `trigger_job` ("Cannot run: … is completed (terminal)") land here
    /// via `runAndReload`/`runNow` when the pre-check above is bypassed
    /// (e.g. a job that turned terminal between load and click).
    static func friendlyCronFailure(_ output: String) -> String? {
        if output.contains("Cannot activate terminal cron job") {
            return "That job already finished — use Resume & Run Now to re-arm it, or duplicate it."
        }
        if output.contains("(terminal)") && output.contains("Cannot run") {
            return "That job already finished — use Resume & Run Now to re-arm it, or duplicate it."
        }
        return nil
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
        // `trigger_job` refuses terminal jobs outright (cron/jobs.py:2760)
        // — but only from v0.20.6 on; see `refusesTerminalJobLocally`.
        if refusesTerminalJobLocally(job) {
            post(terminalRefusalMessage(job), outcome: .failure)
            return
        }
        let svc = fileService
        let jobID = job.id
        Task.detached { [weak self] in
            let runResult = svc.runHermesCLI(args: ["cron", "run", jobID], timeout: 30)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if runResult.exitCode != 0 {
                    self.post(
                        Self.friendlyCronFailure(runResult.output)
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
        runAndReload(["cron", "remove", job.id], success: "Removed", onOutcome: onOutcome)
        if selectedJob?.id == job.id {
            selectedJob = nil
            jobOutput = nil
        }
    }

    func createJob(schedule: String, prompt: String, name: String, deliver: String, skills: [String], script: String, repeatCount: String, workdir: String = "", noAgent: Bool = false, onOutcome: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        runAndReload(
            Self.createJobArguments(
                schedule: schedule, prompt: prompt, name: name, deliver: deliver,
                skills: skills, script: script, repeatCount: repeatCount,
                workdir: workdir, noAgent: noAgent
            ),
            success: "Job created",
            onOutcome: onOutcome
        )
    }

    /// The exact argv `createJob` runs. Split out (not duplicated) so callers
    /// that compose a create — and the tests that pin their composition —
    /// assert the PRODUCTION command line rather than a parallel builder that
    /// can drift from it.
    nonisolated static func createJobArguments(schedule: String, prompt: String, name: String, deliver: String, skills: [String], script: String, repeatCount: String, workdir: String = "", noAgent: Bool = false) -> [String] {
        var args = ["cron", "create"]
        if !name.isEmpty { args += ["--name", name] }
        if !deliver.isEmpty { args += ["--deliver", deliver] }
        if !repeatCount.isEmpty { args += ["--repeat", repeatCount] }
        for skill in skills where !skill.isEmpty { args += ["--skill", skill] }
        if !script.isEmpty { args += ["--script", script] }
        // v0.12+: --workdir injects AGENTS.md/CLAUDE.md context and pins
        // cwd for terminal/file/code_exec tools. Hermes pre-v0.12 doesn't
        // know the flag — argparse rejects unknown args, so the form
        // omits the flag when the field is empty.
        if !workdir.isEmpty { args += ["--workdir", workdir] }
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

    func updateJob(id: String, schedule: String?, prompt: String?, name: String?, deliver: String?, repeatCount: String?, newSkills: [String]?, clearSkills: Bool, script: String?, workdir: String? = nil, noAgent: Bool? = nil) {
        // `job_id` is `cron edit`'s only positional, so it moves to the very
        // end behind `--` — every flag has to precede the marker, since
        // argparse treats each token after it as a positional.
        var args = ["cron", "edit"]
        if let schedule, !schedule.isEmpty { args += ["--schedule", schedule] }
        if let prompt, !prompt.isEmpty { args += ["--prompt", prompt] }
        if let name, !name.isEmpty { args += ["--name", name] }
        if let deliver { args += ["--deliver", deliver] }
        if let repeatCount, !repeatCount.isEmpty { args += ["--repeat", repeatCount] }
        if clearSkills {
            args.append("--clear-skills")
        } else if let newSkills {
            for skill in newSkills where !skill.isEmpty { args += ["--skill", skill] }
        }
        if let script { args += ["--script", script] }
        // `nil` = caller didn't touch the field (omit the flag). Empty string
        // = user cleared an existing workdir; Hermes documents `--workdir ""`
        // on edit as the explicit clear gesture, mirroring the `--script` shape.
        if let workdir { args += ["--workdir", workdir] }
        if let noAgent {
            if noAgent { args.append("--no-agent") }
            else { args.append("--agent") }
        }
        args.append(contentsOf: ["--", id])
        runAndReload(args, success: "Updated")
    }

    // MARK: - Private

    /// `onOutcome` (main-actor, success flag only) exists so a wrapper like
    /// `BotRoutinesViewModel` can observe whether the verb landed — e.g. to
    /// record a typed analytics event — without re-running or re-parsing the
    /// CLI. It carries no CLI text, deliberately.
    private func runAndReload(
        _ arguments: [String],
        success: String,
        onOutcome: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: arguments, timeout: 60)
            await MainActor.run {
                onOutcome?(result.exitCode == 0)
                if result.exitCode == 0 {
                    self.post(success, outcome: .success)
                } else {
                    self.post(
                        Self.friendlyCronFailure(result.output)
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
            }
        }
    }
}
