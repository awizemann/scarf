#if canImport(SQLite3)

import Foundation
#if canImport(os)
import os
#endif

/// `HermesQueryBackend` that runs `sqlite3 -readonly -json` over an
/// SSH session per query. Replaces the old snapshot-then-open pipeline
/// (issue #74): no full-DB transfers, no local cache, every query
/// against the live remote DB.
///
/// **Why one round-trip per query is OK.** ControlMaster keeps the SSH
/// session warm — first connect spins up the master socket; subsequent
/// queries reuse it at ~5 ms overhead. sqlite3 cold-start is ~30–50 ms,
/// query execution is sub-millisecond for indexed queries, JSON
/// serialisation is small. End-to-end ~50–100 ms per query, dominated
/// by sqlite3 process spawn. Multi-query view loads (Dashboard,
/// Insights) batch via `queryBatch` — one cold-start, all statements
/// in a single sqlite3 invocation, ~80–100 ms total.
///
/// **Result format**. `sqlite3 -json` emits one JSON array per
/// statement that returns rows: `[{"col":val,...}, ...]`. Multi-statement
/// scripts emit each array on its own. We separate batched queries
/// with a `SELECT '__SCARF_RS_BEGIN__N' AS marker;` synthesised line so
/// the parser can split on the markers — sqlite3's marker rows
/// preserve order and let us pair each result-set with the originating
/// statement index.
public actor RemoteSQLiteBackend: HermesQueryBackend {

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "RemoteSQLiteBackend")
    #endif

    private let context: ServerContext
    private let transport: any ServerTransport
    private(set) public var hasV07Schema = false
    private(set) public var hasV011Schema = false
    private(set) public var hasMessagesActiveColumn = false
    private(set) public var hasCompactedColumn = false
    private(set) public var hasRewindCountColumn = false
    private(set) public var hasSessionActivityColumns = false
    private(set) public var hasSessionModelUsageTable = false
    private(set) public var lastOpenError: String?
    private var isOpen = false
    /// Captured `sqlite3 --version` line from the most recent preflight.
    /// Stashed for diagnostic logs and a future "remote sqlite3 too old"
    /// error path.
    private var sqliteVersion: String?
    /// Resolved absolute remote `$HOME`, populated on `open()` via
    /// `context.resolvedUserHome()` so that `~/` paths can be expanded
    /// in Swift up front rather than relying on shell expansion across
    /// the streamScript pipeline. The base64 + pipe path through
    /// Citadel does not reliably propagate `$HOME` into the inner
    /// `/bin/sh` on every host — keeping this client-side avoids the
    /// issue (and matches how `RemoteBackupService.expandTilde` already
    /// handles the same problem). `nil` only when the probe failed,
    /// in which case `quoteForRemoteShell` falls back to `"$HOME/..."`
    /// shell expansion.
    private var resolvedHome: String?

    /// In-flight query coalescing — keyed on the inlined SQL text,
    /// value is the Task currently fetching that exact result set.
    /// When two concurrent callers ask for the same query (common
    /// pattern: file watcher tick + chat-finalize debounce both
    /// firing `loadRecentSessions` within ~100 ms), the second
    /// caller awaits the first call's task instead of spawning a
    /// fresh SSH subprocess. Cleared on task completion. Drops
    /// duplicate `mac.loadRecentSessions` traces observed at
    /// t=960450 / t=960584 in the perf capture (two parallel 3-s
    /// loads for the same data, finishing 134 ms apart).
    ///
    /// Coalescing is *only* applied to single `query` calls, not
    /// `queryBatch` — batches are larger payloads with caller-
    /// specific timeout scaling, and concurrent callers wanting
    /// "the same batch" is rare in practice. Keep coalescing
    /// surgical so we don't accidentally serialize independent
    /// work that just happens to match.
    private var inFlightQueries: [String: Task<[Row], Error>] = [:]

    /// Per-query timeout for `query`. Healthy local queries are
    /// <100 ms; remote ones over 420 ms-RTT SSH amortize one round
    /// trip per call PLUS the wire payload time. A `fetchMessages`
    /// over a 157-message session (~50KB JSON encoded) exceeded
    /// the previous 15 s ceiling, silently returned 0 rows, and the
    /// chat appeared empty — a worse failure than the wait it was
    /// guarding against. Bumped to 30 s; the `streamScript`
    /// transport-level timeout still fires on truly wedged hosts.
    private let queryTimeout: TimeInterval = 30

    /// Preflight timeout. First SSH round-trip may include cold
    /// ControlMaster establishment (~1–3 s) plus the schema PRAGMA
    /// queries; 30 s is generous.
    private let preflightTimeout: TimeInterval = 30

    /// Marker prefix used to split `queryBatch` result sets. Picked to
    /// be very unlikely to collide with a real session_id, role string,
    /// or content fragment.
    private static let batchMarkerPrefix = "__SCARF_RS_BEGIN__"

    public init(context: ServerContext, transport: any ServerTransport) {
        self.context = context
        self.transport = transport
    }

    // MARK: - Lifecycle

    public func open() async -> Bool {
        if isOpen { return true }
        // Resolve remote $HOME once (cached process-wide via
        // ServerContext.UserHomeCache so concurrent backends share
        // the probe result). Lets us hand sqlite3 absolute paths and
        // skip the unreliable nested-shell expansion altogether. A
        // probe failure leaves `resolvedHome == nil` and falls back
        // to "$HOME/..."-quoted args; the data-service open() will
        // surface whatever sqlite3 errors out with.
        let probedHome = await context.resolvedUserHome()
        if probedHome != "~" && !probedHome.isEmpty {
            resolvedHome = probedHome
        }
        let dbPath = context.paths.stateDB
        // One SSH round-trip running:
        //   1. sqlite3 --version  (sanity + capture for diagnostics)
        //   2. PRAGMA table_info(sessions) | sessions schema
        //   3. PRAGMA table_info(messages) | messages schema
        // sqlite3 -json emits two arrays back-to-back for the two PRAGMA
        // statements; we parse them as separate result sets.
        let preflight = """
        set -e
        sqlite3 --version
        sqlite3 -readonly -json \(quoteForRemoteShell(dbPath)) "PRAGMA table_info(sessions); PRAGMA table_info(messages); SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'session_model_usage';"
        """

        do {
            let result = try await transport.streamScript(preflight, timeout: preflightTimeout)
            if result.exitCode != 0 {
                lastOpenError = errorMessage(stderr: result.stderrString, stdout: result.stdoutString, exitCode: result.exitCode)
                #if canImport(os)
                Self.logger.warning("Remote preflight failed (exit \(result.exitCode)): \(self.lastOpenError ?? "", privacy: .public)")
                #endif
                return false
            }
            try parsePreflightOutput(result.stdoutString)
            lastOpenError = nil
            isOpen = true
            #if canImport(os)
            Self.logger.info("Remote SQLite backend ready: sqlite3=\(self.sqliteVersion ?? "?", privacy: .public), v0.7=\(self.hasV07Schema), v0.11=\(self.hasV011Schema)")
            #endif
            return true
        } catch {
            lastOpenError = error.localizedDescription
            #if canImport(os)
            Self.logger.warning("Remote preflight transport error: \(error.localizedDescription, privacy: .public)")
            #endif
            return false
        }
    }

    @discardableResult
    public func refresh(forceFresh: Bool) async -> Bool {
        // Streaming queries are always fresh. The watcher tick still
        // fires `dataService.refresh()` on every observed file change
        // — locally that re-opens the SQLite handle; here it's a
        // no-op. `forceFresh: true` is the escape hatch for when the
        // user explicitly wants a re-preflight (e.g. they upgraded
        // Hermes on the remote). Drop the open state and re-run.
        if forceFresh {
            isOpen = false
            return await open()
        }
        return isOpen ? true : await open()
    }

    public func close() async {
        isOpen = false
    }

    // MARK: - Queries

    public func query(_ sql: String, params: [SQLValue]) async throws -> [Row] {
        guard isOpen else { throw BackendError.notOpen }
        let inlined = try SQLValueInliner.inline(sql, params: params)
        // In-flight coalescing — if a query with the exact same
        // inlined SQL is already pending, await its task instead
        // of spawning a new SSH subprocess. Surfaces in ScarfMon as
        // a `sqlite.query.coalesced` event so we can see how often
        // the dedup actually fires in the wild.
        if let existing = inFlightQueries[inlined] {
            ScarfMon.event(.sqlite, "query.coalesced", count: 1)
            return try await withTaskCancellationHandler(
                operation: { try await existing.value },
                onCancel: { existing.cancel() }
            )
        }
        let task = Task<[Row], Error> { [self] in
            try await ScarfMon.measureAsync(.sqlite, "query") {
                let dbPath = context.paths.stateDB
                let script = """
                sqlite3 -readonly -json \(quoteForRemoteShell(dbPath)) <<'__SCARF_SQL__'
                \(inlined)
                __SCARF_SQL__
                """
                let result: ProcessResult
                do {
                    result = try await transport.streamScript(script, timeout: queryTimeout)
                } catch {
                    throw BackendError.transport(error.localizedDescription)
                }
                if result.exitCode != 0 {
                    throw BackendError.sqlite(exitCode: result.exitCode, stderr: result.stderrString)
                }
                let rows = try parseSingleResultSet(result.stdoutString)
                ScarfMon.event(.sqlite, "query.rows", count: rows.count, bytes: result.stdout.count)
                return rows
            }
        }
        inFlightQueries[inlined] = task
        defer { inFlightQueries[inlined] = nil }
        // v2.8 — propagate parent task cancellation INTO the
        // unstructured `task`. `Task<...>{ ... }` doesn't inherit
        // cancellation from the awaiting context, so without this a
        // cancelled chat-hydration / dashboard-refresh would keep
        // the ssh subprocess alive for the full 30s queryTimeout
        // — pinning a remote sqlite query and a ControlMaster
        // session slot. With the bridge, the inner task's awaits
        // see a cancelled parent and `SSHScriptRunner.run`'s own
        // cancellation handler (v2.8) kills the ssh process inside
        // the next 100ms poll.
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    public func queryBatch(_ statements: [(sql: String, params: [SQLValue])]) async throws -> [[Row]] {
        try await ScarfMon.measureAsync(.sqlite, "queryBatch") {
            try await _queryBatchImpl(statements)
        }
    }

    private func _queryBatchImpl(_ statements: [(sql: String, params: [SQLValue])]) async throws -> [[Row]] {
        guard isOpen else { throw BackendError.notOpen }
        if statements.isEmpty { return [] }
        // Build one sqlite3 invocation with marker SELECTs separating
        // each statement's result set. `SELECT '__SCARF_RS_BEGIN__N'`
        // emits a one-row JSON array we use as a sentinel.
        var sqlBlocks: [String] = []
        for (i, stmt) in statements.enumerated() {
            let inlined = try SQLValueInliner.inline(stmt.sql, params: stmt.params)
            // Marker first (so we know which result-set follows even
            // if a query returns zero rows — sqlite3 -json prints
            // nothing for empty result sets, which would otherwise
            // make the parser drift).
            sqlBlocks.append("SELECT '\(Self.batchMarkerPrefix)\(i)' AS marker;")
            sqlBlocks.append(ensureTrailingSemicolon(inlined))
        }
        let combined = sqlBlocks.joined(separator: "\n")
        let dbPath = context.paths.stateDB
        let script = """
        sqlite3 -readonly -json \(quoteForRemoteShell(dbPath)) <<'__SCARF_SQL__'
        \(combined)
        __SCARF_SQL__
        """
        let result: ProcessResult
        do {
            // Batched timeout: scale with statement count, capped at
            // a comfortable 30 s. Most batches are 4–5 statements.
            let timeout = min(30, queryTimeout + Double(statements.count) * 2)
            result = try await transport.streamScript(script, timeout: timeout)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
        if result.exitCode != 0 {
            throw BackendError.sqlite(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return try parseBatchResultSets(result.stdoutString, expectedCount: statements.count)
    }

    // MARK: - Preflight parsing

    private func parsePreflightOutput(_ stdout: String) throws {
        // Expected output:
        //   <sqlite3 version line>
        //   [<sessions PRAGMA result>]
        //   [<messages PRAGMA result>]
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            throw BackendError.parseFailure(stdoutHead: String(stdout.prefix(200)))
        }
        sqliteVersion = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)

        // The remaining lines should contain two JSON arrays. sqlite3
        // -json emits each on its own — though it can wrap long arrays
        // across multiple lines. We split on `][` boundaries to be
        // robust. Walk the stream looking for two top-level arrays.
        let rest = lines.dropFirst().joined(separator: "\n")
        let arrays = splitTopLevelJSONArrays(rest)
        guard arrays.count >= 2 else {
            throw BackendError.parseFailure(stdoutHead: String(stdout.prefix(200)))
        }
        let sessionsTable = try parseTableInfo(arrays[0])
        let messagesTable = try parseTableInfo(arrays[1])

        // v0.7: sessions has `reasoning_tokens`.
        hasV07Schema = sessionsTable.contains("reasoning_tokens")
        // v0.11: BOTH sessions has `api_call_count` AND messages has
        // `reasoning_content`. Belt-and-braces against partial migrations.
        let sessionsHasV011 = sessionsTable.contains("api_call_count")
        let messagesHasV011 = messagesTable.contains("reasoning_content")
        hasV011Schema = sessionsHasV011 && messagesHasV011
        // v0.16: messages has `active` column for soft-delete support.
        hasMessagesActiveColumn = messagesTable.contains("active")
        // v0.18: messages has `compacted` column (in-place compaction
        // soft-archive marker; search must include compacted=1 rows).
        hasCompactedColumn = messagesTable.contains("compacted")
        // v0.16: sessions has `rewind_count` column.
        hasRewindCountColumn = sessionsTable.contains("rewind_count")
        // v0.20: session-activity columns — ALL three must be present
        // (belt-and-braces against a partially-migrated DB).
        hasSessionActivityColumns = sessionsTable.contains("pinned")
            && sessionsTable.contains("last_activity_at")
            && sessionsTable.contains("last_activity_description")
        // v0.20: `session_model_usage` table. The preflight's third
        // statement is a COUNT(*) over sqlite_master, so it always
        // emits exactly one array — arrays[2] when present. Older
        // preflight output shapes (tests / cached transports) may only
        // carry two arrays; default to false in that case.
        if arrays.count >= 3,
           let data = arrays[2].data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let n = arr.first?["n"] as? Int {
            hasSessionModelUsageTable = n > 0
        } else {
            hasSessionModelUsageTable = false
        }
    }

    /// Extract column names from a `PRAGMA table_info(...)` result set.
    private func parseTableInfo(_ json: String) throws -> Set<String> {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BackendError.parseFailure(stdoutHead: String(json.prefix(200)))
        }
        var names: Set<String> = []
        for row in arr {
            if let name = row["name"] as? String {
                names.insert(name)
            }
        }
        return names
    }

    // MARK: - Result-set parsing

    private func parseSingleResultSet(_ stdout: String) throws -> [Row] {
        // sqlite3 -json prints nothing for empty result sets, so an
        // empty stdout is valid and means "0 rows".
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return try rowsFromJSONArray(trimmed)
    }

    private func parseBatchResultSets(_ stdout: String, expectedCount: Int) throws -> [[Row]] {
        // Scan the output as a sequence of JSON arrays. Each marker
        // SELECT emits a one-row array `[{"marker":"__SCARF_RS_BEGIN__N"}]`;
        // the following array (if present) is statement N's result set.
        let arrays = splitTopLevelJSONArrays(stdout)
        var result: [[Row]] = Array(repeating: [], count: expectedCount)
        var i = 0
        while i < arrays.count {
            let chunk = arrays[i]
            // Try to read this chunk as a marker. A marker row is one
            // object with exactly the `marker` field. Anything else
            // is a real result set (which we attribute to the most
            // recent marker we saw).
            if let idx = markerIndex(in: chunk) {
                // The marker index comes from remote stdout — a hostile
                // or corrupted host could emit an out-of-range index.
                guard idx >= 0, idx < expectedCount else {
                    throw BackendError.parseFailure(stdoutHead: String(chunk.prefix(200)))
                }
                // Next array (if any) is this statement's result set.
                // If the next array is ALSO a marker, the current
                // statement returned zero rows.
                let next = i + 1
                if next < arrays.count, markerIndex(in: arrays[next]) == nil {
                    result[idx] = try rowsFromJSONArray(arrays[next])
                    i = next + 1
                } else {
                    // Empty result set for this statement.
                    i = next
                }
            } else {
                // Stray array (no preceding marker). Skip — shouldn't
                // happen in practice given how we build the script.
                i += 1
            }
        }
        return result
    }

    /// If the array's single row is a marker `{"marker":"__SCARF_RS_BEGIN__N"}`,
    /// return N. Otherwise nil.
    private func markerIndex(in json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              arr.count == 1,
              let marker = arr[0]["marker"] as? String,
              marker.hasPrefix(Self.batchMarkerPrefix) else { return nil }
        let suffix = marker.dropFirst(Self.batchMarkerPrefix.count)
        return Int(suffix)
    }

    private func rowsFromJSONArray(_ json: String) throws -> [Row] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BackendError.parseFailure(stdoutHead: String(json.prefix(200)))
        }
        if arr.isEmpty { return [] }
        // `[String: Any]` does NOT preserve insertion order on macOS
        // (NSDictionary backing). To keep the SELECT column order
        // intact — which the data-service row parsers depend on
        // (`row.string(at: 0)` for `id`, etc.) — we extract the key
        // order from the FIRST object's raw JSON bytes. Subsequent
        // rows reuse that key list to look up values by name from
        // their parsed dictionaries.
        let orderedKeys = extractFirstObjectKeys(from: json) ?? Array(arr[0].keys)
        var columnIndex: [String: Int] = [:]
        columnIndex.reserveCapacity(orderedKeys.count)
        for (i, k) in orderedKeys.enumerated() { columnIndex[k] = i }

        var rows: [Row] = []
        rows.reserveCapacity(arr.count)
        for obj in arr {
            var values: [SQLValue] = []
            values.reserveCapacity(orderedKeys.count)
            for key in orderedKeys {
                values.append(decode(obj[key]))
            }
            rows.append(Row(values: values, columnIndex: columnIndex))
        }
        return rows
    }

    /// Walk the raw JSON bytes of the FIRST top-level object in a
    /// `sqlite3 -json` result array and return its keys in literal
    /// order. Single pass over the UTF-8 bytes — avoids the two-pass
    /// String-index scan (issue #135): extracting the first object
    /// substring and then re-scanning it for keys cost two full
    /// traversals plus a substring copy per result set, which showed
    /// up as parse latency on large `fetchMessages` result sets
    /// (~50KB of JSON). Byte-scanning keeps the same semantics:
    /// keys are collected at object depth 1 (the first object's own
    /// level), nested objects/arrays are skipped via depth tracking,
    /// and string/escape states are honoured so a `{`/`,`/`:` inside
    /// a value can't corrupt the key list.
    private func extractFirstObjectKeys(from json: String) -> [String]? {
        let bytes = Array(json.utf8)
        // Find the first '{' — the start of the first object.
        guard let openIdx = bytes.firstIndex(of: 0x7B /* { */) else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var expectingKey = true
        var keyStart: Int?
        var keys: [String] = []
        var i = openIdx
        while i < bytes.count {
            let c = bytes[i]
            if inString {
                if escape {
                    escape = false
                } else if c == 0x5C /* \ */ {
                    escape = true
                } else if c == 0x22 /* " */ {
                    inString = false
                    if expectingKey && depth == 1, let start = keyStart {
                        if let s = String(bytes: bytes[start..<i], encoding: .utf8) {
                            keys.append(s)
                        }
                        expectingKey = false
                        keyStart = nil
                    }
                }
                i += 1
                continue
            }
            switch c {
            case 0x22 /* " */:
                inString = true
                if expectingKey && depth == 1 {
                    keyStart = i + 1
                }
            case 0x7B /* { */:
                depth += 1
            case 0x7D /* } */:
                depth -= 1
                if depth == 0 {
                    // Closed the outer object — we have every key.
                    return keys
                }
            case 0x5B /* [ */:
                depth += 1
            case 0x5D /* ] */:
                depth -= 1
            case 0x2C /* , */:
                if depth == 1 { expectingKey = true }
            case 0x3A /* : */:
                if depth == 1 { expectingKey = false }
            default:
                break
            }
            i += 1
        }
        return keys
    }

    private func decode(_ v: Any?) -> SQLValue {
        guard let v else { return .null }
        if v is NSNull { return .null }
        if let n = v as? NSNumber {
            // NSJSONSerialization decodes both ints and doubles into
            // NSNumber. Distinguish: if it round-trips through Int64
            // unchanged, treat as integer; else real.
            // A leading-zero-after-dot Double like 1.0 still has
            // .doubleValue == 1.0 and Int64(1.0) == 1, so the round-
            // trip check correctly bins integral doubles as integer
            // (which sqlite3 -json does too — `1` in JSON, not `1.0`).
            let asInt64 = n.int64Value
            if Double(asInt64) == n.doubleValue {
                return .integer(asInt64)
            }
            return .real(n.doubleValue)
        }
        if let s = v as? String {
            return .text(s)
        }
        // Fall-through: stringify whatever it is so we don't lose data
        // silently. SQLite -json doesn't emit booleans or nested
        // objects from PRAGMA / SELECT outputs in our usage.
        return .text(String(describing: v))
    }

    // MARK: - JSON helpers

    /// Walk a string of one or more concatenated JSON arrays at the top
    /// level (sqlite3 -json's batched output) and return each array as
    /// a separate substring. Tolerates whitespace/newlines between
    /// arrays.
    private func splitTopLevelJSONArrays(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var inString = false
        var escape = false
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape {
                    escape = false
                } else if c == "\\" {
                    escape = true
                } else if c == "\"" {
                    inString = false
                }
                i = s.index(after: i)
                continue
            }
            switch c {
            case "\"":
                inString = true
            case "[":
                if depth == 0 { start = i }
                depth += 1
            case "]":
                depth -= 1
                if depth == 0, let begin = start {
                    let end = s.index(after: i)
                    out.append(String(s[begin..<end]))
                    start = nil
                }
            default:
                break
            }
            i = s.index(after: i)
        }
        return out
    }

    private func ensureTrailingSemicolon(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") { return trimmed }
        return trimmed + ";"
    }

    // MARK: - Quoting + error mapping

    /// Build the shell argument that the remote `sh -c` will see for
    /// the SQLite path. Three cases, in priority order:
    ///
    /// 1. **`~`-prefixed AND we have a `resolvedHome`** — the common
    ///    case. Pre-expand to an absolute path in Swift, then single-
    ///    quote. Sqlite3 receives a literal absolute path; no shell
    ///    expansion needed.
    /// 2. **`~`-prefixed AND no `resolvedHome`** (probe failed) —
    ///    fall back to `"$HOME/..."` and hope the remote shell expands
    ///    it. Works on Mac SSHTransport (login shell with $HOME set);
    ///    less reliable through Citadel's exec-channel + base64 +
    ///    inner-`/bin/sh` pipeline on iOS, which is precisely why
    ///    we prefer the resolved-home path above.
    /// 3. **Absolute** (`/home/agent/.hermes/state.db`) — single-quote
    ///    with the standard sh escape for any embedded single-quote.
    ///
    /// sqlite3 doesn't expand `~` itself (that's a shell affordance),
    /// so a default-config remote with `paths.stateDB ==
    /// "~/.hermes/state.db"` would produce `unable to open database
    /// "~/.hermes/state.db"` without one of these rewrites — issue
    /// reported on iOS Citadel against `127.0.0.1`.
    private func quoteForRemoteShell(_ path: String) -> String {
        if let home = resolvedHome {
            let expanded: String
            if path == "~" {
                expanded = home
            } else if path.hasPrefix("~/") {
                expanded = home + "/" + String(path.dropFirst(2))
            } else {
                expanded = path
            }
            return "'" + expanded.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // Probe-failed fallback: rely on remote-shell `$HOME` expansion.
        if path == "~" {
            return "\"$HOME\""
        }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            let escaped = rest
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
            return "\"$HOME/\(escaped)\""
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Translate a non-zero sqlite3 exit into a user-presentable
    /// message. Mirrors substrings that `HermesDataService.humanize`
    /// keys off so the existing dashboard banner renders correctly.
    private func errorMessage(stderr: String, stdout: String, exitCode: Int32) -> String {
        let combined = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.isEmpty {
            return "sqlite3 exited \(exitCode) with no output"
        }
        return combined
    }
}

#endif // canImport(SQLite3)
