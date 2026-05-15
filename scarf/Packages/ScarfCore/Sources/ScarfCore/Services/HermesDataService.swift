// MARK: - Platform gate
//
// This file's row-parsing helpers used to lean on libsqlite3 directly
// (`sqlite3_column_*`); after the v2.7 backend split they go through
// the typed `Row` API and don't actually need the SQLite3 module.
// The gate stays for symmetry with the backend files (LocalSQLiteBackend
// imports SQLite3) and to keep ScarfCore's compile target narrow.
#if canImport(SQLite3)

import Foundation
#if canImport(os)
import os
#endif

/// Read-only data service over Hermes's `state.db`. Routes every query
/// through a `HermesQueryBackend`:
///
/// * `LocalSQLiteBackend` for `ServerContext.local` — opens the live
///   `~/.hermes/state.db` via libsqlite3. Microseconds per query.
/// * `RemoteSQLiteBackend` for `.ssh` contexts — runs `sqlite3 -json`
///   over an SSH session per query (ControlMaster keeps the channel
///   warm). 50–100 ms per query, but no full-DB transfers and always-
///   fresh data, even for multi-GB DBs (issue #74).
///
/// The split happened in v2.7 to fix the "5 GB state.db means 7-minute
/// snapshots every refresh" issue. Local performance is unchanged;
/// remote bandwidth scales with query result size, not DB size.
public actor HermesDataService {
    private static let logger = Logger(subsystem: "com.scarf", category: "HermesDataService")

    private let backend: any HermesQueryBackend
    public let context: ServerContext
    private let transport: any ServerTransport

    /// Cached schema fingerprint, populated on `open()`. Keeps the
    /// SELECT-shape builders (`sessionColumns`, `messageColumns`)
    /// synchronous — without this they'd `await backend.hasV07Schema`
    /// on every call.
    private var hasV07Schema = false
    private var hasV011Schema = false

    /// Last error from `open()` / `refresh()`, user-presentable. `nil`
    /// means the last attempt succeeded. Views surface this when their
    /// own load path fails, so the user sees "Permission denied
    /// reading state.db" instead of an empty Dashboard with no
    /// explanation.
    public private(set) var lastOpenError: String?

    public init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
        if context.isRemote {
            self.backend = RemoteSQLiteBackend(context: context, transport: self.transport)
        } else {
            self.backend = LocalSQLiteBackend(context: context)
        }
    }

    /// Test seam — inject any `HermesQueryBackend`. Production code
    /// should use the `init(context:)` overload.
    internal init(context: ServerContext, backend: any HermesQueryBackend) {
        self.context = context
        self.transport = context.makeTransport()
        self.backend = backend
    }

    // MARK: - Lifecycle

    public func open() async -> Bool {
        let ok = await backend.open()
        // Cache schema flags — sessionColumns / messageColumns are
        // hot paths (called on every fetch* method) and going async
        // for them would force every fetch into a multi-await pattern.
        hasV07Schema = await backend.hasV07Schema
        hasV011Schema = await backend.hasV011Schema
        lastOpenError = await backend.lastOpenError
        return ok
    }

    @discardableResult
    public func refresh(forceFresh: Bool = false) async -> Bool {
        let ok = await backend.refresh(forceFresh: forceFresh)
        hasV07Schema = await backend.hasV07Schema
        hasV011Schema = await backend.hasV011Schema
        lastOpenError = await backend.lastOpenError
        return ok
    }

    public func close() async {
        await backend.close()
    }

    /// Turn a transport / backend error into the one-line string Dashboard
    /// shows. Adds hints for the common "sqlite3 not installed" and
    /// "permission denied" cases so users know what to do. Mirrors the
    /// pre-v2.7 humanise behaviour exactly so existing UI banners
    /// continue to render with the same copy.
    private nonisolated func humanize(_ error: Error) -> String {
        let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = desc.lowercased()
        if lower.contains("sqlite3: command not found") || lower.contains("sqlite3: not found") {
            return "sqlite3 is not installed on \(context.displayName). Install it with `apt install sqlite3` (Ubuntu/Debian) or `yum install sqlite` (RHEL/Fedora)."
        }
        if lower.contains("permission denied") {
            return "Permission denied reading Hermes state on \(context.displayName). The SSH user may not have read access to ~/.hermes/state.db — try Run Diagnostics."
        }
        if lower.contains("no such file") || lower.contains("unable to open database file") {
            return "Hermes state not found at ~/.hermes on \(context.displayName). If Hermes is installed elsewhere, set its data directory in Manage Servers."
        }
        return desc
    }

    // MARK: - Column shapes

    private var sessionColumns: String {
        var cols = """
            id, source, user_id, model, title, parent_session_id,
            started_at, ended_at, end_reason, message_count, tool_call_count,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
            estimated_cost_usd
            """
        if hasV07Schema {
            cols += ", reasoning_tokens, actual_cost_usd, cost_status, billing_provider"
        }
        if hasV011Schema {
            cols += ", api_call_count"
        }
        cols += ", \(sessionLastActivityExpression) AS last_activity_at"
        return cols
    }

    private var messageColumns: String {
        var cols = """
            id, session_id, role, content, tool_call_id, tool_calls,
            tool_name, timestamp, token_count, finish_reason
            """
        if hasV07Schema {
            cols += ", reasoning"
        }
        if hasV011Schema {
            cols += ", reasoning_content"
        }
        return cols
    }

    /// Same as `messageColumns` but with the `reasoning_content`
    /// column omitted. v0.11+ Hermes thinking-model output stores
    /// the full chain-of-thought transcript in `reasoning_content`,
    /// which on a single message can be 20+ KB of JSON. For a
    /// 160-message session that's >1 MB of wire payload — enough
    /// to time out a 30s SSH `sqlite3 -json` fetch on a 420ms-RTT
    /// remote (perf capture confirmed). The bubble's main body
    /// doesn't render reasoning_content directly; the inspector
    /// pane does, and the user opens that on demand. So initial
    /// fetch can skip it and a follow-up `fetchReasoningContent`
    /// can pull it lazily when the inspector opens.
    private var messageColumnsLight: String {
        var cols = """
            id, session_id, role, content, tool_call_id, tool_calls,
            tool_name, timestamp, token_count, finish_reason
            """
        if hasV07Schema {
            cols += ", reasoning"
        }
        // v0.11+ `reasoning_content` is intentionally excluded.
        // `messageFromRow` defaults it to nil; callers that need it
        // call `fetchReasoningContent(for:)` to lazy-load.
        return cols
    }

    /// Skeleton column set for the v2.8 two-phase chat loader. Returns
    /// EVERYTHING needed to render a user-or-assistant bubble — id,
    /// role, content, timestamp, token_count, finish_reason — but
    /// hard-NULLs the heavy content-bearing columns (`tool_calls`,
    /// `reasoning`, `reasoning_content`) at the SQL level so the wire
    /// payload is bounded by the conversational text alone. A
    /// 30-message session with multi-page tool result blobs that
    /// previously timed out the 30s SSH budget reduces here to a few
    /// KB. The chat appears in seconds; tool details fill in via
    /// `hydrateAssistantToolCalls(...)` and `hydrateToolResults(...)`
    /// in the background.
    ///
    /// The schema-shape match against `messageFromRow` is exact —
    /// same column ordering as `messageColumnsLight`. The literal
    /// NULLs let messageFromRow's defaulting paths fill empty
    /// arrays / nils without any callee changes.
    private var messageColumnsSkeleton: String {
        var cols = """
            id, session_id, role, content, tool_call_id, NULL AS tool_calls,
            tool_name, timestamp, token_count, finish_reason
            """
        if hasV07Schema {
            cols += ", NULL AS reasoning"
        }
        return cols
    }

    /// Sort top-level chat/session lists by the latest observable activity,
    /// not by the session creation time. Older sessions that receive new
    /// messages should bubble back to the top of Scarf's chat lists.
    private var sessionLastActivityExpression: String {
        """
        MAX(
            COALESCE((SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = sessions.id), 0),
            COALESCE(ended_at, 0),
            COALESCE(started_at, 0)
        )
        """
    }

    private var sessionLastActivityOrder: String {
        "\(sessionLastActivityExpression) DESC, started_at DESC"
    }

    // MARK: - Session Queries

    public func fetchSessions(limit: Int = QueryDefaults.sessionLimit) async -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL ORDER BY \(sessionLastActivityOrder) LIMIT ?"
        do {
            let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
            return rows.map { sessionFromRow($0) }
        } catch {
            Self.logger.warning("fetchSessions failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func fetchSessionsInPeriod(since: Date) async -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL AND \(sessionLastActivityExpression) >= ? ORDER BY \(sessionLastActivityOrder)"
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            return rows.map { sessionFromRow($0) }
        } catch {
            return []
        }
    }

    public func fetchSubagentSessions(parentId: String) async -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id = ? ORDER BY started_at ASC"
        do {
            let rows = try await backend.query(sql, params: [.text(parentId)])
            return rows.map { sessionFromRow($0) }
        } catch {
            return []
        }
    }

    // MARK: - Message Queries

    /// Bounded message fetch keyed by message id (monotonic per row,
    /// safer than timestamp-based pagination because streaming chunk
    /// timestamps can collide). Returns the most recent `limit`
    /// messages older than `before` (when supplied) in chronological
    /// (ASC) order ready to display. Pass `before: nil` for the
    /// initial load — the DB returns the newest `limit` rows.
    public func fetchMessages(
        sessionId: String,
        limit: Int,
        before: Int? = nil
    ) async -> [HermesMessage] {
        await fetchMessagesOutcome(sessionId: sessionId, limit: limit, before: before).messages
    }

    /// Outcome-returning variant of `fetchMessages`. Distinguishes a
    /// successful empty result (genuinely zero rows) from a transport
    /// failure (SSH timeout, ControlMaster drop) so callers can decide
    /// whether to silently render the rows or surface a "couldn't load
    /// full history" banner. The plain `fetchMessages` shape stays so
    /// background paths (reconcile, polling, sessions detail) keep
    /// their silent-best-effort behavior — only the chat-resume path
    /// asks for the outcome.
    public func fetchMessagesOutcome(
        sessionId: String,
        limit: Int,
        before: Int? = nil
    ) async -> MessageFetchOutcome {
        await ScarfMon.measureAsync(.sessionLoad, "mac.fetchMessages") {
            // Use the lite column set — excludes reasoning_content which
            // can be 20+ KB per message on thinking-model sessions and
            // was the cause of repeated 30s SSH timeouts on 100+-message
            // sessions over 420ms-RTT remote links. The inspector pane
            // calls `fetchReasoningContent(for:)` to lazy-load when the
            // user opens a message's disclosure.
            let sql: String
            let params: [SQLValue]
            if let before {
                sql = "SELECT \(messageColumnsLight) FROM messages WHERE session_id = ? AND id < ? ORDER BY id DESC LIMIT ?"
                params = [.text(sessionId), .integer(Int64(before)), .integer(Int64(limit))]
            } else {
                sql = "SELECT \(messageColumnsLight) FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT ?"
                params = [.text(sessionId), .integer(Int64(limit))]
            }
            do {
                let rows = try await backend.query(sql, params: params)
                // Caller wants chronological (oldest-first) order; the SELECT
                // is DESC for the LIMIT to bite the newest rows, so reverse.
                let messages = rows.map { messageFromRow($0) }.reversed() as [HermesMessage]
                ScarfMon.event(.sessionLoad, "mac.fetchMessages.rows", count: messages.count)
                return MessageFetchOutcome(messages: messages, transportError: nil)
            } catch let BackendError.transport(reason) {
                // SSH timeout / ControlMaster drop / connection blip. The
                // chat resume path renders the partial-result banner so
                // the user sees "couldn't load full history" instead of
                // an empty transcript. v2.8.
                ScarfMon.event(.sessionLoad, "mac.fetchMessages.transportError", count: 1)
                return MessageFetchOutcome(messages: [], transportError: reason)
            } catch {
                return MessageFetchOutcome(messages: [], transportError: nil)
            }
        }
    }

    /// Phase 1 of the v2.8 two-phase chat loader. Fetches user +
    /// assistant rows ONLY (skips `role='tool'` entirely) with
    /// `tool_calls`, `reasoning`, and `reasoning_content` hard-NULLed
    /// at the SQL level. The wire payload is bounded by the
    /// conversational text alone — a 30-message session whose tool
    /// results blob ran 100KB+ per row drops from a 30s timeout to a
    /// few hundred ms. The chat is rendered immediately; tool details
    /// fill in via `hydrateAssistantToolCalls` and `hydrateToolResults`
    /// in background tasks.
    ///
    /// Returns the same `MessageFetchOutcome` shape as the full
    /// `fetchMessagesOutcome` so the caller can distinguish a
    /// transport failure (banner-worthy) from a genuinely empty
    /// session.
    public func fetchSkeletonMessages(
        sessionId: String,
        limit: Int,
        before: Int? = nil
    ) async -> MessageFetchOutcome {
        await ScarfMon.measureAsync(.sessionLoad, "mac.fetchSkeletonMessages") {
            let sql: String
            let params: [SQLValue]
            if let before {
                sql = "SELECT \(messageColumnsSkeleton) FROM messages WHERE session_id = ? AND role IN ('user','assistant') AND id < ? ORDER BY id DESC LIMIT ?"
                params = [.text(sessionId), .integer(Int64(before)), .integer(Int64(limit))]
            } else {
                sql = "SELECT \(messageColumnsSkeleton) FROM messages WHERE session_id = ? AND role IN ('user','assistant') ORDER BY id DESC LIMIT ?"
                params = [.text(sessionId), .integer(Int64(limit))]
            }
            do {
                let rows = try await backend.query(sql, params: params)
                let messages = rows.map { messageFromRow($0) }.reversed() as [HermesMessage]
                ScarfMon.event(.sessionLoad, "mac.fetchSkeletonMessages.rows", count: messages.count)
                return MessageFetchOutcome(messages: messages, transportError: nil)
            } catch let BackendError.transport(reason) {
                ScarfMon.event(.sessionLoad, "mac.fetchSkeletonMessages.transportError", count: 1)
                return MessageFetchOutcome(messages: [], transportError: reason)
            } catch {
                return MessageFetchOutcome(messages: [], transportError: nil)
            }
        }
    }

    /// Phase 2a of the two-phase loader. Hydrate `tool_calls` for
    /// assistant rows in `messageIds`. Returns parsed `[HermesToolCall]`
    /// keyed by message id — caller splices into the existing
    /// `HermesMessage` values to bring the tool cards online without
    /// a full re-fetch. Empty / missing `tool_calls` rows are omitted
    /// from the result.
    ///
    /// **Paged into 5-id batches.** A single 25-id IN-clause query
    /// returning 10 large `tool_calls` JSON blobs (a long Edit's args
    /// can be 100KB+ on its own) tripped the 30s SSH timeout in
    /// 2026-05-05 dogfooding. Pages run sequentially so the worst
    /// case is one slow batch instead of one slow whole-fetch — and
    /// the user sees tool cards trickle in newest-first as each page
    /// completes, since the caller drives the splice + UI rebuild.
    public func hydrateAssistantToolCalls(
        messageIds: [Int]
    ) async -> [Int: [HermesToolCall]] {
        guard !messageIds.isEmpty else { return [:] }
        return await ScarfMon.measureAsync(.sessionLoad, "mac.hydrateToolCalls") {
            // Page newest-first: callers pass ids in chronological
            // order from the skeleton fetch; the tail of that array is
            // the most-recent assistant turn, which is the one the
            // user is most likely looking at.
            let pageSize = 5
            let pages = stride(from: 0, to: messageIds.count, by: pageSize).map {
                Array(messageIds[$0..<min($0 + pageSize, messageIds.count)])
            }.reversed()
            var out: [Int: [HermesToolCall]] = [:]
            for page in pages {
                // Bail immediately if the parent task got cancelled
                // (chat switch, view dismiss). v2.8 — without this
                // explicit check the catch-all below would swallow
                // `CancellationError` and keep firing batches against
                // the abandoned session, defeating the whole point of
                // the cancellation propagation chain we wired through
                // SSHScriptRunner + RemoteSQLiteBackend.
                if Task.isCancelled {
                    ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.cancelled", count: 1)
                    return out
                }
                let placeholders = Array(repeating: "?", count: page.count).joined(separator: ",")
                let sql = "SELECT id, tool_calls FROM messages WHERE id IN (\(placeholders)) AND tool_calls IS NOT NULL AND tool_calls != '' AND tool_calls != '[]'"
                let params: [SQLValue] = page.map { .integer(Int64($0)) }
                do {
                    let rows = try await backend.query(sql, params: params)
                    for row in rows {
                        let id = row.int(at: 0)
                        let json = row.optionalString(at: 1)
                        let parsed = parseToolCalls(json)
                        if !parsed.isEmpty {
                            out[id] = parsed
                        }
                    }
                } catch is CancellationError {
                    // Parent cancelled mid-page — return what we have
                    // and stop. Distinct from the transport-timeout
                    // path below, which is a per-page failure.
                    ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.cancelled", count: 1)
                    return out
                } catch let BackendError.transport(reason) {
                    // One page tripped the 30s timeout — at least one
                    // id in this batch carries an oversized tool_calls
                    // blob (multi-hundred-KB Edit args, big diffs).
                    // L1 (v2.8) — fall back to single-id queries to
                    // isolate the whale. The non-whale ids in the same
                    // batch hydrate normally; only the actual offender
                    // stays bare. Adds at most `page.count` extra
                    // round-trips on a timeout, but each is bounded by
                    // its own queryTimeout so we won't compound the
                    // wait beyond ~30s per id.
                    ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.pageTimeout", count: 1)
                    Self.logger.warning("hydrateToolCalls page timed out (\(page.count) ids), falling back to single-id retry: \(reason, privacy: .public)")
                    for id in page {
                        if Task.isCancelled { return out }
                        do {
                            let singleSQL = "SELECT id, tool_calls FROM messages WHERE id = ? AND tool_calls IS NOT NULL AND tool_calls != '' AND tool_calls != '[]'"
                            let rows = try await backend.query(singleSQL, params: [.integer(Int64(id))])
                            for row in rows {
                                let rid = row.int(at: 0)
                                let json = row.optionalString(at: 1)
                                let parsed = parseToolCalls(json)
                                if !parsed.isEmpty {
                                    out[rid] = parsed
                                }
                            }
                        } catch is CancellationError {
                            return out
                        } catch let BackendError.transport(singleReason) {
                            // This is the whale. Skip it — the user
                            // can still expand the assistant message;
                            // only the per-call cards on this row
                            // stay bare. Recorded so future captures
                            // show how often we hit a single-id
                            // timeout vs. a batch timeout.
                            ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.singleTimeout", count: 1)
                            Self.logger.warning("hydrateToolCalls single-id retry timed out (id=\(id)): \(singleReason, privacy: .public)")
                            continue
                        } catch {
                            Self.logger.warning("hydrateToolCalls single-id retry failed (id=\(id)): \(error.localizedDescription, privacy: .public)")
                            continue
                        }
                    }
                    continue
                } catch {
                    Self.logger.warning("hydrateAssistantToolCalls page failed: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.rows", count: out.count)
            return out
        }
    }

    /// Phase 2b of the two-phase loader. Fetch `role='tool'` rows in
    /// `[minId, maxId]` for `sessionId`. These are the heavy ones —
    /// a single tool result can carry a multi-page text blob. The
    /// caller pages through the id range in chunks (newest-first) so
    /// each round-trip is bounded.
    ///
    /// Returns `[HermesMessage]` in DESC order (newest first) the
    /// caller can splice into the live `messages` array. Transport
    /// failures fall through to an empty result with a warning logged
    /// — the chat is already usable without tool results, so this is
    /// best-effort rather than banner-worthy.
    public func fetchToolResultsInRange(
        sessionId: String,
        minId: Int,
        maxId: Int,
        limit: Int = 50
    ) async -> [HermesMessage] {
        await ScarfMon.measureAsync(.sessionLoad, "mac.hydrateToolResults") {
            let sql = "SELECT \(messageColumnsLight) FROM messages WHERE session_id = ? AND role = 'tool' AND id >= ? AND id <= ? ORDER BY id DESC LIMIT ?"
            let params: [SQLValue] = [
                .text(sessionId),
                .integer(Int64(minId)),
                .integer(Int64(maxId)),
                .integer(Int64(limit))
            ]
            do {
                let rows = try await backend.query(sql, params: params)
                let messages = rows.map { messageFromRow($0) }
                ScarfMon.event(.sessionLoad, "mac.hydrateToolResults.rows", count: messages.count)
                return messages
            } catch {
                Self.logger.warning("fetchToolResultsInRange failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
    }

    /// Lazy-load the `reasoning_content` for a single message. Called
    /// when the user expands the inspector disclosure on a thinking-model
    /// reply that has reasoning available (i.e. the message has v0.11
    /// schema). Cheap on a single message — avoids the bulk-fetch
    /// payload-size problem that motivated `messageColumnsLight`.
    public func fetchReasoningContent(for messageId: Int) async -> String? {
        guard hasV011Schema else { return nil }
        let sql = "SELECT reasoning_content FROM messages WHERE id = ?"
        do {
            let rows = try await backend.query(sql, params: [.integer(Int64(messageId))])
            return rows.first?.optionalString(at: 0)
        } catch {
            Self.logger.warning("fetchReasoningContent failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Legacy unbounded fetch retained for one release cycle so any
    /// out-of-tree consumers don't break. New code should use the
    /// bounded `fetchMessages(sessionId:limit:before:)` variant —
    /// loads on 1000+-message sessions stall the UI when they
    /// materialise the whole history at once.
    @available(*, deprecated, message: "Use fetchMessages(sessionId:limit:before:) instead.")
    public func fetchMessages(sessionId: String) async -> [HermesMessage] {
        let sql = "SELECT \(messageColumns) FROM messages WHERE session_id = ? ORDER BY timestamp ASC"
        do {
            let rows = try await backend.query(sql, params: [.text(sessionId)])
            return rows.map { messageFromRow($0) }
        } catch {
            return []
        }
    }

    public func searchMessages(query: String, limit: Int = QueryDefaults.messageSearchLimit) async -> [HermesMessage] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        var msgCols = "m.id, m.session_id, m.role, m.content, m.tool_call_id, m.tool_calls, m.tool_name, m.timestamp, m.token_count, m.finish_reason"
        if hasV07Schema { msgCols += ", m.reasoning" }
        if hasV011Schema { msgCols += ", m.reasoning_content" }
        let sql = """
            SELECT \(msgCols)
            FROM messages_fts fts
            JOIN messages m ON m.id = fts.rowid
            WHERE messages_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        do {
            let rows = try await backend.query(sql, params: [.text(sanitized), .integer(Int64(limit))])
            return rows.map { messageFromRow($0) }
        } catch {
            return []
        }
    }

    public func fetchToolResult(callId: String) async -> String? {
        let sql = "SELECT content FROM messages WHERE role = 'tool' AND tool_call_id = ? LIMIT 1"
        do {
            let rows = try await backend.query(sql, params: [.text(callId)])
            guard let first = rows.first else { return nil }
            return first.string(at: 0)
        } catch {
            return nil
        }
    }

    public func fetchRecentToolCalls(limit: Int = QueryDefaults.toolCallLimit) async -> [HermesMessage] {
        await fetchRecentToolCallsOutcome(limit: limit).messages
    }

    /// Phase L (v2.8) skeleton fetch for the Activity feed. Returns
    /// metadata-only rows for tool-call-bearing messages — `id`,
    /// `session_id`, `role`, `timestamp`. Everything fat (`content`,
    /// `tool_calls` JSON, `reasoning`, `reasoning_content`) is NULLed
    /// at the SQL level. The wire payload for 50 rows drops to
    /// ~3-5 KB regardless of how big the underlying tool_calls blobs
    /// are. `ActivityViewModel` renders placeholder "Loading tool
    /// calls…" rows from the skeleton, then pages through
    /// `hydrateAssistantToolCalls` to fill the real rows in.
    ///
    /// Mirrors `fetchSkeletonMessages` for the chat path — same
    /// philosophy: get something on screen fast, hydrate the heavy
    /// columns in the background.
    public func fetchRecentToolCallSkeleton(
        limit: Int = QueryDefaults.toolCallLimit
    ) async -> MessageFetchOutcome {
        await ScarfMon.measureAsync(.sessionLoad, "mac.fetchToolCallSkeleton") {
            // Project everything as NULL except the four columns
            // ActivityEntry actually needs to render a placeholder
            // row. The WHERE clause still hits the tool_calls
            // column so SQLite reads it from disk — but it never
            // travels back over SSH.
            let cols: String
            if hasV07Schema {
                cols = "id, session_id, role, NULL AS content, NULL AS tool_call_id, NULL AS tool_calls, NULL AS tool_name, timestamp, NULL AS token_count, NULL AS finish_reason, NULL AS reasoning"
            } else {
                cols = "id, session_id, role, NULL AS content, NULL AS tool_call_id, NULL AS tool_calls, NULL AS tool_name, timestamp, NULL AS token_count, NULL AS finish_reason"
            }
            let sql = """
                SELECT \(cols)
                FROM messages
                WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != ''
                ORDER BY timestamp DESC
                LIMIT ?
                """
            do {
                let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
                let messages = rows.map { messageFromRow($0) }
                ScarfMon.event(.sessionLoad, "mac.fetchToolCallSkeleton.rows", count: messages.count)
                return MessageFetchOutcome(messages: messages, transportError: nil)
            } catch let BackendError.transport(reason) {
                ScarfMon.event(.sessionLoad, "mac.fetchToolCallSkeleton.transportError", count: 1)
                Self.logger.warning("fetchRecentToolCallSkeleton transport error: \(reason, privacy: .public)")
                return MessageFetchOutcome(messages: [], transportError: reason)
            } catch {
                Self.logger.warning("fetchRecentToolCallSkeleton failed: \(error.localizedDescription, privacy: .public)")
                return MessageFetchOutcome(messages: [], transportError: nil)
            }
        }
    }

    /// Outcome variant of `fetchRecentToolCalls` — distinguishes a
    /// genuinely empty result from a transport failure so Activity can
    /// surface a banner instead of the empty-state. v2.8.
    public func fetchRecentToolCallsOutcome(
        limit: Int = QueryDefaults.toolCallLimit
    ) async -> MessageFetchOutcome {
        await ScarfMon.measureAsync(.sessionLoad, "mac.fetchRecentToolCalls") {
            let sql = """
                SELECT \(messageColumnsLight)
                FROM messages
                WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != ''
                ORDER BY timestamp DESC
                LIMIT ?
                """
            do {
                let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
                let messages = rows.map { messageFromRow($0) }
                ScarfMon.event(.sessionLoad, "mac.fetchRecentToolCalls.rows", count: messages.count)
                return MessageFetchOutcome(messages: messages, transportError: nil)
            } catch let BackendError.transport(reason) {
                ScarfMon.event(.sessionLoad, "mac.fetchRecentToolCalls.transportError", count: 1)
                Self.logger.warning("fetchRecentToolCalls transport error: \(reason, privacy: .public)")
                return MessageFetchOutcome(messages: [], transportError: reason)
            } catch {
                Self.logger.warning("fetchRecentToolCalls failed: \(error.localizedDescription, privacy: .public)")
                return MessageFetchOutcome(messages: [], transportError: nil)
            }
        }
    }

    public func fetchSessionPreviews(limit: Int = QueryDefaults.sessionPreviewLimit) async -> [String: String] {
        // Already bounded by `substr(content, 1, previewContentLength)`
        // — wire payload caps at ~limit × 100 bytes. Preview rows use the
        // latest user/assistant message (not the first prompt, not tool
        // result blobs) so iOS chat/session lists show where the
        // conversation currently ended.
        // parity with `fetchRecentToolCallsOutcome`; if this query
        // ever does start timing out on a slow remote we'll see it
        // in captures rather than swallowing the error and returning
        // an empty preview map.
        await ScarfMon.measureAsync(.sessionLoad, "mac.fetchSessionPreviews") {
            let sql = """
                SELECT m.session_id, substr(m.content, 1, \(QueryDefaults.previewContentLength))
                FROM messages m
                INNER JOIN (
                    SELECT session_id, MAX(id) as max_id
                    FROM messages
                    WHERE role IN ('user', 'assistant') AND content <> ''
                    GROUP BY session_id
                ) last ON m.id = last.max_id
                ORDER BY m.timestamp DESC
                LIMIT ?
                """
            do {
                let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
                var previews: [String: String] = [:]
                for row in rows {
                    previews[row.string(at: 0)] = row.string(at: 1)
                }
                ScarfMon.event(.sessionLoad, "mac.fetchSessionPreviews.rows", count: previews.count)
                return previews
            } catch let BackendError.transport(reason) {
                ScarfMon.event(.sessionLoad, "mac.fetchSessionPreviews.transportError", count: 1)
                Self.logger.warning("fetchSessionPreviews transport error: \(reason, privacy: .public)")
                return [:]
            } catch {
                Self.logger.warning("fetchSessionPreviews failed: \(error.localizedDescription, privacy: .public)")
                return [:]
            }
        }
    }

    // MARK: - Single-Row Queries

    public struct MessageFingerprint: Equatable, Sendable {
        let count: Int
        let maxId: Int
        let maxTimestamp: Double

        static let empty = MessageFingerprint(count: 0, maxId: 0, maxTimestamp: 0)
    }

    public func fetchMessageFingerprint(sessionId: String) async -> MessageFingerprint {
        let sql = "SELECT COUNT(*), COALESCE(MAX(id), 0), COALESCE(MAX(timestamp), 0) FROM messages WHERE session_id = ?"
        do {
            let rows = try await backend.query(sql, params: [.text(sessionId)])
            guard let row = rows.first else { return .empty }
            return MessageFingerprint(
                count: row.int(at: 0),
                maxId: row.int(at: 1),
                maxTimestamp: row.double(at: 2)
            )
        } catch {
            return .empty
        }
    }

    public func fetchMessageCount(sessionId: String) async -> Int {
        let sql = "SELECT COUNT(*) FROM messages WHERE session_id = ?"
        do {
            let rows = try await backend.query(sql, params: [.text(sessionId)])
            return rows.first?.int(at: 0) ?? 0
        } catch {
            return 0
        }
    }

    public func fetchSession(id: String) async -> HermesSession? {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE id = ? LIMIT 1"
        do {
            let rows = try await backend.query(sql, params: [.text(id)])
            return rows.first.map { sessionFromRow($0) }
        } catch {
            return nil
        }
    }

    public func fetchMostRecentlyActiveSessionId() async -> String? {
        let sql = "SELECT session_id FROM messages ORDER BY timestamp DESC LIMIT 1"
        do {
            let rows = try await backend.query(sql, params: [])
            return rows.first?.optionalString(at: 0)
        } catch {
            return nil
        }
    }

    public func fetchMostRecentlyStartedSessionId(after: Date? = nil) async -> String? {
        let sql: String
        let params: [SQLValue]
        if let after {
            sql = "SELECT id FROM sessions WHERE parent_session_id IS NULL AND started_at > ? ORDER BY started_at DESC LIMIT 1"
            params = [.real(after.timeIntervalSince1970)]
        } else {
            sql = "SELECT id FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT 1"
            params = []
        }
        do {
            let rows = try await backend.query(sql, params: params)
            return rows.first?.optionalString(at: 0)
        } catch {
            return nil
        }
    }

    // MARK: - Stats

    public struct SessionStats: Sendable {
        public let totalSessions: Int
        public let totalMessages: Int
        public let totalToolCalls: Int
        public let totalInputTokens: Int
        public let totalOutputTokens: Int
        public let totalCostUSD: Double
        public let totalReasoningTokens: Int
        public let totalActualCostUSD: Double

        public init(
            totalSessions: Int,
            totalMessages: Int,
            totalToolCalls: Int,
            totalInputTokens: Int,
            totalOutputTokens: Int,
            totalCostUSD: Double,
            totalReasoningTokens: Int,
            totalActualCostUSD: Double
        ) {
            self.totalSessions = totalSessions
            self.totalMessages = totalMessages
            self.totalToolCalls = totalToolCalls
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.totalCostUSD = totalCostUSD
            self.totalReasoningTokens = totalReasoningTokens
            self.totalActualCostUSD = totalActualCostUSD
        }

        public static let empty = SessionStats(
            totalSessions: 0, totalMessages: 0, totalToolCalls: 0,
            totalInputTokens: 0, totalOutputTokens: 0, totalCostUSD: 0,
            totalReasoningTokens: 0, totalActualCostUSD: 0
        )
    }

    public func fetchStats() async -> SessionStats {
        let sql = statsSQL()
        do {
            let rows = try await backend.query(sql, params: [])
            return rows.first.map { statsFromRow($0) } ?? .empty
        } catch {
            return .empty
        }
    }

    private func statsSQL() -> String {
        if hasV07Schema {
            return """
                SELECT COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(estimated_cost_usd),0),
                       COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(actual_cost_usd),0)
                FROM sessions
                """
        }
        return """
            SELECT COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                   COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(estimated_cost_usd),0)
            FROM sessions
            """
    }

    private func statsFromRow(_ row: Row) -> SessionStats {
        SessionStats(
            totalSessions: row.int(at: 0),
            totalMessages: row.int(at: 1),
            totalToolCalls: row.int(at: 2),
            totalInputTokens: row.int(at: 3),
            totalOutputTokens: row.int(at: 4),
            totalCostUSD: row.double(at: 5),
            totalReasoningTokens: hasV07Schema ? row.int(at: 6) : 0,
            totalActualCostUSD: hasV07Schema ? row.double(at: 7) : 0
        )
    }

    // MARK: - Insights Queries

    public func fetchUserMessageCount(since: Date) async -> Int {
        let sql = """
            SELECT COUNT(*) FROM messages m
            JOIN sessions s ON m.session_id = s.id
            WHERE m.role = 'user' AND s.parent_session_id IS NULL AND s.started_at >= ?
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            return rows.first?.int(at: 0) ?? 0
        } catch {
            return 0
        }
    }

    public func fetchToolUsage(since: Date) async -> [(name: String, count: Int)] {
        let sql = """
            SELECT m.tool_name, COUNT(*) as cnt
            FROM messages m
            JOIN sessions s ON m.session_id = s.id
            WHERE m.tool_name IS NOT NULL AND m.tool_name <> '' AND s.parent_session_id IS NULL AND s.started_at >= ?
            GROUP BY m.tool_name
            ORDER BY cnt DESC
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            return rows.map { (name: $0.string(at: 0), count: $0.int(at: 1)) }
        } catch {
            return []
        }
    }

    public func fetchSessionStartHours(since: Date) async -> [Int: Int] {
        let sql = """
            SELECT started_at FROM sessions WHERE parent_session_id IS NULL AND started_at >= ?
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            var hours: [Int: Int] = [:]
            let calendar = Calendar.current
            for row in rows {
                if let date = row.date(at: 0) {
                    let hour = calendar.component(.hour, from: date)
                    hours[hour, default: 0] += 1
                }
            }
            return hours
        } catch {
            return [:]
        }
    }

    public func fetchSessionDaysOfWeek(since: Date) async -> [Int: Int] {
        let sql = """
            SELECT started_at FROM sessions WHERE parent_session_id IS NULL AND started_at >= ?
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            var days: [Int: Int] = [:]
            let calendar = Calendar.current
            for row in rows {
                if let date = row.date(at: 0) {
                    let weekday = (calendar.component(.weekday, from: date) + 5) % 7 // Mon=0
                    days[weekday, default: 0] += 1
                }
            }
            return days
        } catch {
            return [:]
        }
    }

    // MARK: - Batched snapshots

    /// Bundle the four queries Dashboard fires on every load into one
    /// backend round-trip. For local backends this is just four
    /// sequential `query` calls (no perf change). For remote backends
    /// it's one SSH round-trip running one sqlite3 invocation, which
    /// turns Dashboard's "open" cost from ~280 ms (4 × 70 ms) into
    /// ~80–100 ms.
    public struct DashboardSnapshot: Sendable {
        public let stats: SessionStats
        public let recentSessions: [HermesSession]
        public let sessionPreviews: [String: String]
        public let recentToolCalls: [HermesMessage]
    }

    public func dashboardSnapshot(
        sessionLimit: Int = 5,
        previewLimit: Int = 5,
        toolCallLimit: Int = 8
    ) async -> DashboardSnapshot {
        let statements: [(sql: String, params: [SQLValue])] = [
            (statsSQL(), []),
            (
                "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL ORDER BY \(sessionLastActivityOrder) LIMIT ?",
                [.integer(Int64(sessionLimit))]
            ),
            (
                """
                SELECT m.session_id, substr(m.content, 1, \(QueryDefaults.previewContentLength))
                FROM messages m
                INNER JOIN (
                    SELECT session_id, MAX(id) as max_id
                    FROM messages
                    WHERE role IN ('user', 'assistant') AND content <> ''
                    GROUP BY session_id
                ) last ON m.id = last.max_id
                ORDER BY m.timestamp DESC
                LIMIT ?
                """,
                [.integer(Int64(previewLimit))]
            ),
            (
                """
                SELECT \(messageColumns)
                FROM messages
                WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != ''
                ORDER BY timestamp DESC
                LIMIT ?
                """,
                [.integer(Int64(toolCallLimit))]
            )
        ]
        do {
            let resultSets = try await backend.queryBatch(statements)
            let stats = resultSets.first?.first.map { statsFromRow($0) } ?? .empty
            let sessions = (resultSets.count > 1 ? resultSets[1] : []).map { sessionFromRow($0) }
            var previews: [String: String] = [:]
            for row in (resultSets.count > 2 ? resultSets[2] : []) {
                previews[row.string(at: 0)] = row.string(at: 1)
            }
            let toolCalls = (resultSets.count > 3 ? resultSets[3] : []).map { messageFromRow($0) }
            return DashboardSnapshot(
                stats: stats,
                recentSessions: sessions,
                sessionPreviews: previews,
                recentToolCalls: toolCalls
            )
        } catch {
            Self.logger.warning("dashboardSnapshot failed: \(error.localizedDescription, privacy: .public)")
            return DashboardSnapshot(
                stats: .empty,
                recentSessions: [],
                sessionPreviews: [:],
                recentToolCalls: []
            )
        }
    }

    /// Bundle for the chat sidebar / Sessions tab loaders. Folds
    /// `fetchSessions(limit:)` + `fetchSessionPreviews(limit:)` into
    /// one `queryBatch()` round-trip — same shape as
    /// `dashboardSnapshot`. Pre-fix `ChatViewModel.loadRecentSessions`
    /// + `SessionsViewModel.load` each fired the two `await
    /// dataService.fetch*` calls in serial, paying the SSH RTT
    /// twice (~840 ms minimum on a 420 ms-RTT remote, observed in
    /// ScarfMon `mac.loadRecentSessions` traces). Halves the
    /// round-trips for every sidebar load. Each tick still pays
    /// for `dashboard.loadRegistry` separately because that's a
    /// projects.json read (not SQL) and goes through a different
    /// transport call.
    public struct SessionListSnapshot: Sendable {
        public let sessions: [HermesSession]
        public let previews: [String: String]
    }

    public func sessionListSnapshot(limit: Int = QueryDefaults.sessionLimit) async -> SessionListSnapshot {
        let previewLimit = limit
        let statements: [(sql: String, params: [SQLValue])] = [
            (
                "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL ORDER BY \(sessionLastActivityOrder) LIMIT ?",
                [.integer(Int64(limit))]
            ),
            (
                """
                SELECT m.session_id, substr(m.content, 1, \(QueryDefaults.previewContentLength))
                FROM messages m
                INNER JOIN (
                    SELECT session_id, MAX(id) as max_id
                    FROM messages
                    WHERE role IN ('user', 'assistant') AND content <> ''
                    GROUP BY session_id
                ) last ON m.id = last.max_id
                ORDER BY m.timestamp DESC
                LIMIT ?
                """,
                [.integer(Int64(previewLimit))]
            )
        ]
        do {
            let resultSets = try await backend.queryBatch(statements)
            let sessions = (resultSets.first ?? []).map { sessionFromRow($0) }
            var previews: [String: String] = [:]
            for row in (resultSets.count > 1 ? resultSets[1] : []) {
                previews[row.string(at: 0)] = row.string(at: 1)
            }
            return SessionListSnapshot(sessions: sessions, previews: previews)
        } catch {
            Self.logger.warning("sessionListSnapshot failed: \(error.localizedDescription, privacy: .public)")
            return SessionListSnapshot(sessions: [], previews: [:])
        }
    }

    /// Bundle the queries Insights fires on every load into one
    /// backend round-trip — same rationale as `dashboardSnapshot`.
    public struct InsightsSnapshot: Sendable {
        public let userMessageCount: Int
        public let toolUsage: [(name: String, count: Int)]
        public let startHours: [Int: Int]
        public let daysOfWeek: [Int: Int]
    }

    public func insightsSnapshot(since: Date) async -> InsightsSnapshot {
        let sinceTs = since.timeIntervalSince1970
        let statements: [(sql: String, params: [SQLValue])] = [
            (
                """
                SELECT COUNT(*) FROM messages m
                JOIN sessions s ON m.session_id = s.id
                WHERE m.role = 'user' AND s.parent_session_id IS NULL AND s.started_at >= ?
                """,
                [.real(sinceTs)]
            ),
            (
                """
                SELECT m.tool_name, COUNT(*) as cnt
                FROM messages m
                JOIN sessions s ON m.session_id = s.id
                WHERE m.tool_name IS NOT NULL AND m.tool_name <> '' AND s.parent_session_id IS NULL AND s.started_at >= ?
                GROUP BY m.tool_name
                ORDER BY cnt DESC
                """,
                [.real(sinceTs)]
            ),
            (
                "SELECT started_at FROM sessions WHERE parent_session_id IS NULL AND started_at >= ?",
                [.real(sinceTs)]
            )
        ]
        do {
            let resultSets = try await backend.queryBatch(statements)
            let userCount = resultSets.first?.first?.int(at: 0) ?? 0
            let toolUsage = (resultSets.count > 1 ? resultSets[1] : []).map {
                (name: $0.string(at: 0), count: $0.int(at: 1))
            }
            // The third statement returns timestamps; client-side
            // calendar bucketing into hours + days-of-week.
            let calendar = Calendar.current
            var hours: [Int: Int] = [:]
            var days: [Int: Int] = [:]
            for row in (resultSets.count > 2 ? resultSets[2] : []) {
                guard let date = row.date(at: 0) else { continue }
                let hour = calendar.component(.hour, from: date)
                hours[hour, default: 0] += 1
                let weekday = (calendar.component(.weekday, from: date) + 5) % 7
                days[weekday, default: 0] += 1
            }
            return InsightsSnapshot(
                userMessageCount: userCount,
                toolUsage: toolUsage,
                startHours: hours,
                daysOfWeek: days
            )
        } catch {
            return InsightsSnapshot(userMessageCount: 0, toolUsage: [], startHours: [:], daysOfWeek: [:])
        }
    }

    // MARK: - Modification date

    public func stateDBModificationDate() -> Date? {
        // For remote contexts we stat the remote paths. For local it's the
        // same FileManager lookup as before, just via the transport.
        let walDate = transport.stat(context.paths.stateDB + "-wal")?.mtime
        let dbDate = transport.stat(context.paths.stateDB)?.mtime
        if let w = walDate, let d = dbDate {
            return max(w, d)
        }
        return walDate ?? dbDate
    }

    // MARK: - Row Parsing

    private func sessionFromRow(_ row: Row) -> HermesSession {
        // v0.11 column lives at index 20 (after the 16 base + 4 v0.7
        // columns). Reading defensively — old DBs that lack the column
        // never reach this code path because hasV011Schema gates the
        // SELECT shape.
        let apiCallCount: Int = hasV011Schema ? row.int(at: 20) : 0
        let lastActivityAt = row.columnIndex["last_activity_at"].flatMap { row.date(at: $0) }
            ?? row.date(at: 7)
            ?? row.date(at: 6)
        return HermesSession(
            id: row.string(at: 0),
            source: row.string(at: 1),
            userId: row.optionalString(at: 2),
            model: row.optionalString(at: 3),
            title: row.optionalString(at: 4),
            parentSessionId: row.optionalString(at: 5),
            startedAt: row.date(at: 6),
            endedAt: row.date(at: 7),
            endReason: row.optionalString(at: 8),
            messageCount: row.int(at: 9),
            toolCallCount: row.int(at: 10),
            inputTokens: row.int(at: 11),
            outputTokens: row.int(at: 12),
            cacheReadTokens: row.int(at: 13),
            cacheWriteTokens: row.int(at: 14),
            estimatedCostUSD: row.optionalDouble(at: 15),
            reasoningTokens: hasV07Schema ? row.int(at: 16) : 0,
            actualCostUSD: hasV07Schema ? row.optionalDouble(at: 17) : nil,
            costStatus: hasV07Schema ? row.optionalString(at: 18) : nil,
            billingProvider: hasV07Schema ? row.optionalString(at: 19) : nil,
            apiCallCount: apiCallCount,
            lastActivityAt: lastActivityAt
        )
    }

    private func messageFromRow(_ row: Row) -> HermesMessage {
        let toolCallsJSON = row.optionalString(at: 5)
        let toolCalls = parseToolCalls(toolCallsJSON)
        // reasoning lives at index 10 (v0.7+); reasoning_content at 11
        // when v0.11 schema is present. Both columns can carry text
        // simultaneously — UI prefers `reasoningContent`.
        let reasoningContent: String? = hasV011Schema ? row.optionalString(at: 11) : nil
        return HermesMessage(
            id: row.int(at: 0),
            sessionId: row.string(at: 1),
            role: row.string(at: 2),
            content: row.string(at: 3),
            toolCallId: row.optionalString(at: 4),
            toolCalls: toolCalls,
            toolName: row.optionalString(at: 6),
            timestamp: row.date(at: 7),
            tokenCount: row.optionalInt(at: 8),
            finishReason: row.optionalString(at: 9),
            reasoning: hasV07Schema ? row.optionalString(at: 10) : nil,
            reasoningContent: reasoningContent
        )
    }

    private func parseToolCalls(_ json: String?) -> [HermesToolCall] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([HermesToolCall].self, from: data)
        } catch {
            Self.logger.error("Failed to decode tool calls: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Wraps each whitespace-delimited token in double quotes to prevent FTS5 parse errors
    /// on terms containing dots, hyphens, or FTS5 operators (e.g., "v0.7.0", "config.yaml").
    private func sanitizeFTSQuery(_ raw: String) -> String {
        raw.split(separator: " ")
            .map { token in
                let t = String(token)
                let stripped = t.replacingOccurrences(of: "\"", with: "")
                return stripped.isEmpty ? nil : "\"\(stripped)\""
            }
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

#endif // canImport(SQLite3)
