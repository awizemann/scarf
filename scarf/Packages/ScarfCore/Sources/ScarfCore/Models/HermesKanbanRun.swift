import Foundation

/// One attempt to execute a kanban task — `hermes kanban runs <id> --json`
/// returns an array of these per task. Each run records the worker
/// profile that claimed the task, the outcome, and a structured
/// metadata blob the worker handed back.
public struct HermesKanbanRun: Sendable, Equatable, Identifiable, Codable {
    public let id: Int
    public let profile: String?
    public let stepKey: String?
    public let status: String           // running | done | blocked | crashed | timed_out | failed | released
    public let workerPid: Int?
    public let startedAt: String
    public let endedAt: String?
    public let outcome: String?         // completed | blocked | crashed | timed_out | spawn_failed | gave_up | reclaimed
    public let summary: String?
    public let error: String?
    /// `metadata` is an opaque JSON dict from the worker. Carried as a
    /// raw string so we don't lock the typed shape.
    public let metadataJSON: String?

    // NOTE: the run JSON is exactly `_SHOW_RUN_FIELDS` / `_RUNS_RUN_FIELDS`
    // (`hermes_cli/kanban_output.py:25-32`, v2026.9.7 — the only shapes
    // `kanban show --json` :497 and `kanban runs --json` :1136 emit), and
    // that tuple is a CLOSED list: id, profile, step_key, status, outcome,
    // summary, error, metadata, worker_pid, started_at, ended_at. Nothing
    // else is on the wire.
    //
    // Decode paths for a per-run `diagnostics` array, plus `task_id`,
    // `claim_lock`, `claim_expires`, `max_runtime_seconds`,
    // `last_heartbeat_at` and `failure_count`, were modelled here from
    // release notes and DB columns and deleted once each was walked across
    // all 32 `v2026.*` tags without an emitter — `_obj_dict` over those
    // two tuples has never carried one. Run-scoped signals reach the UI from
    // `hermes kanban diagnostics --json`, whose entries carry `run_id`.

    public init(
        id: Int,
        profile: String? = nil,
        stepKey: String? = nil,
        status: String,
        workerPid: Int? = nil,
        startedAt: String,
        endedAt: String? = nil,
        outcome: String? = nil,
        summary: String? = nil,
        error: String? = nil,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.profile = profile
        self.stepKey = stepKey
        self.status = status
        self.workerPid = workerPid
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.summary = summary
        self.error = error
        self.metadataJSON = metadataJSON
    }

    enum CodingKeys: String, CodingKey {
        case id
        case profile
        case stepKey = "step_key"
        case status
        case workerPid = "worker_pid"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case outcome
        case summary
        case error
        case metadata
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        self.profile = try c.decodeIfPresent(String.self, forKey: .profile)
        self.stepKey = try c.decodeIfPresent(String.self, forKey: .stepKey)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        self.workerPid = try c.decodeIfPresent(Int.self, forKey: .workerPid)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let unix = try? c.decodeIfPresent(Double.self, forKey: .startedAt) {
            self.startedAt = f.string(from: Date(timeIntervalSince1970: unix))
        } else {
            self.startedAt = (try? c.decodeIfPresent(String.self, forKey: .startedAt)) ?? ""
        }
        if let unix = try? c.decodeIfPresent(Double.self, forKey: .endedAt) {
            self.endedAt = f.string(from: Date(timeIntervalSince1970: unix))
        } else {
            self.endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        }
        self.outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)

        if let raw = try? c.decodeIfPresent(String.self, forKey: .metadata) {
            self.metadataJSON = raw
        } else if c.contains(.metadata) {
            let nested = try c.decode(JSONAny.self, forKey: .metadata)
            let data = try JSONEncoder().encode(nested)
            self.metadataJSON = String(data: data, encoding: .utf8)
        } else {
            self.metadataJSON = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encodeIfPresent(stepKey, forKey: .stepKey)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(workerPid, forKey: .workerPid)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(metadataJSON, forKey: .metadata)
    }
}
