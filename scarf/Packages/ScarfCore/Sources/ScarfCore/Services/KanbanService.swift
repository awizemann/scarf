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
///   Mutations after create are state transitions (assign / dispatch /
///   complete / block / unblock / archive) or new comments. `claim` is
///   deliberately not wrapped — see `KanbanTransitionStep`'s doc.
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
        KanbanService.prefix(board: board, verbAndArgs)
    }

    /// Pure form of `prefix(_:)`. The argv builders below are `static` so
    /// the exact command line can be asserted in tests without a live
    /// transport — `KanbanService` has no injection seam, and the argv
    /// shape is precisely what the F5 audit found wrong.
    nonisolated static func prefix(board: String?, _ verbAndArgs: [String]) -> [String] {
        var args = ["kanban"]
        if let board, !board.isEmpty {
            args.append(HermesCLIOption.joined("--board", board))
        }
        args.append(contentsOf: verbAndArgs)
        return args
    }

    /// argv for `hermes kanban promote`. See `promote(taskIds:…)` for the
    /// verified argparse shape this encodes.
    nonisolated static func promoteArgv(
        board: String? = nil,
        taskIds: [String],
        reason: String? = nil,
        force: Bool = false,
        dryRun: Bool = false
    ) -> [String] {
        guard let first = taskIds.first else { return [] }
        var args = prefix(board: board, ["promote"])
        // Flags FIRST, then `--`, then the positionals — argparse consumes
        // everything after the first `--` as a positional, so `--json` /
        // `--force` behind it would be rejected as "unrecognized arguments".
        if force { args.append("--force") }
        if dryRun { args.append("--dry-run") }
        args.append("--json")
        let rest = Array(taskIds.dropFirst())
        if !rest.isEmpty {
            // `--ids` is `nargs="+"`; the `--` that follows terminates its
            // greedy consumption, so the trailing positionals stay
            // positional. (`--ids` must sit last among the flags for that
            // reason.)
            args.append("--ids")
            args.append(contentsOf: rest)
        }
        args.append("--")
        args.append(first)
        if let reason, !reason.isEmpty {
            // ONE argv element. `_cmd_promote` re-joins `reason` with
            // spaces, so splitting here would only destroy runs of
            // whitespace and let argparse claim a dash-leading word.
            args.append(reason)
        }
        return args
    }

    /// argv for `hermes kanban schedule` — same argparse shape as
    /// `promote` (one positional id, `reason` `nargs="*"`, `--ids`).
    nonisolated static func scheduleArgv(
        board: String? = nil,
        taskIds: [String],
        reason: String? = nil
    ) -> [String] {
        guard let first = taskIds.first else { return [] }
        var args = prefix(board: board, ["schedule"])
        let rest = Array(taskIds.dropFirst())
        if !rest.isEmpty {
            args.append("--ids")
            args.append(contentsOf: rest)
        }
        args.append("--")
        args.append(first)
        if let reason, !reason.isEmpty {
            args.append(reason)
        }
        return args
    }

    /// argv for `hermes kanban assignees --json`.
    nonisolated static func assigneesArgv(board: String? = nil) -> [String] {
        prefix(board: board, ["assignees", "--json"])
    }

    /// argv for `hermes kanban list` under a given filter.
    nonisolated static func listArgv(board: String? = nil, filter: KanbanListFilter) -> [String] {
        prefix(board: board, ["list"]) + filter.argv()
    }

    // MARK: - Reads

    public func list(_ filter: KanbanListFilter = .all) async throws -> [HermesKanbanTask] {
        let args = KanbanService.listArgv(board: board, filter: filter)
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

    /// argv for `hermes kanban diagnostics --json`. Fleet mode (no
    /// `--task`) returns every non-archived task that has at least one
    /// active signal, so ONE call feeds a whole board load.
    /// `hermes_cli/kanban_parser.py:251-256` (v2026.9.7); the same
    /// subcommand + `--json` shape has existed unchanged since v2026.5.7
    /// (`hermes_cli/kanban.py:1365-1375` there, `:678-681` at v2026.9.7),
    /// and v0.13 is the `hasKanbanDiagnostics` floor — callers MUST gate on
    /// that flag.
    nonisolated static func diagnosticsArgv(board: String? = nil, taskId: String? = nil) -> [String] {
        var args = ["diagnostics", "--json"]
        if let taskId, !taskId.isEmpty {
            args.append(HermesCLIOption.joined("--task", taskId))
        }
        return prefix(board: board, args)
    }

    /// Active diagnostics keyed by task id. Gate the call site on
    /// `HermesCapabilities.hasKanbanDiagnostics` — a pre-v0.13 argparse
    /// has no `diagnostics` subcommand and Hermes routes an unknown
    /// kanban verb to the agent (charter C5).
    ///
    /// Returns `[:]` when the board is healthy: fleet mode prints `[]`.
    public func diagnostics(taskId: String? = nil) async throws -> [String: [HermesKanbanDiagnostic]] {
        let args = KanbanService.diagnosticsArgv(board: board, taskId: taskId)
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 20)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "diagnostics")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            let entries = try JSONDecoder().decode([HermesKanbanDiagnosticsEntry].self, from: data)
            return Dictionary(
                entries.map { ($0.taskId, $0.diagnostics) },
                uniquingKeysWith: { $1 }
            ).filter { !$0.value.isEmpty }
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
            args.append(HermesCLIOption.joined("--tail", String(tailBytes)))
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

    /// Known profiles + per-profile task counts —
    /// `hermes kanban assignees --json`.
    ///
    /// **`--json` needs no capability gate.** `p_asg.add_argument("--json",
    /// action="store_true")` is present at every tag that ships the
    /// `assignees` subcommand at all: v2026.5.7 (v0.13.0) through
    /// v2026.8.31 (v0.21.0). v2026.4.30 (v0.12.0) has no `hermes_cli/
    /// kanban.py` whatsoever, so a host old enough to reject the flag is
    /// a host with no kanban CLI at all.
    ///
    /// The human table used to be parsed instead, which produced
    /// all-zero counts (the text row is `name  on-disk  status=n, …`,
    /// never `name active total`) plus a phantom `NAME` row from the
    /// header. There is no text fallback any more: `--json` is always
    /// accepted, so a payload we cannot decode is a real failure and is
    /// thrown rather than rendered as an empty picker.
    public func assignees() async throws -> [HermesKanbanAssignee] {
        let args = KanbanService.assigneesArgv(board: board)
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "assignees")

        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode([HermesKanbanAssignee].self, from: data)
        } catch {
            throw KanbanError.decoding(message: error.localizedDescription)
        }
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

    public func comment(taskId: String, text: String, author: String? = nil) async throws {
        var args = prefix("comment")
        if let author, !author.isEmpty {
            args.append(HermesCLIOption.joined("--author", author))
        }
        // `--` last, after every flag: argparse treats EVERY token after the
        // first `--` as a positional, so a flag behind it would be eaten as
        // an extra positional. `text` is `nargs="+"` — one argv element is a
        // one-word list the CLI joins, so the whole comment stays intact.
        args.append(contentsOf: ["--", taskId, text])
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "comment")
    }

    /// The exact argv `complete` runs. `static`, like `listArgv` /
    /// `promoteArgv` / `diagnosticsArgv`, so a test asserts the PRODUCTION
    /// command line rather than a parallel builder that can drift from it.
    nonisolated static func completeArgv(
        board: String? = nil,
        taskIds: [String],
        result: String? = nil,
        summary: String? = nil,
        metadataJSON: String? = nil
    ) -> [String] {
        var args = prefix(board: board, ["complete"])
        // Every option value goes over as ONE `--flag=value` token: `--result`
        // and `--summary` are free-text fields a user fills in
        // (`hermes_cli/kanban_parser.py:280-283` @ `v2026.9.7`, plain
        // `add_argument`s), and a value beginning with `-` handed over as a
        // separate token is `error: expected one argument`, exit 2.
        if let result, !result.isEmpty {
            args.append(HermesCLIOption.joined("--result", result))
        }
        if let summary, !summary.isEmpty {
            args.append(HermesCLIOption.joined("--summary", summary))
        }
        if let metadataJSON, !metadataJSON.isEmpty {
            args.append(HermesCLIOption.joined("--metadata", metadataJSON))
        }
        // `--` before the ids, exactly as `unblock` does. `task_ids` is a
        // `nargs="+"` POSITIONAL (`hermes_cli/kanban_parser.py:279` @
        // `v2026.9.7`), so an id that begins with a dash is read as an
        // unknown option and argparse exits 2 on the whole verb. Nothing that
        // must stay an option can be stranded behind the marker, because
        // every option above is now a single token.
        args.append("--")
        args.append(contentsOf: taskIds)
        return args
    }

    public func complete(
        taskIds: [String],
        result: String? = nil,
        summary: String? = nil,
        metadataJSON: String? = nil
    ) async throws {
        guard !taskIds.isEmpty else { return }
        let args = Self.completeArgv(
            board: board, taskIds: taskIds, result: result,
            summary: summary, metadataJSON: metadataJSON)
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
        // `unblock` is the one bulk verb whose ids really are one
        // `nargs="+"` positional (`p_unblock.add_argument("task_ids",
        // nargs="+")`), so every id goes positionally. `--` still guards
        // against an id that starts with a dash.
        var args = prefix("unblock")
        args.append("--")
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "unblock")
    }

    /// The exact argv `reopen-review` runs — `static` for the same reason
    /// `completeArgv` is: the test asserts the PRODUCTION command line.
    ///
    /// `task_ids` is a `nargs="+"` positional and `--reason` a plain
    /// `add_argument` (`hermes_cli/kanban_parser.py:323-326` @ `v2026.9.7`),
    /// so this is the `unblock` shape, not the `archive` one: exactly ONE
    /// list-valued parser, which is what makes `--` safe here (P54's
    /// counter-example is `archive`, whose `--rm` would be starved by the
    /// separator). The reason goes over as a single `--reason=…` token so a
    /// value beginning with `-` is not read as the next flag.
    ///
    /// Refusals exit 1: `_cmd_reopen_review` (`hermes_cli/kanban.py:990-1008`)
    /// returns `_bulk_apply`'s verdict, which is `1 if failed`
    /// (`hermes_cli/kanban_output.py:61-69`) and prints `cannot reopen <id>
    /// (not in review?)` on stderr. So the exit code IS the verdict here and
    /// `ensureSuccess` needs no output judging (charter C5).
    nonisolated static func reopenReviewArgv(
        board: String? = nil, taskIds: [String], reason: String? = nil
    ) -> [String] {
        var args = prefix(board: board, ["reopen-review"])
        if let reason, !reason.trimmingCharacters(in: .whitespaces).isEmpty {
            args.append(HermesCLIOption.joined("--reason", reason))
        }
        args.append("--")
        args.append(contentsOf: taskIds)
        return args
    }

    /// `review -> ready|todo` — send a task back to its implementer.
    /// **Callers must gate on `HermesCapabilities.hasKanbanReviewExits`**
    /// (v0.20.1); the verb does not exist below it and Hermes routes an
    /// unknown `kanban` verb to the agent (charter C5).
    public func reopenReview(taskIds: [String], reason: String? = nil) async throws {
        guard !taskIds.isEmpty else { return }
        let args = Self.reopenReviewArgv(board: board, taskIds: taskIds, reason: reason)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "reopen-review")
    }

    /// Same `--` guard as `complete`/`unblock`: `task_ids` is `nargs="*"`
    /// here (`hermes_cli/kanban_parser.py:336` @ `v2026.9.7`).
    nonisolated static func archiveArgv(board: String? = nil, taskIds: [String]) -> [String] {
        prefix(board: board, ["archive"]) + ["--"] + taskIds
    }

    public func archive(taskIds: [String]) async throws {
        guard !taskIds.isEmpty else { return }
        let args = Self.archiveArgv(board: board, taskIds: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "archive")
    }

    @discardableResult
    public func dispatch(maxTasks: Int? = nil, dryRun: Bool = false) async throws -> KanbanDispatchSummary {
        var args = prefix("dispatch", "--json")
        if dryRun { args.append("--dry-run") }
        if let maxTasks { args.append(HermesCLIOption.joined("--max", String(maxTasks))) }
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 60)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "dispatch")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode(KanbanDispatchSummary.self, from: data)
        } catch {
            // NO stub summary. `--json` is always on this argv, so a payload
            // we can't decode means the pass didn't run the way we think it
            // did — and a zero-everything stub renders identically to a
            // dispatcher pass that legitimately promoted nothing. Surface
            // the failure instead; the caller shows an error banner.
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    // MARK: - v0.15 verbs

    /// Promote `todo`/`blocked` tasks to `ready` so the dispatcher can
    /// pick them up — `hermes kanban promote`.
    ///
    /// **The bulk shape is `--ids`, not extra positionals.** Verified at
    /// `v2026.8.31`, `hermes_cli/kanban.py`:
    ///
    /// ```python
    /// p_promote.add_argument("task_id")
    /// p_promote.add_argument("reason", nargs="*", …)
    /// p_promote.add_argument("--ids", nargs="+", default=None, …)
    /// ```
    ///
    /// There is exactly ONE positional id; everything after it is swept
    /// into `reason`, which `_cmd_promote` does `" ".join(args.reason)`
    /// on. Passing `[a, b, c]` positionally therefore promoted only `a`
    /// and wrote `"b c"` into the audit-trail reason on the
    /// `task_events` row — silently, exit 0. So: first id positional,
    /// the rest under `--ids`.
    ///
    /// argv order (see the F2 `--` rule): every flag, then `--ids …`,
    /// then `--`, then the single positional id, then the reason as ONE
    /// argv element (never space-split — the CLI re-joins it).
    public func promote(
        taskIds: [String],
        reason: String? = nil,
        force: Bool = false,
        dryRun: Bool = false
    ) async throws {
        guard !taskIds.isEmpty else { return }
        let args = KanbanService.promoteArgv(
            board: board, taskIds: taskIds, reason: reason, force: force, dryRun: dryRun
        )
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "promote")
    }

    /// Park tasks in the `scheduled` status — `hermes kanban schedule`.
    /// They await a later trigger (workflow step, manual promote, etc.)
    /// instead of being eligible for dispatch.
    ///
    /// Same argparse shape as `promote` (verified at `v2026.8.31`):
    /// `p_schedule.add_argument("task_id")` + `reason` `nargs="*"` +
    /// `--ids` `nargs="+"`, so bulk ids go under `--ids` or they land in
    /// the reason text.
    public func schedule(taskIds: [String], reason: String? = nil) async throws {
        guard !taskIds.isEmpty else { return }
        let args = KanbanService.scheduleArgv(board: board, taskIds: taskIds, reason: reason)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "schedule")
    }

    /// Hard-delete already-archived tasks — `hermes kanban archive --rm
    /// <ids…>`. There's no separate `purge` verb; the `--rm` flag on
    /// `archive` performs the destructive removal. Only valid on tasks
    /// already in `archived`.
    ///
    /// **No `--` here, deliberately** (P54, round-6). The round-6 report
    /// listed this beside `archiveArgv`'s separator as `--` residue; it is
    /// not. `archive` carries BOTH `task_ids` (`nargs="*"`) and
    /// `--rm`/`purge_ids` (`nargs="+"`) — `hermes_cli/kanban_parser.py:335-338`
    /// @ `v2026.9.7` — and argparse's `--` ends option parsing, so
    /// `archive --rm -- a b` hands `a b` to the POSITIONAL `task_ids` and
    /// leaves `--rm` with none. That is either an exit-2 "expected at least
    /// one argument" or, worse, a silent ARCHIVE where the user asked for a
    /// permanent delete. `archiveArgv` (the non-`--rm` form) takes the
    /// separator precisely because `task_ids` is the only consumer there.
    ///
    /// A task id beginning with a dash is therefore still unreachable on
    /// this one verb. Hermes generates the ids, so none does today, and
    /// there is no argparse spelling that would fix it — the separator is
    /// the wrong tool, not a missing one.
    public func purge(taskIds: [String]) async throws {
        guard !taskIds.isEmpty else { return }
        var args = prefix("archive", "--rm")
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "purge")
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
    /// `caps` has NO default: it IS the fix (addendum lesson 10). A default
    /// would let a call site silently take `.empty` and hide the Review
    /// column's two exits on a host that has them.
    public nonisolated static func plan(
        for transition: KanbanTransition,
        caps: HermesCapabilities
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

        // Round-6 decision 6 — the Review column used to be a dead end in
        // BOTH directions: `to == .review` is refused above (the dispatcher
        // owns entry), and every drag OUT fell through to the `default:` arm
        // below, which says "No CLI path exists for this transition." That
        // was false on any host at or above v0.20.1. Both doors are real:
        //
        // - `review -> done`: `complete_task`'s UPDATE takes
        //   `status IN ('running', 'ready', 'blocked', 'review')`
        //   (`hermes_cli/kanban_db.py` @ `v2026.8.13`; the clause is the
        //   three-status form at `v2026.8.3`, which is why the floor is
        //   v0.20.1 and not `hasKanbanV015` — see `hasKanbanReviewExits`).
        // - `review -> upNext`: `reopen_review_task`
        //   (`kanban_db.py:3295-3328` @ `v2026.9.7`) moves `review` to
        //   `_landing_status_after_parents`, i.e. `ready` or `todo` — both
        //   of which this board collapses into Up Next.
        //
        // Below the floor the honest refusal stands, worded so the user
        // knows it is the HOST and not the gesture.
        if from == .review, to == .done || to == .upNext {
            // The version refusal is scoped to the two destinations the gate
            // is ABOUT. Raising it for `review -> blocked` too would name an
            // upgrade that does not help: `block_task` updates only rows
            // `WHERE … AND status IN ('running', 'ready')`
            // (`hermes_cli/kanban_db.py:2929` @ `v2026.9.7`) at every tag,
            // the same reason `scheduled -> blocked` is absent — so that one
            // falls through to the `default:` refusal on EVERY host, as it
            // should. Inventing a two-step for it would land the card
            // somewhere the user did not drop it.
            guard caps.hasKanbanReviewExits else {
                throw KanbanError.forbiddenTransition(
                    from: from.displayName,
                    to: to.displayName,
                    reason: "Moving a task out of Review needs Hermes v0.20.1 or newer. Approve or reopen it from the Hermes CLI on the host."
                )
            }
            return to == .done
                ? KanbanTransitionPlan(steps: [.complete(resultRequired: false)])
                : KanbanTransitionPlan(steps: [.reopenReview])
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
        // `scheduled` is a SOURCE state for `unblock`, exactly like
        // `blocked`. Verified at v2026.8.31 — `p_unblock`'s help reads
        // "Return blocked/scheduled tasks to ready…" and `_cmd_unblock`
        // fails with "cannot unblock <id> (not blocked/scheduled?)". The
        // planner omitted it, so dragging a parked card anywhere threw
        // "No CLI path exists for this transition" even though one does.
        case (.scheduled, .upNext):
            return KanbanTransitionPlan(steps: [.unblock])
        case (.scheduled, .running):
            return KanbanTransitionPlan(steps: [.unblock, .dispatch])
        case (.scheduled, .done):
            return KanbanTransitionPlan(steps: [.unblock, .complete(resultRequired: false)])
        // No `scheduled → blocked`: `kanban_db.block_task` only updates
        // rows `WHERE status IN ('running', 'ready')`, so blocking a
        // parked task returns False and prints "cannot block <id>".
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
    /// `review -> ready|todo`. Gated: see
    /// `HermesCapabilities.hasKanbanReviewExits`.
    case reopenReview
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
