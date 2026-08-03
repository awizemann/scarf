import Foundation
#if canImport(os)
import os
#endif

/// Async, transport-aware client for `hermes curator …`. Wraps the v0.12
/// verbs (`status / run / pause / resume / pin / unpin / restore`) plus
/// the v0.13 archive surface (`archive / prune / list-archived` and a
/// synchronous-blocking `run`).
///
/// **Concurrency.** Pure-I/O `actor` — no UI state. View models hold a
/// service reference and `await` methods. Each public method dispatches
/// the underlying CLI invocation through `Task.detached(priority:
/// .utility)` so two concurrent reads from the VM don't queue end-to-end
/// on a single thread. Mirrors `KanbanService` shape exactly.
///
/// **Capability gating happens at the call site, not in the service.**
/// `runNow(synchronous:timeout:)` takes a flag from the VM (the VM reads
/// `HermesCapabilities.hasCuratorArchive` to decide). The service stays
/// version-agnostic — only the timeout differs in practice.
public actor CuratorService {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "CuratorService")
    #endif

    private let context: ServerContext

    public init(context: ServerContext) {
        self.context = context
    }

    // MARK: - Reads

    /// Run `hermes curator status` and parse stdout via
    /// `HermesCuratorStatusParser`. Combines the text output with the
    /// on-disk `.curator_state` JSON for richer last-run metadata.
    /// Never throws — a transport failure resolves to `.empty` so the
    /// view always has something to render.
    public func status() async -> HermesCuratorStatus {
        let context = self.context
        return await Task.detached(priority: .utility) { () -> HermesCuratorStatus in
            let textResult = Self.runHermesSync(context: context, args: ["curator", "status"], timeout: 30)
            let stateData = context.readData(context.paths.curatorStateFile)
            return HermesCuratorStatusParser.parse(text: textResult.output, stateFileJSON: stateData)
        }.value
    }

    /// `hermes curator list-archived`. Hermes has no `--json` flag on
    /// this verb (re-verified against v0.16 — it prints text), so we
    /// parse the text output directly. Empty / "no archived skills"
    /// sentinel folds to `[]`.
    public func listArchived() async throws -> [HermesCuratorArchivedSkill] {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "list-archived"], timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "list-archived")

        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().contains("no archived skills") {
            return []
        }
        return Self.parseListArchivedText(stdout)
    }

    /// `hermes curator list-unmanaged` (v0.20+, caller gates on
    /// `hasCuratorAdopt`). Text output only — header `unmanaged skills
    /// (N):`, one indented row per skill, and a trailing adopt hint.
    /// The no-unmanaged sentinel folds to `[]`.
    public func listUnmanaged() async throws -> [HermesCuratorUnmanagedSkill] {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "list-unmanaged"], timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "list-unmanaged")
        return Self.parseListUnmanaged(stdout)
    }

    // MARK: - Writes (legacy v0.12 verbs; service form)

    public func runNow(synchronous: Bool, timeout: TimeInterval) async throws {
        let resolvedTimeout = synchronous ? timeout : 30
        let (code, stdout, stderr) = await runHermes(args: ["curator", "run"], timeout: resolvedTimeout)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "run")
    }

    public func pause() async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "pause"], timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "pause")
    }

    public func resume() async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "resume"], timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "resume")
    }

    public func pin(_ name: String) async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "pin", name], timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "pin")
    }

    public func unpin(_ name: String) async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "unpin", name], timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "unpin")
    }

    public func restore(_ name: String) async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "restore", name], timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "restore")
    }

    // MARK: - Writes (new in v0.13)

    /// `hermes curator archive <name>` — non-destructive; moves the
    /// skill from the active set to the archived set. No `--json` is
    /// expected; the verb's success channel is the exit code.
    public func archive(_ name: String) async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "archive", name], timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "archive")
    }

    /// `hermes curator prune [--days N]` — **bulk-archives** agent-created
    /// skills idle for ≥ `days` (default 90). This is NOT a disk deletion:
    /// archived skills move out of the active set and stay restorable. Pinned
    /// and already-archived skills are skipped. `--dry-run` previews the
    /// candidate list; the live run passes `-y` so it doesn't block on the
    /// CLI's interactive `[y/N]` confirm — Scarf gates on its own confirm
    /// sheet instead. (Hermes has no `--json` for this verb; we parse text.)
    @discardableResult
    public func prune(days: Int = 90, dryRun: Bool) async throws -> CuratorPruneSummary {
        var args = ["curator", "prune", "--days", String(days)]
        args.append(dryRun ? "--dry-run" : "-y")
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 60)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "prune")
        return Self.parsePrune(stdout, days: days)
    }

    // MARK: - Writes (new in v0.20 — caller gates on hasCuratorAdopt)

    /// `hermes curator adopt <name> --yes` — hands one unmanaged skill to
    /// the curator (provenance is a user declaration; reversible only by
    /// editing the usage record). `--yes` is passed unconditionally: the
    /// CLI's confirmation prompt is interactive `[y/N]` and Scarf can't
    /// answer prompts — Scarf gates on its own UI confirm instead.
    public func adopt(name: String) async throws {
        let (code, stdout, stderr) = await runHermes(
            args: ["curator", "adopt", name, "--yes"],
            timeout: 30
        )
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "adopt")
    }

    /// `hermes curator adopt --all-unmanaged [--dry-run] --yes` — adopts
    /// every curation-eligible unmanaged skill. Same `--yes` rationale as
    /// `adopt(name:)`. Returns raw stdout (the adopted / would-adopt list)
    /// for display; callers preview with `dryRun: true` first.
    @discardableResult
    public func adoptAll(dryRun: Bool) async throws -> String {
        var args = ["curator", "adopt", "--all-unmanaged", "--yes"]
        if dryRun { args.append("--dry-run") }
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 60)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "adopt")
        return stdout
    }

    // MARK: - Pure parsers (nonisolated; safe to call from VMs without awaits)

    /// Parse a `list-archived --json` payload. Tolerates the bare-array
    /// shape, the `{"archived": [...]}` envelope, and "no archived
    /// skills" / empty-string sentinels. Returns `[]` for any of the
    /// empty cases. Throws `CuratorError.decoding` only when the input
    /// is non-empty and clearly not JSON.
    public nonisolated static func parseListArchived(stdout: String) throws -> [HermesCuratorArchivedSkill] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().contains("no archived skills") {
            return []
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw CuratorError.decoding(verb: "list-archived", message: "non-UTF8 stdout")
        }
        if let arr = try? JSONDecoder().decode([HermesCuratorArchivedSkill].self, from: data) {
            return arr
        }
        struct Wrapper: Decodable { let archived: [HermesCuratorArchivedSkill] }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return wrapped.archived
        }
        // Last resort: text fallback.
        let parsed = parseListArchivedText(stdout)
        if !parsed.isEmpty {
            return parsed
        }
        throw CuratorError.decoding(verb: "list-archived", message: "stdout was neither JSON nor a recognised text list")
    }

    /// Defensive text parser for `list-archived` output when `--json`
    /// isn't supported. Format inferred from `curator status`: one row
    /// per non-blank line, leading whitespace, name in column 1, then
    /// optional `archived=YYYY-MM-DD`, `size=NNNN`, `reason=...` k/v
    /// pairs. Blank lines, header lines, and the empty-state sentinel
    /// are skipped.
    public nonisolated static func parseListArchivedText(_ text: String) -> [HermesCuratorArchivedSkill] {
        var rows: [HermesCuratorArchivedSkill] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            // Skip header / sentinel lines.
            if lower.hasPrefix("name") && lower.contains("archived") { continue }
            if lower.contains("no archived skills") { continue }
            if line.unicodeScalars.allSatisfy({ $0.value == 0x2500 || $0.properties.isWhitespace }) {
                continue
            }
            // Skip lines that look like JSON / non-row chrome — `{`,
            // `}`, `[`, `]` at the start or quotes / colons mean we're
            // parsing a malformed JSON dump, not a row table.
            if let first = line.first, "{[}]\":,".contains(first) {
                continue
            }
            // Find the first whitespace-separated token as the name; if
            // the name carries an `=` it's a header chip we should skip.
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard let name = parts.first, !name.contains("=") else { continue }
            // Reject names that look like punctuation / JSON fragments.
            if name.contains("\"") || name.contains(":") || name.contains("{") || name.contains("}") || name.contains("[") || name.contains("]") {
                continue
            }
            // Pull k=v pairs from the remainder.
            var archivedAt: String?
            var sizeBytes: Int?
            var reason: String?
            var category: String?
            var path: String?
            for token in parts.dropFirst() {
                guard let eq = token.firstIndex(of: "=") else { continue }
                let key = String(token[..<eq])
                let value = String(token[token.index(after: eq)...])
                switch key {
                case "archived", "archived_at":
                    archivedAt = value
                case "size", "size_bytes":
                    sizeBytes = Int(value)
                case "reason":
                    reason = value
                case "category":
                    category = value
                case "path":
                    path = value
                default:
                    continue
                }
            }
            rows.append(
                HermesCuratorArchivedSkill(
                    name: name,
                    category: category,
                    archivedAt: archivedAt,
                    reason: reason,
                    sizeBytes: sizeBytes,
                    path: path
                )
            )
        }
        return rows
    }

    /// Parse `hermes curator list-unmanaged` stdout (verified live on
    /// v0.20.0):
    ///
    ///     unmanaged skills (50):
    ///       find-nearby     activity=   0  last_activity=never    (no marker)
    ///       godmode         activity=   0  last_activity=never    (created_by:null)
    ///
    ///     adopt one with `hermes curator adopt <name>`, or all with …
    ///
    /// Rows are the lines carrying `activity=`; the header, footer hint,
    /// and any empty sentinel are skipped. Names may contain spaces —
    /// the name is everything before `activity=`.
    public nonisolated static func parseListUnmanaged(_ stdout: String) -> [HermesCuratorUnmanagedSkill] {
        var rows: [HermesCuratorUnmanagedSkill] = []
        for raw in stdout.components(separatedBy: .newlines) {
            guard let activityRange = raw.range(of: "activity=") else { continue }
            let name = String(raw[..<activityRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            var remainder = String(raw[activityRange.upperBound...])
            let activityDigits = remainder
                .drop(while: { $0 == " " })
                .prefix(while: { $0.isNumber })
            let activity = Int(activityDigits) ?? 0

            var lastActivity = ""
            if let laRange = remainder.range(of: "last_activity=") {
                remainder = String(remainder[laRange.upperBound...])
                // Label runs until the marker parenthetical (or EOL).
                if let paren = remainder.firstIndex(of: "(") {
                    lastActivity = String(remainder[..<paren]).trimmingCharacters(in: .whitespaces)
                } else {
                    lastActivity = remainder.trimmingCharacters(in: .whitespaces)
                }
            }

            var marker = ""
            if let open = remainder.firstIndex(of: "("),
               let close = remainder[open...].firstIndex(of: ")") {
                marker = String(remainder[remainder.index(after: open)..<close])
            }

            rows.append(
                HermesCuratorUnmanagedSkill(
                    name: name,
                    activityCount: activity,
                    lastActivityLabel: lastActivity,
                    markerLabel: marker
                )
            )
        }
        return rows
    }

    /// Parse `hermes curator prune [--days N] [--dry-run]` text output into the
    /// idle skills it (would) archive. The CLI prints:
    ///
    ///     curator: 3 skill(s) idle >= 90d:
    ///       old-helper       idle 412d
    ///       scratch-pad      idle 120d
    ///     (dry run — no changes made)
    ///
    /// and `curator: nothing to prune (...)` when nothing is idle. Candidate
    /// rows are indented (`  <name> … idle <N>d`); the column-0 header/footer
    /// lines ("curator: …", "(dry run …)", "curator: archived N/M") are
    /// ignored. `days` is the request threshold, threaded through unchanged.
    public nonisolated static func parsePrune(_ stdout: String, days: Int) -> CuratorPruneSummary {
        var candidates: [CuratorPruneCandidate] = []
        // Split on the newline CHARACTER SET (not just "\n") so a CRLF host's
        // trailing CR is consumed as a separator and never rides along into the
        // `idle <N>d` suffix parse below.
        for raw in stdout.components(separatedBy: .newlines) {
            // Candidate rows are indented; headers/footers start at column 0.
            guard let first = raw.first, first == " " || first == "\t" else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Shape: "<name>   idle <N>d" — split on the last " idle " token so
            // a name is never confused for the idle suffix.
            guard let r = trimmed.range(of: " idle ", options: .backwards) else { continue }
            let name = String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            var idlePart = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if idlePart.hasSuffix("d") { idlePart.removeLast() }
            guard !name.isEmpty, let idle = Int(idlePart) else { continue }
            candidates.append(CuratorPruneCandidate(name: name, idleDays: idle))
        }
        return CuratorPruneSummary(candidates: candidates, days: days)
    }

    // MARK: - CLI invocation

    private nonisolated func runHermes(
        args: [String],
        timeout: TimeInterval
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let context = self.context
        return await Task.detached(priority: .utility) { () -> (Int32, String, String) in
            let result = Self.runHermesSync(context: context, args: args, timeout: timeout)
            return (result.exitCode, result.output, result.stderr)
        }.value
    }

    /// Synchronous, transport-level invocation. `output` is stdout; the
    /// caller usually only reads `output` for parser input but sometimes
    /// needs `stderr` (e.g. to detect "unrecognized argument" patterns).
    private nonisolated static func runHermesSync(
        context: ServerContext,
        args: [String],
        timeout: TimeInterval
    ) -> (exitCode: Int32, output: String, stderr: String) {
        let transport = context.makeTransport()
        do {
            let result = try transport.runProcess(
                executable: context.paths.hermesBinary,
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
    }

    private nonisolated func ensureSuccess(
        code: Int32,
        stdout: String,
        stderr: String,
        verb: String
    ) throws {
        guard code != 0 else { return }
        if code == -1 && stderr.lowercased().contains("hermes binary not found") {
            throw CuratorError.cliMissing
        }
        let combined = stderr.isEmpty ? stdout : stderr
        #if canImport(os)
        Self.logger.warning("curator \(verb) exit=\(code, privacy: .public) stderr=\(combined, privacy: .public)")
        #endif
        throw CuratorError.nonZeroExit(verb: verb, code: code, stderr: combined)
    }
}
