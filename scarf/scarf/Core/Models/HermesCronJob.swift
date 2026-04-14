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
    let preRunScript: String?
    let deliveryFailures: Int?
    let lastDeliveryError: String?
    let timeoutType: String?
    let timeoutSeconds: Int?
    let silent: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, skills, model, schedule, enabled, state, deliver, silent
        case nextRunAt = "next_run_at"
        case lastRunAt = "last_run_at"
        case lastError = "last_error"
        case preRunScript = "pre_run_script"
        case deliveryFailures = "delivery_failures"
        case lastDeliveryError = "last_delivery_error"
        case timeoutType = "timeout_type"
        case timeoutSeconds = "timeout_seconds"
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

    var deliveryDisplay: String? {
        guard let deliver, !deliver.isEmpty else { return nil }
        // v0.9.0 extends Discord routing to threads: `discord:<chat>:<thread>`.
        if deliver.hasPrefix("discord:") {
            let parts = deliver.dropFirst("discord:".count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                return "Discord thread \(parts[1]) in \(parts[0])"
            }
            if parts.count == 1 {
                return "Discord \(parts[0])"
            }
        }
        return deliver
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
