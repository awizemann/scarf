import Foundation

/// One event from the `task_events` log — emitted by `hermes kanban show`
/// (within a `HermesKanbanTaskDetail`). There is NO machine-readable live
/// stream to decode from: `hermes kanban watch` takes
/// `--assignee/--tenant/--kinds/--interval` and nothing else, and its help is
/// "Live-stream task_events to the terminal" (`hermes_cli/kanban_parser.py:359-365`
/// @ `v2026.9.7`) — no `--json`. Event kinds are open-ended on the Hermes
/// side; v0.12 emits a small known set listed in `KanbanEventKind`. Unknown
/// kinds map to `.unknown` so new Hermes builds don't break decoding.
public struct HermesKanbanEvent: Sendable, Equatable, Identifiable, Codable {
    public let id: Int
    public let taskId: String
    public let runId: Int?
    /// Wire string for the event kind. Use `kindEnum` to interpret.
    public let kind: String
    public let createdAt: String
    /// Opaque diagnostics payload from the `task_events.payload` column.
    /// Stored as a JSON string so callers that don't need it pay no
    /// decoding cost; callers that do can re-parse.
    public let payloadJSON: String?

    public init(
        id: Int,
        taskId: String,
        runId: Int? = nil,
        kind: String,
        createdAt: String,
        payloadJSON: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.runId = runId
        self.kind = kind
        self.createdAt = createdAt
        self.payloadJSON = payloadJSON
    }

    public var kindEnum: KanbanEventKind { KanbanEventKind.from(kind) }

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case runId = "run_id"
        case kind
        case createdAt = "created_at"
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        self.taskId = try c.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        self.runId = try c.decodeIfPresent(Int.self, forKey: .runId)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        if let unix = try? c.decodeIfPresent(Double.self, forKey: .createdAt) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            self.createdAt = f.string(from: Date(timeIntervalSince1970: unix))
        } else {
            self.createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        }

        // payload may be absent, a JSON object, or already a string.
        if let raw = try? c.decodeIfPresent(String.self, forKey: .payload) {
            self.payloadJSON = raw
        } else if c.contains(.payload) {
            // Re-encode arbitrary JSON into a string so we can carry it
            // around without committing to a typed shape.
            let nested = try c.decode(JSONAny.self, forKey: .payload)
            let data = try JSONEncoder().encode(nested)
            self.payloadJSON = String(data: data, encoding: .utf8)
        } else {
            self.payloadJSON = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(taskId, forKey: .taskId)
        try c.encodeIfPresent(runId, forKey: .runId)
        try c.encode(kind, forKey: .kind)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(payloadJSON, forKey: .payload)
    }
}

/// Known event kinds emitted by Hermes v0.12+. New kinds are surfaced
/// as `.unknown` until the model catches up; UI defaults to a generic
/// rendering for those.
public enum KanbanEventKind: String, Sendable, CaseIterable {
    case created
    case claimed
    case released
    case started
    case completed
    case blocked
    case unblocked
    case commented
    case archived
    case heartbeat
    case statusChange = "status_change"
    case error
    case crashed
    case timedOut = "timed_out"
    case spawnFailed = "spawn_failed"
    case unknown

    public static func from(_ raw: String) -> KanbanEventKind {
        KanbanEventKind(rawValue: raw.lowercased()) ?? .unknown
    }
}

// MARK: - JSON-any helper

/// Minimal type-erased JSON wrapper used for opaque event payloads. We
/// don't commit to a typed shape because Hermes treats payload as
/// diagnostics and may evolve it freely. Used only inside Codable
/// init/encode (a single decode→re-encode→string pass), so the `Any`
/// payload never crosses an actor boundary — `@unchecked Sendable`
/// is the appropriate seal here.
struct JSONAny: Codable, @unchecked Sendable {
    let raw: Any

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.raw = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            self.raw = b
        } else if let i = try? container.decode(Int64.self) {
            self.raw = i
        } else if let d = try? container.decode(Double.self) {
            self.raw = d
        } else if let s = try? container.decode(String.self) {
            self.raw = s
        } else if let arr = try? container.decode([JSONAny].self) {
            self.raw = arr.map(\.raw)
        } else if let dict = try? container.decode([String: JSONAny].self) {
            self.raw = dict.mapValues(\.raw)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch raw {
        case is NSNull:
            try c.encodeNil()
        case let b as Bool:
            try c.encode(b)
        case let i as Int64:
            try c.encode(i)
        case let i as Int:
            try c.encode(Int64(i))
        case let d as Double:
            try c.encode(d)
        case let s as String:
            try c.encode(s)
        case let arr as [Any]:
            try c.encode(arr.map { JSONAny(unsafeRaw: $0) })
        case let dict as [String: Any]:
            try c.encode(dict.mapValues { JSONAny(unsafeRaw: $0) })
        default:
            throw EncodingError.invalidValue(
                raw,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported")
            )
        }
    }

    private init(unsafeRaw: Any) { self.raw = unsafeRaw }
}
