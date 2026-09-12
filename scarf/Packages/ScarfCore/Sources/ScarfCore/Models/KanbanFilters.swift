import Foundation

/// Filter options for `hermes kanban list --json`. Empty filter (default)
/// returns all non-archived tasks across all tenants.
public struct KanbanListFilter: Sendable, Equatable {
    public var status: KanbanStatus?
    public var assignee: String?
    /// `nil` = all tenants — the flag is omitted entirely. Any non-nil
    /// value, `""` included, becomes a literal `AND tenant = ?` equality
    /// (`hermes_cli/kanban_db.py:1472-1479` at `v2026.9.7`), so there is no
    /// spelling of `--tenant` that means "untagged"/NULL: `--tenant ""`
    /// matches only rows whose tenant is the empty string. Callers wanting
    /// every tenant must pass `nil`.
    public var tenant: String?
    /// `nil` = all sessions. Filters by the originating ACP chat
    /// `session_id` stamped on tasks created inside an agent loop
    /// (`hermes kanban list --session <id>`, v0.15+). ANDs with the
    /// other filters. Lets the chat-scoped board scope precisely.
    public var session: String?
    public var includeArchived: Bool
    /// Show only my profile's tasks (`--mine`).
    public var mineOnly: Bool
    /// v0.15: `--sort <key>` ordering. Accepted values (Hermes default
    /// `priority`): created, created-desc, priority, priority-desc,
    /// status, assignee, title, updated. Not enforced Swift-side —
    /// passed through verbatim so a new Hermes sort key doesn't need a
    /// Scarf release. `nil`/empty → omitted (Hermes default applies).
    public var sort: String?

    public init(
        status: KanbanStatus? = nil,
        assignee: String? = nil,
        tenant: String? = nil,
        session: String? = nil,
        includeArchived: Bool = false,
        mineOnly: Bool = false,
        sort: String? = nil
    ) {
        self.status = status
        self.assignee = assignee
        self.tenant = tenant
        self.session = session
        self.includeArchived = includeArchived
        self.mineOnly = mineOnly
        self.sort = sort
    }

    public static let all = KanbanListFilter()

    /// Build the argv suffix after `["kanban", "list"]`.
    public func argv() -> [String] {
        var args: [String] = ["--json"]
        if mineOnly {
            args.append("--mine")
        }
        if let status, status != .unknown {
            args.append(HermesCLIOption.joined("--status", status.rawValue))
        }
        if let assignee, !assignee.isEmpty {
            args.append(HermesCLIOption.joined("--assignee", assignee))
        }
        if let tenant {
            args.append(HermesCLIOption.joined("--tenant", tenant))
        }
        if let session, !session.isEmpty {
            args.append(HermesCLIOption.joined("--session", session))
        }
        if includeArchived {
            args.append("--archived")
        }
        if let sort, !sort.isEmpty {
            args.append(HermesCLIOption.joined("--sort", sort))
        }
        return args
    }
}

/// Summary of one `hermes kanban dispatch` pass. Used by the optional
/// "Dispatch now" button to show what happened.
public struct KanbanDispatchSummary: Sendable, Equatable, Codable {
    public let promoted: Int
    public let failed: Int
    public let dryRun: Bool
    public let perTask: [DispatchedTask]

    public init(
        promoted: Int = 0,
        failed: Int = 0,
        dryRun: Bool = false,
        perTask: [DispatchedTask] = []
    ) {
        self.promoted = promoted
        self.failed = failed
        self.dryRun = dryRun
        self.perTask = perTask
    }

    public struct DispatchedTask: Sendable, Equatable, Codable, Identifiable {
        public var id: String { taskId }
        public let taskId: String
        public let decision: String   // "promoted" | "skipped" | "failed"
        public let reason: String?

        public init(taskId: String, decision: String, reason: String? = nil) {
            self.taskId = taskId
            self.decision = decision
            self.reason = reason
        }

        enum CodingKeys: String, CodingKey {
            case taskId = "task_id"
            case decision
            case reason
        }
    }

    enum CodingKeys: String, CodingKey {
        case promoted
        case failed
        case dryRun = "dry_run"
        case perTask = "per_task"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.promoted = try c.decodeIfPresent(Int.self, forKey: .promoted) ?? 0
        self.failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        self.dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        self.perTask = try c.decodeIfPresent([DispatchedTask].self, forKey: .perTask) ?? []
    }
}
