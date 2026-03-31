import Foundation

@Observable
final class CronViewModel {
    private let fileService = HermesFileService()

    var jobs: [HermesCronJob] = []
    var selectedJob: HermesCronJob?
    var jobOutput: String?

    func load() {
        jobs = fileService.loadCronJobs()
    }

    func selectJob(_ job: HermesCronJob) {
        selectedJob = job
        jobOutput = fileService.loadCronOutput(jobId: job.id)
    }
}
