import Foundation

public struct HermesCronJob: Identifiable, Sendable, Codable {
    public nonisolated let id: String
    public nonisolated let name: String
    public nonisolated let prompt: String
    public nonisolated let skills: [String]?
    public nonisolated let model: String?
    public nonisolated let schedule: CronSchedule
    public nonisolated let enabled: Bool
    public nonisolated let state: String
    public nonisolated let deliver: String?
    public nonisolated let nextRunAt: String?
    public nonisolated let lastRunAt: String?
    public nonisolated let lastError: String?
    public nonisolated let preRunScript: String?
    public nonisolated let deliveryFailures: Int?
    public nonisolated let lastDeliveryError: String?
    public nonisolated let timeoutType: String?
    public nonisolated let timeoutSeconds: Int?
    public nonisolated let silent: Bool?

    public enum CodingKeys: String, CodingKey {
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

    /// Memberwise init. Swift doesn't synthesize one for us because
    /// of the hand-written Codable conformance. The iOS Cron editor
    /// uses this to rebuild jobs from user-edited fields.
    public nonisolated init(
        id: String,
        name: String,
        prompt: String,
        skills: [String]? = nil,
        model: String? = nil,
        schedule: CronSchedule,
        enabled: Bool,
        state: String,
        deliver: String? = nil,
        nextRunAt: String? = nil,
        lastRunAt: String? = nil,
        lastError: String? = nil,
        preRunScript: String? = nil,
        deliveryFailures: Int? = nil,
        lastDeliveryError: String? = nil,
        timeoutType: String? = nil,
        timeoutSeconds: Int? = nil,
        silent: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.skills = skills
        self.model = model
        self.schedule = schedule
        self.enabled = enabled
        self.state = state
        self.deliver = deliver
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastError = lastError
        self.preRunScript = preRunScript
        self.deliveryFailures = deliveryFailures
        self.lastDeliveryError = lastDeliveryError
        self.timeoutType = timeoutType
        self.timeoutSeconds = timeoutSeconds
        self.silent = silent
    }

    public nonisolated init(from decoder: any Decoder) throws {
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

    public nonisolated func encode(to encoder: any Encoder) throws {
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

    public nonisolated var stateIcon: String {
        switch state {
        case "scheduled": return "clock"
        case "running": return "play.circle"
        case "completed": return "checkmark.circle"
        case "failed": return "xmark.circle"
        default: return "questionmark.circle"
        }
    }

    public nonisolated var deliveryDisplay: String? {
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

public struct CronSchedule: Sendable, Codable {
    public nonisolated let kind: String
    public nonisolated let runAt: String?
    public nonisolated let display: String?
    public nonisolated let expression: String?

    public enum CodingKeys: String, CodingKey {
        case kind
        case runAt = "run_at"
        case display
        case expression
    }

    public nonisolated init(
        kind: String,
        runAt: String? = nil,
        display: String? = nil,
        expression: String? = nil
    ) {
        self.kind = kind
        self.runAt = runAt
        self.display = display
        self.expression = expression
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind       = try c.decode(String.self, forKey: .kind)
        self.runAt      = try c.decodeIfPresent(String.self, forKey: .runAt)
        self.display    = try c.decodeIfPresent(String.self, forKey: .display)
        self.expression = try c.decodeIfPresent(String.self, forKey: .expression)
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
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
public struct CronJobsFile: Sendable, Codable {
    public nonisolated let jobs: [HermesCronJob]
    public nonisolated let updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case jobs
        case updatedAt = "updated_at"
    }

    public nonisolated init(jobs: [HermesCronJob], updatedAt: String?) {
        self.jobs = jobs
        self.updatedAt = updatedAt
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jobs      = try c.decode([HermesCronJob].self, forKey: .jobs)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobs, forKey: .jobs)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}
