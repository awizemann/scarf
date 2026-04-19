import Foundation

struct HermesCronJob: Identifiable, Sendable, Codable {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let prompt: String
    nonisolated let skills: [String]?
    nonisolated let model: String?
    nonisolated let schedule: CronSchedule
    nonisolated let enabled: Bool
    nonisolated let state: String
    nonisolated let deliver: String?
    nonisolated let nextRunAt: String?
    nonisolated let lastRunAt: String?
    nonisolated let lastError: String?
    nonisolated let preRunScript: String?
    nonisolated let deliveryFailures: Int?
    nonisolated let lastDeliveryError: String?
    nonisolated let timeoutType: String?
    nonisolated let timeoutSeconds: Int?
    nonisolated let silent: Bool?

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

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                = try c.decode(String.self, forKey: .id)
        self.name              = try c.decode(String.self, forKey: .name)
        self.prompt            = try c.decode(String.self, forKey: .prompt)
        self.skills            = try c.decodeIfPresent([String].self, forKey: .skills)
        self.model             = try c.decodeIfPresent(String.self, forKey: .model)
        self.schedule          = try c.decode(CronSchedule.self, forKey: .schedule)
        self.enabled           = try c.decode(Bool.self, forKey: .enabled)
        self.state             = try c.decode(String.self, forKey: .state)
        self.deliver           = try c.decodeIfPresent(String.self, forKey: .deliver)
        self.nextRunAt         = try c.decodeIfPresent(String.self, forKey: .nextRunAt)
        self.lastRunAt         = try c.decodeIfPresent(String.self, forKey: .lastRunAt)
        self.lastError         = try c.decodeIfPresent(String.self, forKey: .lastError)
        self.preRunScript      = try c.decodeIfPresent(String.self, forKey: .preRunScript)
        self.deliveryFailures  = try c.decodeIfPresent(Int.self, forKey: .deliveryFailures)
        self.lastDeliveryError = try c.decodeIfPresent(String.self, forKey: .lastDeliveryError)
        self.timeoutType       = try c.decodeIfPresent(String.self, forKey: .timeoutType)
        self.timeoutSeconds    = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        self.silent            = try c.decodeIfPresent(Bool.self, forKey: .silent)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(skills, forKey: .skills)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(deliver, forKey: .deliver)
        try c.encodeIfPresent(nextRunAt, forKey: .nextRunAt)
        try c.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encodeIfPresent(preRunScript, forKey: .preRunScript)
        try c.encodeIfPresent(deliveryFailures, forKey: .deliveryFailures)
        try c.encodeIfPresent(lastDeliveryError, forKey: .lastDeliveryError)
        try c.encodeIfPresent(timeoutType, forKey: .timeoutType)
        try c.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try c.encodeIfPresent(silent, forKey: .silent)
    }

    nonisolated var stateIcon: String {
        switch state {
        case "scheduled": return "clock"
        case "running": return "play.circle"
        case "completed": return "checkmark.circle"
        case "failed": return "xmark.circle"
        default: return "questionmark.circle"
        }
    }

    nonisolated var deliveryDisplay: String? {
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
    nonisolated let kind: String
    nonisolated let runAt: String?
    nonisolated let display: String?
    nonisolated let expression: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case runAt = "run_at"
        case display
        case expression
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind       = try c.decode(String.self, forKey: .kind)
        self.runAt      = try c.decodeIfPresent(String.self, forKey: .runAt)
        self.display    = try c.decodeIfPresent(String.self, forKey: .display)
        self.expression = try c.decodeIfPresent(String.self, forKey: .expression)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(runAt, forKey: .runAt)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encodeIfPresent(expression, forKey: .expression)
    }
}

// Hand-written `init(from:)` / `encode(to:)` so Swift 6 doesn't synthesize a
// MainActor-isolated Codable conformance — `HermesFileService.loadCronJobs`
// is nonisolated and needs to decode this from a background task.
struct CronJobsFile: Sendable, Codable {
    nonisolated let jobs: [HermesCronJob]
    nonisolated let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case jobs
        case updatedAt = "updated_at"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jobs      = try c.decode([HermesCronJob].self, forKey: .jobs)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobs, forKey: .jobs)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}
