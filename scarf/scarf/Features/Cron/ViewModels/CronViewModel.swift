import Foundation
import AppKit
import os

@Observable
final class CronViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "CronViewModel")
    private let fileService = HermesFileService()

    var jobs: [HermesCronJob] = []
    var selectedJob: HermesCronJob?
    var jobOutput: String?
    var availableSkills: [String] = []
    var message: String?
    var showCreateSheet = false
    var editingJob: HermesCronJob?

    func load() {
        jobs = fileService.loadCronJobs()
        availableSkills = fileService.loadSkills().flatMap { $0.skills.map(\.id) }.sorted()
        if let selected = selectedJob, let refreshed = jobs.first(where: { $0.id == selected.id }) {
            selectedJob = refreshed
            jobOutput = fileService.loadCronOutput(jobId: refreshed.id)
        }
    }

    func selectJob(_ job: HermesCronJob) {
        selectedJob = job
        jobOutput = fileService.loadCronOutput(jobId: job.id)
    }

    // MARK: - CLI wrappers

    func pauseJob(_ job: HermesCronJob) {
        runAndReload(["cron", "pause", job.id], success: "Paused")
    }

    func resumeJob(_ job: HermesCronJob) {
        runAndReload(["cron", "resume", job.id], success: "Resumed")
    }

    func runNow(_ job: HermesCronJob) {
        runAndReload(["cron", "run", job.id], success: "Scheduled for next tick")
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
