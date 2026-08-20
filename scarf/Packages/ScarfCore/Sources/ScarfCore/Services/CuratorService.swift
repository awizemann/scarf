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

    // MARK: - Reads (new in v0.20.4 — caller gates on hasCuratorLedger)

    /// `hermes curator ledger [--skill N] [--limit N]` — the per-mutation
    /// audit trail (curator/agent/user actions), newest first. Text-only
    /// verb (no `--json`); `limit` mirrors the CLI's own default of 20 when
    /// `nil` so an unset value still bounds the request.
    public func ledger(skill: String? = nil, limit: Int? = nil) async throws -> [HermesCuratorLedgerEntry] {
        var args = ["curator", "ledger"]
        if let skill { args += ["--skill", skill] }
        args += ["--limit", String(limit ?? 20)]
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "ledger")
        return Self.parseLedger(stdout)
    }

    // MARK: - Writes (new in v0.20.4 — caller gates on hasCuratorPurge)

    /// `hermes curator purge [--days N] [--dry-run] [-y]` — **permanently
    /// deletes** archived skills past `curator.archive_ttl_days` (or the
    /// explicit `days` override). This is disk deletion, unlike `prune`
    /// (archive-only, reversible) — never conflate the two. `-y` is passed
    /// unconditionally on a live run for the same reason `prune`/`adopt`
    /// do: Hermes's confirmation prompt is interactive `[y/N]` and Scarf
    /// can't answer it — Scarf's own destructive-confirm sheet gates the
    /// call instead. When Hermes reports the verb as disabled (TTL is 0 and
    /// no override was given), the exit code is non-zero but this is a
    /// legitimate "nothing to do, here's why" response, not a transport
    /// failure — it's surfaced via `disabledReason` rather than a thrown
    /// error.
    @discardableResult
    public func purge(days: Int? = nil, dryRun: Bool) async throws -> CuratorPurgeSummary {
        var args = ["curator", "purge"]
        if let days { args += ["--days", String(days)] }
        args.append(dryRun ? "--dry-run" : "-y")
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 60)
        if let disabled = Self.parsePurgeDisabled(stdout) {
            return CuratorPurgeSummary(candidates: [], days: days, disabledReason: disabled)
        }
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "purge")
        return Self.parsePurge(stdout, days: days)
    }

    // MARK: - Writes (new in v0.20.4 — caller gates on hasCuratorEntryRollback)

    /// `hermes curator rollback <entry_id> -y` — reverts a single ledger
    /// mutation (content-addressed blob restore), distinct from the bare
    /// `hermes curator rollback` whole-tree snapshot form (unchanged,
    /// unmodeled here). `-y` is passed unconditionally for the same
    /// interactive-prompt reason as `purge`/`prune` — Scarf's own confirm
    /// gates the call.
    @discardableResult
    public func rollbackEntry(_ entryID: String) async throws -> CuratorEntryRollbackResult {
        let (code, stdout, stderr) = await runHermes(
            args: ["curator", "rollback", entryID, "-y"],
            timeout: 30
        )
        // A rollback failure ("no ledger entry", "rollback failed — …") is
        // Hermes's success channel reporting a domain failure, not a
        // transport error — parse it into the result rather than throwing,
        // so the UI can show *why* inline. Only a genuinely non-zero exit
        // with no recognizable Hermes response is a thrown transport error.
        if let result = Self.parseRollbackEntry(stdout, entryID: entryID) {
            return result
        }
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "rollback")
        throw CuratorError.decoding(verb: "rollback", message: "unrecognized rollback output")
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

    /// Parse `hermes curator ledger [--skill N] [--limit N]` text output
    /// (`hermes_cli/curator.py:539`, `_cmd_ledger`). Fixed-width columns:
    ///
    ///     id             when         actor    action       skill
    ///     ab12cd34ef56   2026-08-18   curator  archive      old-helper
    ///     cd34ef56ab12   2026-08-17   agent    absorb       scratch-pad  → absorbed into 'notes'
    ///     ef56ab12cd34   2026-08-16   user     rollback     old-helper   → rollback of ab12cd34ef56
    ///
    /// and the empty-state sentinel `curator: ledger is empty (or
    /// skills.ledger is disabled).`. The header row and the trailing
    /// "Roll back a single mutation with …" hint are skipped. Columns are
    /// fixed-width left-justified (`{:<14} {:<12} {:<8} {:<12} skill`), so
    /// we split positionally rather than on whitespace runs — a skill name
    /// may itself contain spaces, and it's always the trailing column.
    public nonisolated static func parseLedger(_ stdout: String) -> [HermesCuratorLedgerEntry] {
        var rows: [HermesCuratorLedgerEntry] = []
        for raw in stdout.components(separatedBy: .newlines) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if line.hasPrefix("id") && line.contains("when") && line.contains("actor") { continue }
            if line.contains("ledger is empty") { continue }
            if line.hasPrefix("Roll back a single mutation") || line.hasPrefix("whole-tree snapshots remain") { continue }

            // Fixed column layout: id<14> " " when<12> " " actor<8> " "
            // action<12> " " skill[+suffix]. Guard against a short/odd
            // line (future Hermes layout change) by falling back to a
            // best-effort whitespace split rather than crashing or
            // silently dropping the row.
            guard line.count >= 50 else {
                if let fallback = parseLedgerRowFallback(line) { rows.append(fallback) }
                continue
            }
            let chars = Array(line)
            let idField = String(chars[0..<14]).trimmingCharacters(in: .whitespaces)
            let whenField = String(chars[15..<27]).trimmingCharacters(in: .whitespaces)
            let actorField = String(chars[28..<36]).trimmingCharacters(in: .whitespaces)
            let actionField = String(chars[37..<49]).trimmingCharacters(in: .whitespaces)
            let rest = String(chars[50...]).trimmingCharacters(in: .whitespaces)
            guard !idField.isEmpty else { continue }

            var skill = rest
            var absorbedInto: String?
            var rollbackTarget: String?
            if let r = rest.range(of: "  → absorbed into '") {
                skill = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                var tail = String(rest[r.upperBound...])
                if let close = tail.firstIndex(of: "'") { tail = String(tail[..<close]) }
                absorbedInto = tail
            } else if let r = rest.range(of: "  → rollback of ") {
                skill = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                rollbackTarget = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            rows.append(
                HermesCuratorLedgerEntry(
                    entryID: idField,
                    whenLabel: whenField,
                    actor: actorField,
                    action: actionField,
                    skill: skill,
                    absorbedInto: absorbedInto,
                    rollbackTarget: rollbackTarget
                )
            )
        }
        return rows
    }

    /// Best-effort fallback for a ledger row shorter than the expected
    /// fixed-width layout — collapses whitespace runs into single
    /// separators. Loses fidelity on skill names containing spaces, but
    /// keeps the row visible instead of dropping it outright.
    private nonisolated static func parseLedgerRowFallback(_ line: String) -> HermesCuratorLedgerEntry? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 5 else { return nil }
        return HermesCuratorLedgerEntry(
            entryID: parts[0],
            whenLabel: parts[1],
            actor: parts[2],
            action: parts[3],
            skill: parts[4...].joined(separator: " ")
        )
    }

    /// `hermes curator purge` prints this exact message and exits non-zero
    /// when `curator.archive_ttl_days` is 0 and no `--days` override was
    /// given. Returns the message verbatim, or `nil` when this isn't that
    /// response.
    public nonisolated static func parsePurgeDisabled(_ stdout: String) -> String? {
        for raw in stdout.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("curator: purge disabled") {
                return line
            }
        }
        return nil
    }

    /// Parse `hermes curator purge [--days N] [--dry-run] [-y]` text output
    /// (`hermes_cli/curator.py:570`, `_cmd_purge`). Shapes:
    ///
    ///     Archived skills older than 90d:
    ///       old-helper
    ///       scratch-pad
    ///     (dry run — nothing deleted)
    ///
    /// or, on a live run:
    ///
    ///     Archived skills older than 90d:
    ///       old-helper
    ///       scratch-pad
    ///     curator: purged 2 archived skill(s). Ledger entries recorded.
    ///
    /// or the no-candidates sentinel `curator: no archived skills older
    /// than {N}d.` / `curator: no archive directory — nothing to purge.`
    /// `days` in the result comes from the request when given, else parsed
    /// out of the header line so a config-default run still reports the
    /// effective threshold.
    public nonisolated static func parsePurge(_ stdout: String, days: Int?) -> CuratorPurgeSummary {
        var candidates: [CuratorPurgeCandidate] = []
        var effectiveDays = days
        var purgedCount: Int?
        for raw in stdout.components(separatedBy: .newlines) {
            if let headerRange = raw.range(of: "Archived skills older than ") {
                let after = raw[headerRange.upperBound...]
                let digits = after.prefix(while: { $0.isNumber })
                if let n = Int(digits) { effectiveDays = n }
                continue
            }
            if raw.hasPrefix("curator: purged ") {
                let after = raw.dropFirst("curator: purged ".count)
                let digits = after.prefix(while: { $0.isNumber })
                purgedCount = Int(digits)
                continue
            }
            guard let first = raw.first, first == " " || first == "\t" else { continue }
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "(dry run — nothing deleted)" else { continue }
            candidates.append(CuratorPurgeCandidate(name: name))
        }
        return CuratorPurgeSummary(candidates: candidates, days: effectiveDays, purgedCount: purgedCount)
    }

    /// Parse `hermes curator rollback <entry_id> [-y]` text output
    /// (`hermes_cli/curator.py:660`, `_cmd_rollback`, single-mutation
    /// branch only — the bare whole-tree form is unchanged and unparsed
    /// here). Success shape:
    ///
    ///     Rollback target: ledger entry ab12cd34ef56
    ///       action: archive
    ///       skill:  old-helper
    ///       actor:  curator
    ///       when:   2026-08-18T10:00:00Z
    ///       files:  3
    ///     curator: restored 3 file(s) from ledger entry ab12cd34ef56
    ///
    /// Unknown-entry failure:
    ///
    ///     curator: no ledger entry 'bogus-id'. See `hermes curator ledger`
    ///     for entry ids, or use `--id <snapshot>` for whole-tree snapshot
    ///     rollback.
    ///
    /// Rollback-mechanism failure:
    ///
    ///     curator: rollback failed — <message>
    ///
    /// Returns `nil` when `stdout` doesn't contain a recognizable `curator:`
    /// response line at all (a genuine transport/exit-code failure, which
    /// the caller surfaces via `ensureSuccess` instead).
    public nonisolated static func parseRollbackEntry(_ stdout: String, entryID: String) -> CuratorEntryRollbackResult? {
        var action: String?
        var skill: String?
        var actor: String?
        var when: String?
        var files: Int?
        var message: String?
        var succeeded = false
        var sawCuratorLine = false

        for raw in stdout.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("action:") {
                action = String(line.dropFirst("action:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("skill:") {
                skill = String(line.dropFirst("skill:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("actor:") {
                actor = String(line.dropFirst("actor:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("when:") {
                when = String(line.dropFirst("when:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("files:") {
                files = Int(line.dropFirst("files:".count).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("curator: rollback failed") {
                sawCuratorLine = true
                succeeded = false
                message = String(line.dropFirst("curator: rollback failed".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " —-"))
            } else if line.hasPrefix("curator: no ledger entry") {
                sawCuratorLine = true
                succeeded = false
                message = line.dropFirst("curator: ".count).description
            } else if line.hasPrefix("curator:") {
                sawCuratorLine = true
                succeeded = true
                message = String(line.dropFirst("curator:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard sawCuratorLine else { return nil }
        return CuratorEntryRollbackResult(
            entryID: entryID,
            action: action,
            skill: skill,
            actor: actor,
            whenLabel: when,
            filesTouched: files,
            succeeded: succeeded,
            message: message
        )
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
