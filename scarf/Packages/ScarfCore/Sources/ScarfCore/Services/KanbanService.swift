import Foundation
#if canImport(os)
import os
#endif

/// Async, transport-aware client for `hermes kanban …`. Wraps every CLI
/// verb the v0.12 board exposes in a typed Swift surface.
///
/// **Concurrency.** This is a pure-I/O `actor` — no UI state. View models
/// (`@MainActor` `@Observable`) hold a service reference and `await`
/// methods. Each public method serializes through the actor, but the
/// underlying CLI invocation runs on a `Task.detached(priority: .utility)`
/// so two concurrent reads from different VMs don't queue end-to-end on
/// a single thread.
///
/// **Hermes constraints surfaced as Swift constraints:**
/// - There is no `update` verb, so there's no `update(taskId:title:body:)`.
///   Mutations after create are state transitions (assign / claim /
///   complete / block / unblock / archive / comment) or new comments.
/// - The board is global with optional `tenant` namespacing — pass a
///   tenant via `KanbanListFilter.tenant` for project-scoped views.
/// - The CLI prints `"no matching tasks"` instead of `[]` when nothing
///   matches a filter. We fold that into `[]` rather than throwing.
public actor KanbanService {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "KanbanService")
    #endif

    private let context: ServerContext
    /// Optional board slug. `--board <slug>` is a GLOBAL flag on the
    /// top-level `kanban` parser (applies to every subcommand), so it's
    /// inserted right after `"kanban"` in every verb's argv via
    /// `prefix()`. `nil` (the default) keeps existing callers on the
    /// implicit default board — argv is byte-identical to before.
    private let board: String?

    public init(context: ServerContext, board: String? = nil) {
        self.context = context
        self.board = board
    }

    /// argv prefix shared by every verb: `["kanban"]` plus the global
    /// `--board <slug>` flag when a board slug is set. Keeps the global
    /// flag in one place so all subcommands scope consistently.
    private nonisolated func prefix(_ verbAndArgs: String...) -> [String] {
        var args = ["kanban"]
        if let board, !board.isEmpty {
            args.append(contentsOf: ["--board", board])
        }
        args.append(contentsOf: verbAndArgs)
        return args
    }

    // MARK: - Reads

    public func list(_ filter: KanbanListFilter = .all) async throws -> [HermesKanbanTask] {
        var args = prefix("list")
        args.append(contentsOf: filter.argv())
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 20)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "list")

        // No "(no matching tasks)" sentinel here on purpose. `argv()` always
        // passes `--json`, and `_cmd_list` returns `json.dumps([])` before it
        // can ever reach that print — so the sentinel was dead code that a
        // task TITLED "no matching tasks" could nonetheless trip, silently
        // emptying a populated board. Substring-matching CLI prose is not a
        // protocol; the empty array is.
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode([HermesKanbanTask].self, from: data)
        } catch {
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    public func show(taskId: String) async throws -> HermesKanbanTaskDetail {
        let args = prefix("show", taskId, "--json")
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "show")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: data)
        } catch {
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    public func runs(taskId: String) async throws -> [HermesKanbanRun] {
        let args = prefix("runs", taskId, "--json")
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "runs")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode([HermesKanbanRun].self, from: data)
        } catch {
            // Some Hermes builds emit a `{"runs": [...]}` envelope.
            struct Wrapper: Decodable { let runs: [HermesKanbanRun] }
            if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
                return wrapped.runs
            }
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    public func stats() async throws -> HermesKanbanStats {
        let args = prefix("stats", "--json")
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "stats")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode(HermesKanbanStats.self, from: data)
        } catch {
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    /// Print the captured worker log for a task — `hermes kanban log
    /// <id>`. Returns whatever `$HERMES_HOME/kanban/logs/<id>` contains.
    /// Empty string when the worker hasn't written anything yet (or
    /// the task has never been claimed). Pass `tailBytes` to cap the
    /// returned size (useful when polling at high cadence).
    public func log(taskId: String, tailBytes: Int? = nil) async throws -> String {
        var args = prefix("log")
        if let tailBytes {
            args.append(contentsOf: ["--tail", String(tailBytes)])
        }
        args.append(taskId)
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        // `kanban log` exits with code 0 even when no log file exists —
        // it just prints "No log file." or similar to stdout. Tolerate
        // non-zero codes too: some Hermes versions emit a warning to
        // stderr and exit 1 when the log dir is missing.
        if code != 0 {
            let combined = stderr.isEmpty ? stdout : stderr
            // Treat "no log" sentinels as empty rather than as errors.
            let lower = combined.lowercased()
            if lower.contains("no log") || lower.contains("not found") {
                return ""
            }
            throw KanbanError.nonZeroExit(code: code, stderr: combined)
        }
        return stdout
    }

    public func assignees() async throws -> [HermesKanbanAssignee] {
        // The `assignees` verb doesn't take `--json` consistently across
        // 0.12.x — pass it anyway and fall back to a tab-delimited parse
        // if Hermes printed a human table.
        let args = prefix("assignees")
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "assignees")

        if let data = stdout.data(using: .utf8),
           let arr = try? JSONDecoder().decode([HermesKanbanAssignee].self, from: data) {
            return arr
        }

        // Fallback: each non-blank line of the form
        //   "<profile>\t<active>\t<total>"
        // OR "<profile>     <active>     <total>" (whitespace separated).
        return parseAssigneeTable(stdout)
    }

    private nonisolated func parseAssigneeTable(_ text: String) -> [HermesKanbanAssignee] {
        var result: [HermesKanbanAssignee] = []
        // Profile names follow the same convention as `hermes -p <name>`
        // — letters, digits, hyphen, underscore. Anything else is
        // chrome (header rows, Rich box-drawing, fallback messages
        // like "(no assignees — create a profile with `hermes -p
        // <name> setup`)") and gets skipped.
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Skip the column header row.
            if line.lowercased().hasPrefix("profile") { continue }
            // Skip the empty-state sentinel without trying to tokenize
            // it (used to leak "(no" into the picker).
            if line.lowercased().contains("no assignees") { continue }
            // Skip Rich box-drawing separators (only ─ + whitespace).
            if line.unicodeScalars.allSatisfy({ $0.value == 0x2500 || $0.properties.isWhitespace }) {
                continue
            }
            // Strip the active marker `◆` (U+25C6) some `hermes`
            // commands prefix to the active profile.
            var working = line
            if working.hasPrefix("◆") {
                working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let parts = working
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
                .map { String($0) }
                .filter { !$0.isEmpty }
            guard let profile = parts.first else { continue }
            // Validate: must look like a real profile slug, not a word
            // out of an English sentence.
            guard profile.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
                continue
            }
            let active = (parts.count > 1) ? Int(parts[1]) ?? 0 : 0
            let total = (parts.count > 2) ? Int(parts[2]) ?? 0 : active
            result.append(HermesKanbanAssignee(profile: profile, activeCount: active, totalCount: total))
        }
        return result
    }

    // MARK: - Writes

    public func create(_ request: KanbanCreateRequest) async throws -> HermesKanbanTask {
        var args = prefix("create")
        args.append(contentsOf: request.argv())
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "create")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        // Hermes returns the full task object when --json is set.
        do {
            return try JSONDecoder().decode(HermesKanbanTask.self, from: data)
        } catch {
            // Some builds emit just the new id on stdout. Fall back to a
            // follow-up `show` so the caller always gets a typed task.
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("{") {
                let detail = try await show(taskId: trimmed)
                return detail.task
            }
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    public func assign(taskId: String, profile: String?) async throws {
        let target = (profile?.isEmpty ?? true) ? "none" : profile!
        let args = prefix("assign", taskId, target)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "assign")
    }

    @discardableResult
    public func claim(taskId: String, ttlSeconds: Int = 900) async throws -> String {
        let args = prefix("claim", taskId, "--ttl", String(ttlSeconds))
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 20)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "claim")
        // claim prints the resolved workspace path on stdout.
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func comment(taskId: String, text: String, author: String? = nil) async throws {
        var args = prefix("comment")
        if let author, !author.isEmpty {
            args.append(contentsOf: ["--author", author])
        }
        // `--` last, after every flag: argparse treats EVERY token after the
        // first `--` as a positional, so a flag behind it would be eaten as
        // an extra positional. `text` is `nargs="+"` — one argv element is a
        // one-word list the CLI joins, so the whole comment stays intact.
        args.append(contentsOf: ["--", taskId, text])
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "comment")
    }

    public func complete(
        taskIds: [String],
        result: String? = nil,
        summary: String? = nil,
        metadataJSON: String? = nil
    ) async throws {
        guard !taskIds.isEmpty else { return }
        var args = prefix("complete")
        if let result, !result.isEmpty {
            args.append(contentsOf: ["--result", result])
        }
        if let summary, !summary.isEmpty {
            args.append(contentsOf: ["--summary", summary])
        }
        if let metadataJSON, !metadataJSON.isEmpty {
            args.append(contentsOf: ["--metadata", metadataJSON])
        }
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 30)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "complete")
    }

    public func block(taskId: String, reason: String? = nil) async throws {
        var args = prefix("block")
        // `--` before the positionals (see `comment`). The reason goes over
        // as ONE argv element rather than space-split: `reason` is
        // `nargs="*"`, so the CLI joins the list back — splitting it here
        // only destroyed runs of whitespace and handed argparse a chance to
        // read a word starting with `-` as a flag.
        args.append(contentsOf: ["--", taskId])
        if let reason, !reason.trimmingCharacters(in: .whitespaces).isEmpty {
            args.append(reason)
        }
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "block")
    }

    public func unblock(taskIds: [String]) async throws {
        guard !taskIds.isEmpty else { return }
        var args = prefix("unblock")
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "unblock")
    }

    public func archive(taskIds: [String]) async throws {
        guard !taskIds.isEmpty else { return }
        var args = prefix("archive")
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "archive")
    }

    @discardableResult
    public func dispatch(maxTasks: Int? = nil, dryRun: Bool = false) async throws -> KanbanDispatchSummary {
        var args = prefix("dispatch", "--json")
        if dryRun { args.append("--dry-run") }
        if let maxTasks { args.append(contentsOf: ["--max", String(maxTasks)]) }
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 60)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "dispatch")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode(KanbanDispatchSummary.self, from: data)
        } catch {
            // Older builds may print human output. Return a stub summary.
            return KanbanDispatchSummary(promoted: 0, failed: 0, dryRun: dryRun, perTask: [])
        }
    }

    public func link(parent: String, child: String) async throws {
        let args = prefix("link", parent, child)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "link")
    }

    public func unlink(parent: String, child: String) async throws {
        let args = prefix("unlink", parent, child)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "unlink")
    }

    // MARK: - v0.15 verbs

    /// Promote `todo`/`blocked` tasks to `ready` so the dispatcher can
    /// pick them up — `hermes kanban promote <ids…>`. Hermes accepts
    /// positional ids (the `--ids` flag is the bulk alternative; positional
    /// is fine). `reason` is appended as a trailing positional word group;
    /// `--force` overrides guard checks, `--dry-run` previews without
    /// mutating. `--json` for a machine-readable summary.
    public func promote(
        taskIds: [String],
        reason: String? = nil,
        force: Bool = false,
        dryRun: Bool = false
    ) async throws {
        guard !taskIds.isEmpty else { return }
        var args = prefix("promote")
        // Flags FIRST, then `--`, then the positionals — argparse consumes
        // everything after the first `--` as a positional, so `--json` /
        // `--force` behind it would be rejected as "unrecognized arguments".
        if force { args.append("--force") }
        if dryRun { args.append("--dry-run") }
        args.append("--json")
        args.append("--")
        args.append(contentsOf: taskIds)
        if let reason, !reason.isEmpty {
            args.append(reason)
        }
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "promote")
    }

    /// Park tasks in the `scheduled` status — `hermes kanban schedule
    /// <ids…>`. They await a later trigger (workflow step, manual
    /// promote, etc.) instead of being eligible for dispatch.
    public func schedule(taskIds: [String], reason: String? = nil) async throws {
        guard !taskIds.isEmpty else { return }
        var args = prefix("schedule")
        args.append("--")
        args.append(contentsOf: taskIds)
        if let reason, !reason.isEmpty {
            args.append(reason)
        }
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "schedule")
    }

    /// Hard-delete already-archived tasks — `hermes kanban archive --rm
    /// <ids…>`. There's no separate `purge` verb; the `--rm` flag on
    /// `archive` performs the destructive removal. Only valid on tasks
    /// already in `archived`.
    public func purge(taskIds: [String]) async throws {
        guard !taskIds.isEmpty else { return }
        var args = prefix("archive", "--rm")
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "purge")
    }

    /// Spawn a swarm of workers against a single goal — `hermes kanban
    /// swarm <goal> --worker … --verifier … --synthesizer …`. Each
    /// `worker` string is passed verbatim in `PROFILE:TITLE[:SKILL,SKILL]`
    /// format. The verifier checks worker output; the synthesizer merges
    /// it. Optional tenant / priority / created-by / idempotency-key.
    public func swarm(
        goal: String,
        workers: [String],
        verifier: String,
        synthesizer: String,
        tenant: String? = nil,
        priority: Int? = nil,
        createdBy: String? = nil,
        idempotencyKey: String? = nil
    ) async throws {
        var args = prefix("swarm")
        for worker in workers {
            args.append(contentsOf: ["--worker", worker])
        }
        args.append(contentsOf: ["--verifier", verifier, "--synthesizer", synthesizer])
        if let tenant, !tenant.isEmpty {
            args.append(contentsOf: ["--tenant", tenant])
        }
        if let priority {
            args.append(contentsOf: ["--priority", String(priority)])
        }
        if let createdBy, !createdBy.isEmpty {
            args.append(contentsOf: ["--created-by", createdBy])
        }
        if let idempotencyKey, !idempotencyKey.isEmpty {
            args.append(contentsOf: ["--idempotency-key", idempotencyKey])
        }
        args.append("--json")
        // `goal` is argparse's positional and moves to the very end behind
        // `--`, so a goal that legitimately opens with a dash ("--json is
        // broken") is text rather than a flag. It cannot stay next to the
        // verb: every token after `--` is a positional.
        args.append(contentsOf: ["--", goal])
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 60)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "swarm")
    }

    // MARK: - Hallucination gate (v0.13)

    // NOTE: there is NO `hermes kanban verify` verb in Hermes (re-verified
    // against v0.16 — `kanban` has no verify/reject subcommand). The
    // former `verify(taskId:)` shelled a non-existent verb and has been
    // removed. Rejection (below) routes through the real `comment` +
    // `archive` verbs, so the recovery UX stays functional.

    /// Reject a worker-created card as a hallucinated reference. There
    /// is no dedicated `kanban reject` verb in v0.13; the right action
    /// per the v0.13 release notes is to archive the card (the work
    /// doesn't exist) with a comment recording the rejection reason for
    /// the audit trail. Routing this through the existing `comment` +
    /// `archive` verbs keeps the wire shape stable across versions.
    ///
    /// If a future Hermes adds a dedicated `kanban reject` verb, swap
    /// the body here — the public surface stays "reject" returning Void.
    public func rejectHallucinated(taskId: String) async throws {
        // Best-effort comment first so the audit trail records the
        // rejection. A failure here shouldn't block the archive — log
        // and continue.
        do {
            try await comment(
                taskId: taskId,
                text: "Rejected as hallucinated (no underlying work).",
                author: nil
            )
        } catch {
            #if canImport(os)
            Self.logger.warning("kanban reject: comment failed, proceeding to archive (\(error.localizedDescription, privacy: .public))")
            #endif
        }
        try await archive(taskIds: [taskId])
    }

    // MARK: - Drag-drop transition mapper

    /// Map a board-level column transition to the right Hermes verb call.
    /// Returns the list of CLI invocations the caller should run in order.
    /// Pure — no I/O. Called from VMs to build an action plan; the VM
    /// then either prompts the user (e.g. for a block reason) or calls
    /// the matching `KanbanService` methods.
    ///
    /// Forbidden transitions throw `KanbanError.forbiddenTransition`
    /// rather than returning an empty plan, so callers can surface the
    /// reason to the user.
    public nonisolated static func plan(
        for transition: KanbanTransition
    ) throws -> KanbanTransitionPlan {
        let from = transition.from
        let to = transition.to
        if from == to {
            return KanbanTransitionPlan(steps: [])
        }

        // "Done" is terminal — Hermes has no `reopen` verb.
        if from == .done {
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "Done is terminal — create a follow-up task to continue work."
            )
        }

        // Triage promotion isn't a CLI verb in v0.12 — it happens via
        // a specifier worker. UI should disallow drag from triage.
        if from == .triage {
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "Triage tasks are promoted by a specifier agent. Use the specifier worker pipeline."
            )
        }

        // Archive lives outside the board — only via context menu.
        if to == .archived {
            return KanbanTransitionPlan(steps: [.archive])
        }

        // v0.15: Scheduled is reached via the explicit Schedule action,
        // not by dragging a card onto the column.
        if to == .scheduled {
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "Scheduled tasks are parked via the Schedule action."
            )
        }

        // v0.15: Review is owned by the dispatcher — work lands there
        // automatically when a worker completes, not by a drag.
        if to == .review {
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "Review is managed by the dispatcher."
            )
        }

        switch (from, to) {
        case (.upNext, .running):
            return KanbanTransitionPlan(steps: [.dispatch])
        case (.upNext, .blocked):
            return KanbanTransitionPlan(steps: [.block(reasonRequired: true)])
        case (.upNext, .done):
            // Direct todo→done is unusual but allowed (manual checkoff).
            return KanbanTransitionPlan(steps: [.complete(resultRequired: false)])
        case (.running, .blocked):
            return KanbanTransitionPlan(steps: [.block(reasonRequired: true)])
        case (.running, .done):
            return KanbanTransitionPlan(steps: [.complete(resultRequired: false)])
        case (.running, .upNext):
            // Release back to ready — no direct verb. Closest is unblock,
            // which only works for blocked tasks. Forbid for now.
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "Use the inspector's Comment + Unassign actions to hand a running task back."
            )
        case (.blocked, .upNext):
            return KanbanTransitionPlan(steps: [.unblock])
        case (.blocked, .running):
            return KanbanTransitionPlan(steps: [.unblock, .dispatch])
        case (.blocked, .done):
            return KanbanTransitionPlan(steps: [.unblock, .complete(resultRequired: false)])
        default:
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "No CLI path exists for this transition."
            )
        }
    }

    // MARK: - CLI invocation

    private nonisolated func runHermes(
        args: [String],
        timeout: TimeInterval
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let context = self.context
        return await Task.detached(priority: .utility) { () -> (Int32, String, String) in
            let transport = context.makeTransport()
            let executable = context.paths.hermesBinary
            do {
                let result = try transport.runProcess(
                    executable: executable,
                    args: args,
                    stdin: nil,
                    timeout: timeout
                )
                return (result.exitCode, result.stdoutString, result.stderrString)
            } catch let error as TransportError {
                let message = error.diagnosticStderr.isEmpty
                    ? (error.errorDescription ?? "transport error")
                    : error.diagnosticStderr
                return (-1, "", message)
            } catch {
                return (-1, "", error.localizedDescription)
            }
        }.value
    }

    private nonisolated func ensureSuccess(
        code: Int32,
        stdout: String,
        stderr: String,
        verb: String
    ) throws {
        guard code != 0 else { return }
        if code == -1 && stderr.lowercased().contains("hermes binary not found") {
            throw KanbanError.cliMissing
        }
        let combined = stderr.isEmpty ? stdout : stderr
        #if canImport(os)
        Self.logger.warning("kanban \(verb) exit=\(code, privacy: .public) stderr=\(combined, privacy: .public)")
        #endif
        throw KanbanError.nonZeroExit(code: code, stderr: combined)
    }
}

// MARK: - Transition planning

/// Source/destination columns for a single drag-drop. Comparable to
/// SwiftUI's `.dropDestination` payload but kept Sendable + Hashable
/// so it can also drive iOS context-menu "Move to…" actions.
public struct KanbanTransition: Sendable, Hashable {
    public let from: KanbanBoardColumn
    public let to: KanbanBoardColumn

    public init(from: KanbanBoardColumn, to: KanbanBoardColumn) {
        self.from = from
        self.to = to
    }
}

/// One Hermes verb call produced by `KanbanService.plan(for:)`. The VM
/// resolves any user-input requirements (block reason, completion
/// result) before invoking the corresponding actor method.
///
/// **Why `.dispatch` and not `.claim`.** `hermes kanban claim` reserves
/// a task atomically and prints the workspace path — but it's a
/// "manual alternative to the dispatcher" that assumes the caller will
/// spawn the worker themselves. Scarf is not a worker host; the
/// gateway-running dispatcher is. Calling `claim` from drag-drop
/// flipped status to `running` without spawning any work, and the
/// task got reclaimed (stale_lock) ~15 minutes later. The right
/// verb is `dispatch`, which causes the dispatcher to spawn workers
/// for every assigned `ready` task in one pass.
public enum KanbanTransitionStep: Sendable, Equatable {
    /// Force a dispatcher pass so the gateway spawns workers for
    /// assigned `ready` tasks. Requires the task have an assignee
    /// — the dispatcher silently skips unassigned tasks.
    case dispatch
    case unblock
    case block(reasonRequired: Bool)
    case complete(resultRequired: Bool)
    case archive
}

public struct KanbanTransitionPlan: Sendable, Equatable {
    public let steps: [KanbanTransitionStep]

    public init(steps: [KanbanTransitionStep]) {
        self.steps = steps
    }

    public var requiresBlockReason: Bool {
        steps.contains { if case .block(true) = $0 { return true } else { return false } }
    }

    public var requiresCompleteResult: Bool {
        steps.contains { if case .complete(true) = $0 { return true } else { return false } }
    }
}
