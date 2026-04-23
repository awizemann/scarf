import Foundation
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

    func load() {
        isLoading = true
        let svc = fileService
        let selectedID = selectedJob?.id
        Task.detached { [weak self] in
            // Three sync transport ops on remote — keep them off main.
            let jobs = svc.loadCronJobs()
            let skills = svc.loadSkills().flatMap { $0.skills.map(\.id) }.sorted()
            let refreshed = selectedID.flatMap { id in jobs.first(where: { $0.id == id }) }
            let output = refreshed.flatMap { svc.loadCronOutput(jobId: $0.id) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.jobs = jobs
                self.availableSkills = skills
                if let refreshed { self.selectedJob = refreshed }
                if output != nil { self.jobOutput = output }
                self.isLoading = false
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
        let svc = fileService
        let jobID = job.id
        Task.detached { [weak self] in
            let runResult = svc.runHermesCLI(args: ["cron", "run", jobID], timeout: 30)
            // Give `cron run` a moment to register the queue entry
            // before forcing the tick. A few hundred ms is enough;
            // longer only delays the user-visible feedback.
            try? await Task.sleep(for: .milliseconds(250))
            let tickResult = svc.runHermesCLI(args: ["cron", "tick"], timeout: 60)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if runResult.exitCode == 0 && tickResult.exitCode == 0 {
                    self.message = "Job executed (see Output panel for details)"
                } else {
                    let errOutput = runResult.exitCode != 0 ? runResult.output : tickResult.output
                    self.message = "Run failed: \(errOutput.prefix(200))"
                    self.logger.warning("cron runNow failed: run=\(runResult.exitCode), tick=\(tickResult.exitCode) output=\(errOutput)")
                }
                self.load()
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

    func createJob(schedule: String, prompt: String, name: String, deliver: String, skills: [String], script: String, repeatCount: String) {
        var args = ["cron", "create"]
        if !name.isEmpty { args += ["--name", name] }
        if !deliver.isEmpty { args += ["--deliver", deliver] }
        if !repeatCount.isEmpty { args += ["--repeat", repeatCount] }
        for skill in skills where !skill.isEmpty { args += ["--skill", skill] }
        if !script.isEmpty { args += ["--script", script] }
        args.append(schedule)
        if !prompt.isEmpty { args.append(prompt) }
        runAndReload(args, success: "Job created")
    }

    func updateJob(id: String, schedule: String?, prompt: String?, name: String?, deliver: String?, repeatCount: String?, newSkills: [String]?, clearSkills: Bool, script: String?) {
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
        runAndReload(args, success: "Updated")
    }

    // MARK: - Private

    private func runAndReload(_ arguments: [String], success: String) {
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: arguments, timeout: 60)
            await MainActor.run {
                if result.exitCode == 0 {
                    self.message = success
                } else {
                    self.message = "Failed: \(result.output.prefix(200))"
                    self.logger.warning("cron command failed: args=\(arguments) output=\(result.output)")
                }
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }
}
