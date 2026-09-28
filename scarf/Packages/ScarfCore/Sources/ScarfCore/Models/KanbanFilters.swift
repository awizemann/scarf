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

/// Summary of one `hermes kanban dispatch --json` pass.
///
/// Decodes the keys Hermes actually prints (`_cmd_dispatch`,
/// `hermes_cli/kanban_ops.py:97-116` @ `v2026.9.24`; `spawned` has had this
/// shape since kanban shipped in `v2026.5.7`). The `skipped_*` /
/// `respawn_guarded` / `skipped_locked` / `memory_pressure` keys are newer;
/// an older host simply omits them and they decode as empty. The command
/// always exits 0, so whether a task was started is read from `spawned`.
public struct KanbanDispatchSummary: Sendable, Equatable, Decodable {
    public let promoted: Int
    /// Task ids a worker was spawned for this pass.
    public let spawnedTaskIds: [String]
    public let skippedUnassigned: [String]
    public let skippedNonspawnable: [String]
    /// `task_id -> assignee` held back by `kanban.max_in_progress_per_profile`.
    public let skippedPerProfileCapped: [String: String]
    /// `task_id -> reason` (`blocker_auth`, `recent_success`, `active_pr`).
    public let respawnGuarded: [String: String]
    /// Another process held the board's dispatch lock; this pass did nothing.
    public let skippedLocked: Bool
    /// `"critical"` / `"elevated"` when memory pressure limited spawning.
    public let memoryPressure: String?

    public init(
        promoted: Int = 0,
        spawnedTaskIds: [String] = [],
        skippedUnassigned: [String] = [],
        skippedNonspawnable: [String] = [],
        skippedPerProfileCapped: [String: String] = [:],
        respawnGuarded: [String: String] = [:],
        skippedLocked: Bool = false,
        memoryPressure: String? = nil
    ) {
        self.promoted = promoted
        self.spawnedTaskIds = spawnedTaskIds
        self.skippedUnassigned = skippedUnassigned
        self.skippedNonspawnable = skippedNonspawnable
        self.skippedPerProfileCapped = skippedPerProfileCapped
        self.respawnGuarded = respawnGuarded
        self.skippedLocked = skippedLocked
        self.memoryPressure = memoryPressure
    }

    /// Why a task the user asked to run was not started by this pass.
    public enum NotStartedReason: Sendable, Equatable {
        case unassigned
        case assigneeNotAProfile
        case profileAtCapacity(assignee: String)
        case respawnGuarded(reason: String)
        case dispatcherBusy
        case memoryPressure(level: String)
        /// Not in any bucket: not ready yet (e.g. open parents) or the
        /// board-wide in-progress cap was reached.
        case notReadyOrAtCapacity
    }

    /// `nil` when a worker was spawned for `taskId`.
    public func notStartedReason(for taskId: String) -> NotStartedReason? {
        if spawnedTaskIds.contains(taskId) { return nil }
        if skippedUnassigned.contains(taskId) { return .unassigned }
        if skippedNonspawnable.contains(taskId) { return .assigneeNotAProfile }
        if let who = skippedPerProfileCapped[taskId] { return .profileAtCapacity(assignee: who) }
        if let why = respawnGuarded[taskId] { return .respawnGuarded(reason: why) }
        if skippedLocked { return .dispatcherBusy }
        if let level = memoryPressure, !level.isEmpty { return .memoryPressure(level: level) }
        return .notReadyOrAtCapacity
    }

    private struct TaskRef: Decodable {
        let taskId: String
        let assignee: String?
        let reason: String?
        enum CodingKeys: String, CodingKey {
            case taskId = "task_id", assignee, reason
        }
    }

    enum CodingKeys: String, CodingKey {
        case promoted, spawned
        case skippedUnassigned = "skipped_unassigned"
        case skippedNonspawnable = "skipped_nonspawnable"
        case skippedPerProfileCapped = "skipped_per_profile_capped"
        case respawnGuarded = "respawn_guarded"
        case skippedLocked = "skipped_locked"
        case memoryPressure = "memory_pressure"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.promoted = try c.decodeIfPresent(Int.self, forKey: .promoted) ?? 0
        self.spawnedTaskIds = (try c.decodeIfPresent([TaskRef].self, forKey: .spawned) ?? []).map(\.taskId)
        self.skippedUnassigned = try c.decodeIfPresent([String].self, forKey: .skippedUnassigned) ?? []
        self.skippedNonspawnable = try c.decodeIfPresent([String].self, forKey: .skippedNonspawnable) ?? []
        let capped = try c.decodeIfPresent([TaskRef].self, forKey: .skippedPerProfileCapped) ?? []
        self.skippedPerProfileCapped = Dictionary(
            capped.map { ($0.taskId, $0.assignee ?? "") }, uniquingKeysWith: { a, _ in a })
        let guarded = try c.decodeIfPresent([TaskRef].self, forKey: .respawnGuarded) ?? []
        self.respawnGuarded = Dictionary(
            guarded.map { ($0.taskId, $0.reason ?? "") }, uniquingKeysWith: { a, _ in a })
        self.skippedLocked = try c.decodeIfPresent(Bool.self, forKey: .skippedLocked) ?? false
        self.memoryPressure = try c.decodeIfPresent(String.self, forKey: .memoryPressure)
    }
}
