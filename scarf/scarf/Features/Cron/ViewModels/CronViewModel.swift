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
    var message: String?
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

    // MARK: - CLI wrappers

    func pauseJob(_ job: HermesCronJob) {
        runAndReload(["cron", "pause", job.id], success: "Paused")
    }

    func resumeJob(_ job: HermesCronJob) {
        runAndReload(["cron", "resume", job.id], success: "Resumed")
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
        let svc = fileService
        let jobID = job.id
        Task.detached { [weak self] in
            let runResult = svc.runHermesCLI(args: ["cron", "run", jobID], timeout: 30)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if runResult.exitCode != 0 {
                    self.message = "Run failed to queue: \(runResult.output.prefix(200))"
                    self.logger.warning("cron run failed: \(runResult.output)")
                    self.load(force: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.message = nil
                    }
                    return
                }
                self.message = "Agent started — dashboard will update when it finishes"
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    func deleteJob(_ job: HermesCronJob) {
        runAndReload(["cron", "remove", job.id], success: "Removed")
        if selectedJob?.id == job.id {
            selectedJob = nil
            jobOutput = nil
        }
    }

    func createJob(schedule: String, prompt: String, name: String, deliver: String, skills: [String], script: String, repeatCount: String, workdir: String = "", noAgent: Bool = false) {
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
        args.append(schedule)
        if noAgent {
            args.append("")
        } else if !prompt.isEmpty {
            args.append(prompt)
        }
        runAndReload(args, success: "Job created")
    }

    func updateJob(id: String, schedule: String?, prompt: String?, name: String?, deliver: String?, repeatCount: String?, newSkills: [String]?, clearSkills: Bool, script: String?, workdir: String? = nil, noAgent: Bool? = nil) {
        var args = ["cron", "edit", id]
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
        runAndReload(args, success: "Updated")
    }

    // MARK: - Private

    private func runAndReload(_ arguments: [String], success: String) {
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: arguments, timeout: 60)
            await MainActor.run {
                if result.exitCode == 0 {
                    self.message = success
                } else {
                    self.message = "Failed: \(result.output.prefix(200))"
                    self.logger.warning("cron command failed: args=\(arguments) output=\(result.output)")
                }
                self.load(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }
}
