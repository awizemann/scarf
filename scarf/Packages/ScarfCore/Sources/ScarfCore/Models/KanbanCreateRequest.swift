import Foundation

/// Swift-side parameter struct that maps 1:1 onto `hermes kanban create`
/// flags. Constructing one then handing it to `KanbanService.create`
/// keeps the CLI argv assembly in one place — VMs build a `KanbanCreateRequest`
/// from form state and never assemble argv directly.
public struct KanbanCreateRequest: Sendable, Equatable {
    public var title: String
    public var body: String?
    public var assignee: String?
    public var parentIds: [String]
    public var workspace: KanbanWorkspaceSpec?
    public var tenant: String?
    public var priority: Int?
    public var triage: Bool
    public var idempotencyKey: String?
    public var maxRuntimeSeconds: Int?
    public var createdBy: String?
    public var skills: [String]
    // `branch` is GONE (P56). It emitted `--branch <name>` ungated, and
    // `--branch` first exists at `v2026.5.28` (0.15.0) — it occurs zero times
    // in `hermes_cli/kanban.py` at `v2026.5.16` (0.14.0), where argparse
    // would have exited 2 on the whole `kanban create`. But no production
    // caller ever set it: the only writers were two tests. Deleting the
    // parameter is strictly smaller than the alternative (a new capability
    // flag, its four-test floor group, and a gate on a field nothing fills)
    // and it cannot regress a surface that was never reachable — which is
    // also why it needs no C1 argument: every host renders exactly as
    // before. Re-add it WITH its flag the day a create form grows the field;
    // the floor walk is recorded here so it costs nothing to redo.
    /// v0.13: per-task FAILURE budget. `--max-retries N` is write-once at
    /// create time — no `set_max_retries` verb. Despite the flag's name it
    /// is a ceiling on *consecutive failures*, not on extra attempts:
    /// `record_failure` trips the breaker when `failures >= effective_limit`
    /// and parks the card in `blocked` (`hermes_cli/kanban_db_dispatch.py:1026-1034`
    /// at v2026.9.7), so `1` means "no retries — block on the first failure"
    /// and `2` (Hermes's own `DEFAULT_FAILURE_LIMIT`, same file:33) means
    /// one retry. Pass `nil` to let Hermes apply that default.
    /// Capability-gated in the create sheet on `hasKanbanDiagnostics`.
    public var maxRetries: Int?

    /// Hermes's `DEFAULT_FAILURE_LIMIT` (`hermes_cli/kanban_db_dispatch.py:33`,
    /// v2026.9.7) — the value the dispatcher uses when neither the per-task
    /// `max_retries` nor `kanban.failure_limit` is set. Mirrored so the create
    /// sheet seeds the stepper at Hermes's real default instead of inventing one.
    public static let hermesDefaultFailureLimit = 2
    /// v0.21.1: `--completion-contract <contract>` — `local-only` (Hermes's
    /// own default), `OWNER/REPO` to require publication, or an exact GitHub
    /// PR URL whose CI gates `kanban complete`
    /// (`hermes_cli/kanban_parser.py:189`). Create-only: `kanban edit` at
    /// v2026.9.7 takes `--result` and the step-handoff flags and nothing else,
    /// so there is no edit path to offer. Callers MUST leave this nil unless
    /// `HermesCapabilities.hasKanbanCompletionContract` — a pre-v0.21.1
    /// argparse exits 2 on the unknown flag and the card is never created.
    public var completionContract: String?

    public init(
        title: String,
        body: String? = nil,
        assignee: String? = nil,
        parentIds: [String] = [],
        workspace: KanbanWorkspaceSpec? = nil,
        tenant: String? = nil,
        priority: Int? = nil,
        triage: Bool = false,
        idempotencyKey: String? = nil,
        maxRuntimeSeconds: Int? = nil,
        createdBy: String? = nil,
        skills: [String] = [],
        maxRetries: Int? = nil,
        completionContract: String? = nil
    ) {
        self.title = title
        self.body = body
        self.assignee = assignee
        self.parentIds = parentIds
        self.workspace = workspace
        self.tenant = tenant
        self.priority = priority
        self.triage = triage
        self.idempotencyKey = idempotencyKey
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.createdBy = createdBy
        self.skills = skills
        self.maxRetries = maxRetries
        self.completionContract = completionContract
    }

    /// Build the argv suffix this request maps to (everything after
    /// `["kanban", "create"]`). Public for tests; consumers should
    /// call `KanbanService.create` instead of building argv directly.
    public func argv() -> [String] {
        var args: [String] = []
        if let body, !body.isEmpty {
            args.append(HermesCLIOption.joined("--body", body))
        }
        if let assignee, !assignee.isEmpty {
            args.append(HermesCLIOption.joined("--assignee", assignee))
        }
        for parent in parentIds {
            args.append(HermesCLIOption.joined("--parent", parent))
        }
        if let workspace {
            args.append(HermesCLIOption.joined("--workspace", workspace.cliValue))
        }
        if let tenant, !tenant.isEmpty {
            args.append(HermesCLIOption.joined("--tenant", tenant))
        }
        if let priority {
            args.append(HermesCLIOption.joined("--priority", String(priority)))
        }
        if triage {
            args.append("--triage")
        }
        if let idempotencyKey, !idempotencyKey.isEmpty {
            args.append(HermesCLIOption.joined("--idempotency-key", idempotencyKey))
        }
        if let maxRuntimeSeconds {
            args.append(HermesCLIOption.joined("--max-runtime", "\(maxRuntimeSeconds)s"))
        }
        if let maxRetries {
            args.append(HermesCLIOption.joined("--max-retries", String(maxRetries)))
        }
        if let completionContract, !completionContract.isEmpty {
            args.append(HermesCLIOption.joined("--completion-contract", completionContract))
        }
        if let createdBy, !createdBy.isEmpty {
            args.append(HermesCLIOption.joined("--created-by", createdBy))
        }
        for skill in skills {
            args.append(HermesCLIOption.joined("--skill", skill))
        }
        args.append("--json")
        // Title is the positional argument — appended last, behind `--`, so
        // a title that legitimately starts with a dash ("--force is
        // ignored") is read as text instead of being claimed as an option
        // (argparse exits 2, or worse, silently flips a flag). `--` has to
        // be last: argparse reads EVERY token after it as a positional.
        args.append(contentsOf: ["--", title])
        return args
    }
}

/// Typed mirror of Hermes's `--workspace` flag. Hermes accepts
/// `scratch | worktree | worktree:<path> | dir:<path>`. `scratch` and
/// `worktree` are bare strings on the wire; `worktree:<path>` and
/// `dir:<absolute path>` are colon-prefixed paths. We keep them typed in
/// Swift so callers can't typo "scrach".
public enum KanbanWorkspaceSpec: Sendable, Equatable {
    case scratch
    case worktree
    /// v0.15: a worktree rooted at an explicit path (`worktree:<path>`).
    case worktreePath(String)
    case directory(String)

    public var cliValue: String {
        switch self {
        case .scratch:              return "scratch"
        case .worktree:             return "worktree"
        case .worktreePath(let p):  return "worktree:\(p)"
        case .directory(let p):     return "dir:\(p)"
        }
    }

    /// "scratch" / "worktree" / "dir" — the kind segment, suitable
    /// for badge labels.
    public var displayKind: String {
        switch self {
        case .scratch:                  return "scratch"
        case .worktree, .worktreePath:  return "worktree"
        case .directory:                return "dir"
        }
    }
}
