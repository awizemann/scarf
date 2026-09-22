import Foundation

/// One task from `hermes kanban list --json` (v0.12+).
///
/// Hermes ships a SQLite-backed task board under `~/.hermes/kanban.db`.
/// v2.6 surfaced this as a read-only list; v2.7.5 lifts it to a full
/// drag-and-drop board with the complete write surface (`create`,
/// `claim`, `complete`, `block`, `unblock`, `archive`, `assign`,
/// `link`/`unlink`, `comment`, `dispatch`).
///
/// Hermes has no `update` verb — `priority` / `title` / `body` /
/// `tenant` / `max_retries` are write-once at create time. Mutations
/// after that are expressed as state transitions (status, assignee) or
/// new comments.
public struct HermesKanbanTask: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let title: String
    public let body: String?
    public let assignee: String?
    // Hermes's full vocabulary, v2026.9.21:hermes_cli/kanban_db.py:103
    // (VALID_STATUSES). `scheduled` and `review` arrived in v0.15.
    public let status: String          // archived | blocked | done | ready | review | running | scheduled | todo | triage
    public let priority: Int?
    public let tenant: String?
    public let workspaceKind: String?  // scratch | worktree | dir
    public let workspacePath: String?
    public let createdBy: String?
    public let createdAt: String?      // ISO timestamp
    public let startedAt: String?
    public let completedAt: String?
    public let result: String?
    public let skills: [String]

    // NOTE: the task JSON is exactly `_TASK_DICT_FIELDS`
    // (`hermes_cli/kanban_output.py:18-24`, v2026.9.7) — `_task_to_dict`
    // (:85-88) is the ONLY task serialiser, shared by `kanban create --json`
    // (`kanban.py:381`), `list --json` (:429) and `show --json` (:494).
    // `idempotency_key`, `last_heartbeat_at`, `max_runtime_seconds` and
    // `current_run_id` were modelled here from release notes; they are kanban
    // DB columns that no tagged release has ever put on the wire (walked
    // across every `v2026.*` tag: the dict is a literal at v0.13–v0.20 and a
    // field tuple after the output module split, and none of the four appears
    // in either). The decode paths are deleted rather than kept "defensively"
    // — a field that is always nil reads as "the host didn't report it".
    // v0.13 (v2026.5.7) reliability + recovery fields. All Optional with
    // `nil` decoded for pre-v0.13 hosts so the v2.7.5 surface keeps
    // rendering unchanged when the connected Hermes hasn't shipped them.
    /// Per-task retry budget set at create time via `--max-retries N`.
    /// Hermes pattern is write-once — no `set_max_retries` verb. Scarf
    /// surfaces this read-only on the inspector header.
    public let maxRetries: Int?

    // v0.15 (v2026.5.28) field.
    /// Originating ACP chat session id, stamped by `kanban_create` from
    /// the `HERMES_SESSION_ID` env the ACP adapter sets around the agent
    /// loop. `nil` for CLI/dashboard-created tasks and on pre-v0.15 hosts.
    /// Lets the chat-scoped board filter precisely by `--session` instead
    /// of the old tenant + time-window heuristic.
    public let sessionId: String?

    // v0.15 (v2026.5.28) worktree + workflow fields.
    /// Git branch a worktree-workspace task operates on, set via
    /// `kanban create --branch`. Present in `list --json`; `nil` for
    /// non-worktree tasks and pre-v0.15 hosts.
    public let branchName: String?
    /// Identifier of the multi-step workflow template driving this task.
    /// Present in `list --json`; `nil` for ad-hoc tasks and pre-v0.15
    /// hosts.
    public let workflowTemplateId: String?
    /// Key of the current step within the task's workflow template.
    /// Present in `list --json`; `nil` outside a workflow and pre-v0.15.
    public let currentStepKey: String?
    /// Per-task model override (e.g. a worker pinned to a specific model),
    /// set at create time. Emitted by every `--json` task envelope, `list`
    /// included — they all go through `_task_to_dict` and
    /// `_TASK_DICT_FIELDS` (`hermes_cli/kanban_output.py:18-24`,
    /// `hermes_cli/kanban.py:381`, `:429` @ `v2026.9.7`) — so `nil` means
    /// "no pin", not "this verb didn't say".
    public let modelOverride: String?
    /// The inference PROVIDER paired with `modelOverride`
    /// (`_TASK_DICT_FIELDS`, `hermes_cli/kanban_output.py:22`).
    ///
    /// **Floor v0.19.1 (`v2026.7.30`).** P42 first wrote v0.21.1 here by
    /// grepping `_TASK_DICT_FIELDS`, which dates the FILE MOVE (`kanban.py::
    /// _task_to_dict` → `kanban_output.py::_TASK_DICT_FIELDS` at `v2026.9.7`)
    /// and not the KEY. Re-walked by opening `hermes_cli/kanban.py` at every
    /// `v2026.*` tag: `"provider_override": t.provider_override` enters
    /// `_task_to_dict` at `v2026.7.30:80` (0.19.1) and is in every later tag
    /// — `v2026.8.31:80` included — while `v2026.7.20` (0.19.0) has no
    /// occurrence of the name in the file. `list --json` prints
    /// `[_task_to_dict(t) for t in tasks]` (`v2026.7.30:1594`), so the key is
    /// EMITTED from that tag. The inspector gates its chip on
    /// `HermesCapabilities.hasKanbanProviderOverride`; the DECODE itself
    /// needs no gate, being `decodeIfPresent`.
    public let providerOverride: String?
    /// `project_id` — the optional link to a first-class Hermes Project
    /// (`hermes_cli/projects_db`), declared on the `tasks` DDL at
    /// `hermes_cli/kanban_db.py:866-869` and emitted in every task envelope
    /// (`kanban_output.py:20`) @ `v2026.9.7`.
    ///
    /// **No capability flag, deliberately.** Walked the same way as
    /// `providerOverride`: `"project_id": t.project_id` enters
    /// `_task_to_dict` at `v2026.7.1:72` (0.18.0) and is absent at
    /// `v2026.6.19`. Nothing in Scarf's UI is gated on it — it is decode-only
    /// and `decodeIfPresent`, so a pre-v0.18 row decodes to `nil`, which is
    /// the same answer an unlinked task gives. A flag would gate nothing, so
    /// there is none; add one the day a surface renders it.
    ///
    /// This is NOT Scarf's project key and cannot become one: `create_task`
    /// resolves the id against the creator's per-profile `projects.db` and
    /// silently drops an id that does not resolve (`kanban_db.py:1110-1117`,
    /// `:1124-1127`), so a Scarf-minted value would evaporate. Scarf keys its
    /// own projects on `tenant` (see `KanbanTenantResolver`). Decoded so a
    /// task that IS linked to a real Hermes project can be told apart from
    /// one that is not, rather than the link being invisible.
    public let projectId: String?

    // v0.21.1 (v2026.9.7) fields. Both are new to the `list --json` task dict
    // at this release (`hermes_cli/kanban_output.py:18-24`) — `_task_to_dict`
    // in v2026.8.31's `hermes_cli/kanban.py:57-81` emitted neither, even though
    // the `last_failure_error` COLUMN has existed since v0.20.x. Gate the UI on
    // `hasKanbanCompletionContract`.
    /// Declared acceptance boundary for the card, set at create time via
    /// `--completion-contract`: `local-only` (Hermes's default), `OWNER/REPO`
    /// to require publication, or an exact GitHub PR URL whose CI gates
    /// `kanban complete`. `nil` on pre-v0.21.1 hosts and for cards created
    /// without one.
    public let completionContract: String?
    /// The failure reason from the card's last failed dispatch, previously
    /// reachable only via a second `kanban show`. `nil` on pre-v0.21.1 hosts,
    /// and cleared by Hermes on a successful run.
    public let lastFailureError: String?

    public init(
        id: String,
        title: String,
        body: String? = nil,
        assignee: String? = nil,
        status: String,
        priority: Int? = nil,
        tenant: String? = nil,
        workspaceKind: String? = nil,
        workspacePath: String? = nil,
        createdBy: String? = nil,
        createdAt: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil,
        result: String? = nil,
        skills: [String] = [],
        maxRetries: Int? = nil,
        sessionId: String? = nil,
        branchName: String? = nil,
        workflowTemplateId: String? = nil,
        currentStepKey: String? = nil,
        modelOverride: String? = nil,
        completionContract: String? = nil,
        lastFailureError: String? = nil,
        providerOverride: String? = nil,
        projectId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.assignee = assignee
        self.status = status
        self.priority = priority
        self.tenant = tenant
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.result = result
        self.skills = skills
        self.maxRetries = maxRetries
        self.sessionId = sessionId
        self.branchName = branchName
        self.workflowTemplateId = workflowTemplateId
        self.currentStepKey = currentStepKey
        self.modelOverride = modelOverride
        self.completionContract = completionContract
        self.lastFailureError = lastFailureError
        self.providerOverride = providerOverride
        self.projectId = projectId
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, assignee, status, priority, tenant
        case workspaceKind = "workspace_kind"
        case workspacePath = "workspace_path"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case result, skills
        case maxRetries = "max_retries"
        case sessionId = "session_id"
        case branchName = "branch_name"
        case workflowTemplateId = "workflow_template_id"
        case currentStepKey = "current_step_key"
        case modelOverride = "model_override"
        case providerOverride = "provider_override"
        case projectId = "project_id"
        case completionContract = "completion_contract"
        case lastFailureError = "last_failure_error"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        self.assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        self.tenant = try c.decodeIfPresent(String.self, forKey: .tenant)
        self.workspaceKind = try c.decodeIfPresent(String.self, forKey: .workspaceKind)
        self.workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
        self.createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        // Hermes emits timestamps as Unix integer seconds for tasks
        // returned from `create`/`show`/`list` (its SQLite columns are
        // INTEGER) but ISO-8601 strings in some other paths. Normalize
        // both shapes into ISO-8601 strings so UI code only deals with
        // one type.
        self.createdAt = try Self.decodeFlexibleTimestamp(c, forKey: .createdAt)
        self.startedAt = try Self.decodeFlexibleTimestamp(c, forKey: .startedAt)
        self.completedAt = try Self.decodeFlexibleTimestamp(c, forKey: .completedAt)
        self.result = try c.decodeIfPresent(String.self, forKey: .result)
        self.skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        // v0.13 fields — every one is `decodeIfPresent` so a v0.12 host's
        // task row decodes successfully with these all nil/empty. The
        // tolerant-decode contract is pinned by KanbanModelsTests.
        self.maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries)
        // v0.15 field — `decodeIfPresent` so pre-v0.15 task rows (no
        // `session_id` key) decode with `sessionId == nil`.
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        // v0.15 worktree + workflow fields. All `decodeIfPresent` so
        // pre-v0.15 rows decode with nil.
        //
        // `modelOverride` is NOT show-only, whatever this comment used to
        // say: `list --json` serialises each task through the same
        // `_task_to_dict` (`hermes_cli/kanban.py:429` @ `v2026.9.7`, and
        // `create --json` at `:381`), whose field tuple `_TASK_DICT_FIELDS`
        // carries `model_override` (`hermes_cli/kanban_output.py:18-24`). A
        // nil here means the task has no pin, not that the verb withheld it.
        self.branchName = try c.decodeIfPresent(String.self, forKey: .branchName)
        self.workflowTemplateId = try c.decodeIfPresent(String.self, forKey: .workflowTemplateId)
        self.currentStepKey = try c.decodeIfPresent(String.self, forKey: .currentStepKey)
        self.modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        // v0.21.1 fields — `decodeIfPresent` so a pre-v0.21.1 row (neither key
        // present) decodes with both nil and every existing surface renders
        // byte-identically.
        self.completionContract = try c.decodeIfPresent(String.self, forKey: .completionContract)
        // `decodeIfPresent` for both, exactly as every other version-gated
        // key: a pre-v0.21.1 row carries neither and decodes with both nil.
        self.providerOverride = try c.decodeIfPresent(String.self, forKey: .providerOverride)
        self.projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        self.lastFailureError = try c.decodeIfPresent(String.self, forKey: .lastFailureError)
    }

    /// Decode a timestamp that may arrive as a Unix integer or an
    /// ISO-8601 string. Returns the ISO-8601 string form so downstream
    /// code only deals with one type.
    static func decodeFlexibleTimestamp(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        if !container.contains(key) { return nil }
        // Try the SQLite-style integer first (most common from Hermes).
        if let unix = try? container.decodeIfPresent(Double.self, forKey: key) {
            let date = Date(timeIntervalSince1970: unix)
            return Self.isoFormatter.string(from: date)
        }
        // Fall back to a plain string.
        return try container.decodeIfPresent(String.self, forKey: key)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `createdAt` parsed back into a `Date` for time-window filtering
    /// (e.g. the "Since chat opened" lens on the project board). Nil
    /// when the wire field is absent OR the string can't be parsed —
    /// callers that filter by time treat unparseable rows as outside
    /// the window rather than crashing.
    public var createdAtDate: Date? {
        guard let createdAt else { return nil }
        return Self.isoFormatter.date(from: createdAt)
    }
}

// MARK: - Status enum (typed view of the wire string)

/// Typed mirror of Hermes's status enum. Models keep `status: String` for
/// forward compatibility with new statuses Hermes might add; UI code uses
/// `KanbanStatus.from(_:)` to map known values into typed categories and
/// fall back to `.unknown` for anything new.
public enum KanbanStatus: String, Sendable, CaseIterable, Identifiable {
    case triage
    case todo
    // v0.15: tasks parked by `kanban schedule` await a trigger.
    case scheduled
    case ready
    case running
    case blocked
    // v0.15: completed work awaiting verification before `done`.
    case review
    case done
    case archived
    case unknown

    public var id: String { rawValue }

    public static func from(_ raw: String) -> KanbanStatus {
        KanbanStatus(rawValue: raw.lowercased()) ?? .unknown
    }

    /// Coarse board grouping. `triage` is a column; `todo` and `ready`
    /// collapse to one ("Up Next"); everything else maps 1:1.
    /// `archived` lives outside the board (toggle). The v0.15 statuses
    /// `scheduled` and `review` map to their own dedicated columns.
    public var boardColumn: KanbanBoardColumn {
        switch self {
        case .triage:              return .triage
        case .scheduled:           return .scheduled
        case .todo, .ready, .unknown: return .upNext
        case .running:             return .running
        case .review:              return .review
        case .blocked:             return .blocked
        case .done:                return .done
        case .archived:            return .archived
        }
    }
}

public enum KanbanBoardColumn: String, Sendable, CaseIterable, Identifiable {
    case triage
    // v0.15: pre-work parked via `kanban schedule`, awaiting a trigger.
    case scheduled
    case upNext
    case running
    // v0.15: completed work awaiting verification before `done`.
    case review
    case blocked
    case done
    case archived

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .triage:    return "Triage"
        case .scheduled: return "Scheduled"
        case .upNext:    return "Up Next"
        case .running:   return "Running"
        case .review:    return "Review"
        case .blocked:   return "Blocked"
        case .done:      return "Done"
        case .archived:  return "Archived"
        }
    }

    /// Visible columns in the default board layout. `archived` appears
    /// only when the "Show archived" toggle is on. `triage`, `scheduled`,
    /// and `review` are shown only when the board has at least one task
    /// in that bucket (collapsed otherwise to keep the layout focused).
    /// `scheduled` sits before Up Next (it's pre-work); `review` sits
    /// between Running and Done.
    public static let defaultVisible: [KanbanBoardColumn] = [
        .triage, .scheduled, .upNext, .running, .review, .blocked, .done
    ]
}
