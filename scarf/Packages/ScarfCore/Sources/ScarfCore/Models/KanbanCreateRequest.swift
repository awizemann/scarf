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
    /// v0.15: git branch a worktree-workspace task should operate on,
    /// passed verbatim as `--branch <name>`. Only meaningful with a
    /// `.worktree` / `.worktreePath` workspace. `nil`/empty → omitted.
    public var branch: String?
    /// v0.13: per-task retry budget. `--max-retries N` is write-once at
    /// create time — no `set_max_retries` verb. Pass `nil` to let Hermes
    /// pick its built-in default (3 as of v0.13.0). Capability-gated in
    /// the create sheet on `hasKanbanDiagnostics`.
    // TODO(WS-3-Q6): Confirm Hermes's global default for `max_retries`
    // (v0.13 release notes don't enumerate it). The create sheet defaults
    // the field to 3; if Hermes config exposes a different default, mirror
    // it.
    public var maxRetries: Int?

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
        branch: String? = nil
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
        self.branch = branch
    }

    /// Build the argv suffix this request maps to (everything after
    /// `["kanban", "create"]`). Public for tests; consumers should
    /// call `KanbanService.create` instead of building argv directly.
    public func argv() -> [String] {
        var args: [String] = []
        if let body, !body.isEmpty {
            args.append(contentsOf: ["--body", body])
        }
        if let assignee, !assignee.isEmpty {
            args.append(contentsOf: ["--assignee", assignee])
        }
        for parent in parentIds {
            args.append(contentsOf: ["--parent", parent])
        }
        if let workspace {
            args.append(contentsOf: ["--workspace", workspace.cliValue])
        }
        if let branch, !branch.isEmpty {
            args.append(contentsOf: ["--branch", branch])
        }
        if let tenant, !tenant.isEmpty {
            args.append(contentsOf: ["--tenant", tenant])
        }
        if let priority {
            args.append(contentsOf: ["--priority", String(priority)])
        }
        if triage {
            args.append("--triage")
        }
        if let idempotencyKey, !idempotencyKey.isEmpty {
            args.append(contentsOf: ["--idempotency-key", idempotencyKey])
        }
        if let maxRuntimeSeconds {
            args.append(contentsOf: ["--max-runtime", "\(maxRuntimeSeconds)s"])
        }
        if let maxRetries {
            args.append(contentsOf: ["--max-retries", String(maxRetries)])
        }
        if let createdBy, !createdBy.isEmpty {
            args.append(contentsOf: ["--created-by", createdBy])
        }
        for skill in skills {
            args.append(contentsOf: ["--skill", skill])
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
