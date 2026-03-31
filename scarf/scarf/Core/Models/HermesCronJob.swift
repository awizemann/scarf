import Foundation

struct HermesCronJob: Identifiable, Sendable, Codable {
    let id: String
    let name: String
    let prompt: String
    let skills: [String]?
    let model: String?
    let schedule: CronSchedule
    let enabled: Bool
    let state: String
    let deliver: String?
    let nextRunAt: String?
    let lastRunAt: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, skills, model, schedule, enabled, state, deliver
        case nextRunAt = "next_run_at"
        case lastRunAt = "last_run_at"
        case lastError = "last_error"
    }

    var stateIcon: String {
        switch state {
        case "scheduled": return "clock"
        case "running": return "play.circle"
        case "completed": return "checkmark.circle"
        case "failed": return "xmark.circle"
        default: return "questionmark.circle"
        }
    }
}

struct CronSchedule: Sendable, Codable {
    let kind: String
    let runAt: String?
    let display: String?
    let expression: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case runAt = "run_at"
        case display
        case expression
    }
}

struct CronJobsFile: Sendable, Codable {
    let jobs: [HermesCronJob]
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case jobs
        case updatedAt = "updated_at"
    }
}
