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
    private var hasMessagesActiveColumn = false
    private var hasCompactedColumn = false
    private var hasCompressedSummaryColumn = false
    private var hasRewindCountColumn = false
    private var hasSessionActivityColumns = false
    private var hasSessionModelUsageTable = false
    private var hasHiddenColumn = false
    private var hasLastReadAtColumn = false
    private var hasListableChildSupport = false

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
        hasMessagesActiveColumn = await backend.hasMessagesActiveColumn
        hasCompactedColumn = await backend.hasCompactedColumn
        hasCompressedSummaryColumn = await backend.hasCompressedSummaryColumn
        hasRewindCountColumn = await backend.hasRewindCountColumn
        hasSessionActivityColumns = await backend.hasSessionActivityColumns
        hasSessionModelUsageTable = await backend.hasSessionModelUsageTable
        hasHiddenColumn = await backend.hasHiddenColumn
        hasLastReadAtColumn = await backend.hasLastReadAtColumn
        hasListableChildSupport = await backend.hasListableChildSupport
        lastOpenError = await backend.lastOpenError
        return ok
    }

    @discardableResult
    public func refresh(forceFresh: Bool = false) async -> Bool {
        let ok = await backend.refresh(forceFresh: forceFresh)
        hasV07Schema = await backend.hasV07Schema
        hasV011Schema = await backend.hasV011Schema
        hasMessagesActiveColumn = await backend.hasMessagesActiveColumn
        hasCompactedColumn = await backend.hasCompactedColumn
        hasCompressedSummaryColumn = await backend.hasCompressedSummaryColumn
        hasRewindCountColumn = await backend.hasRewindCountColumn
        hasSessionActivityColumns = await backend.hasSessionActivityColumns
        hasSessionModelUsageTable = await backend.hasSessionModelUsageTable
        hasHiddenColumn = await backend.hasHiddenColumn
        hasLastReadAtColumn = await backend.hasLastReadAtColumn
        hasListableChildSupport = await backend.hasListableChildSupport
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
        // v0.16: appended last so its row index depends on the v0.7/v0.11
        // blocks above — sessionFromRow reads it by column name, not a
        // hardcoded position, to stay correct across those combinations.
        if hasRewindCountColumn {
            cols += ", rewind_count"
        }
        // v0.20: appended last, read by column NAME in sessionFromRow
        // (same pattern as rewind_count) so positions stay stable
        // across every earlier schema combination. Absent columns
        // (pre-0.20 DB) → identical SELECT shape to today.
        if hasSessionActivityColumns {
            cols += ", pinned, last_activity_at, last_activity_description"
        }
        // v0.20.4: read watermark. Appended last and read by column
        // NAME in sessionFromRow, same pattern as everything above.
        // Absent (pre-v0.20.4 DB) → identical SELECT shape to today.
        // READ ONLY: Scarf never writes `last_read_at` — state.db is
        // opened read-only and Hermes owns the watermark
        // (`set_session_read`). Scarf only derives `isUnread` from it.
        if hasLastReadAtColumn {
            cols += ", last_read_at"
        }
        return cols
    }

    /// `sessionColumns` plus Hermes's session-recency expression, for the
    /// LIST queries only.
    ///
    /// Ports `_sql_session_last_active` (hermes_state_common.py:169-191):
    /// the freshest of `last_activity_at` and `MAX(messages.timestamp)`,
    /// falling back to `started_at`. The message max is the dominant term
    /// — the durable heartbeat is rate-limited (~60 s) and best-effort, so
    /// after a turn writes messages `last_activity_at` lags them. Deriving
    /// unread from the heartbeat alone silently under-reports.
    ///
    /// **Cost.** This is a correlated subquery per row, so it rides ONLY
    /// on the queries whose rows feed the unread badge, and only when
    /// `last_read_at` exists — without the watermark column `isUnread` is
    /// unconditionally false and the subquery would buy nothing. That gate
    /// also keeps the emitted SQL byte-identical on pre-v0.20.4 hosts.
    /// Hermes pays exactly the same per-row cost in `list_sessions_rich`,
    /// and `messages.session_id` is indexed.
    private var sessionListColumns: String {
        guard hasLastReadAtColumn else { return sessionColumns }
        let a = hasListableChildSupport ? "s" : "sessions"
        let msgMax = "(SELECT MAX(_act_m.timestamp) FROM messages _act_m WHERE _act_m.session_id = \(a).id)"
        // The heartbeat column only exists from v0.20; without it the
        // expression degrades to MAX(messages.timestamp) ?? started_at,
        // which is still the dominant term.
        let freshest: String = hasSessionActivityColumns
            ? "(SELECT MAX(_act_v.v) FROM (SELECT \(a).last_activity_at AS v UNION ALL SELECT \(msgMax)) _act_v)"
            : msgMax
        return sessionColumns + ", COALESCE(\(freshest), \(a).started_at) AS last_active"
    }

    // MARK: - Session list predicate (Hermes parity)

    /// `FROM` clause for the session-list queries. Aliased to `s` only
    /// when the listable-child predicate is active — it needs a stable
    /// outer alias to correlate its `sessions p` subqueries against.
    /// Without it the emitted SQL stays byte-identical to pre-v0.20.4.
    private var sessionListFrom: String {
        hasListableChildSupport ? "sessions s" : "sessions"
    }

    /// `WHERE` predicate selecting the rows a session list shows.
    ///
    /// Mirrors Hermes's `_LISTABLE_CHILD_SQL`
    /// (hermes_state_common.py:169-175): roots, plus branch children,
    /// plus reset children — subagent runs and compression
    /// continuations stay out. Reset children are identified by the
    /// `_reset_from` marker in `model_config`, with the same-`session_key`
    /// legacy fallback for rows written before the marker existed
    /// (`_legacy_reset_child_sql`, :117-133). Without this, a
    /// conversation continued after `/reset` is invisible in Scarf.
    ///
    /// `json_extract` is used rather than the `->>` operator Hermes
    /// spells it with: `->>` needs SQLite 3.38+ *syntax* support, while
    /// `json_extract` is the portable spelling of the same thing and
    /// the JSON1 availability is probed at open().
    ///
    /// `hidden = 0` rides along when `sessions.hidden` exists so Scarf
    /// shows the same set Hermes does.
    private var sessionListPredicate: String {
        var clauses: [String] = []
        if hasListableChildSupport {
            let branch = """
                json_extract(COALESCE(s.model_config, '{}'), '$._branched_from') IS NOT NULL \
                OR EXISTS (SELECT 1 FROM sessions p WHERE p.id = s.parent_session_id \
                AND p.end_reason = 'branched' AND s.started_at >= p.ended_at)
                """
            clauses.append("(s.parent_session_id IS NULL OR \(branch) OR \(Self.resetChildSQL))")
        } else {
            clauses.append("parent_session_id IS NULL")
        }
        if hasHiddenColumn {
            clauses.append(hasListableChildSupport ? "s.hidden = 0" : "hidden = 0")
        }
        return clauses.joined(separator: " AND ")
    }

    /// Hermes's `_RESET_CHILD_SQL` (hermes_state_common.py:139-143)
    /// against the outer alias `s`: the durable `_reset_from` marker,
    /// or the pre-marker heuristic — a child riding its parent's exact
    /// non-empty routing key where the parent ended at a reset
    /// boundary. `_RESET_END_REASONS` is copied verbatim from :100-113.
    private static let resetChildSQL = """
        json_extract(COALESCE(s.model_config, '{}'), '$._reset_from') IS NOT NULL \
        OR EXISTS (SELECT 1 FROM sessions p WHERE p.id = s.parent_session_id \
        AND p.end_reason IN ('session_reset', 'session_switch', 'idle', 'daily', 'suspended', 'resume_pending_expired') \
        AND s.session_key IS NOT NULL AND s.session_key != '' AND s.session_key = p.session_key)
        """

    /// Hermes's `_ephemeral_child_sql` (hermes_state_common.py:178-190)
    /// for the children of one parent: subagent runs only — not branch,
    /// reset, or compression continuations. Used by
    /// `fetchSubagentSessions` so a post-reset conversation isn't
    /// rendered as a subagent run of the session it continued.
    private var subagentChildPredicate: String {
        guard hasListableChildSupport else { return "parent_session_id = ?" }
        let branch = """
            json_extract(COALESCE(s.model_config, '{}'), '$._branched_from') IS NOT NULL \
            OR EXISTS (SELECT 1 FROM sessions p WHERE p.id = s.parent_session_id \
            AND p.end_reason = 'branched' AND s.started_at >= p.ended_at)
            """
        let compression = """
            EXISTS (SELECT 1 FROM sessions p WHERE p.id = s.parent_session_id \
            AND p.end_reason = 'compression')
            """
        return """
            s.parent_session_id = ? AND NOT (\(branch)) \
            AND NOT (\(compression)) AND NOT (\(Self.resetChildSQL))
            """
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
        // v0.11+ `reasoning_content` BLOB stays excluded (heavy). We select a
        // NULL placeholder — keeps index 11 == reasoning_content to match
        // `messageColumns` / `messageFromRow` — plus a cheap boolean
        // `hasReasoningContent` (index 12, read by NAME) so the REASONING
        // disclosure renders on resume for messages that have reasoning_content
        // but a NULL legacy `reasoning` (v0.16 thinking models — t-aud27). The
        // blob itself still lazy-loads via `reasoningContent(for:)`.
        if hasV011Schema {
            cols += ", NULL AS reasoning_content, (reasoning_content IS NOT NULL AND reasoning_content != '') AS hasReasoningContent"
        }
        return cols
    }

    /// Skeleton column set for the v2.8 two-phase chat loader. Returns
    /// EVERYTHING needed to render a user-or-assistant bubble — id,
    /// role, content, timestamp, token_count, finish_reason, plus the
    /// small `reasoning` channel — while hard-NULLing `tool_calls` and
    /// EXCLUDING `reasoning_content` (the heavy 20+ KB-per-message
    /// chain-of-thought blob) so the wire payload stays bounded by the
    /// conversational text. A 30-message session with multi-page tool
    /// result blobs that previously timed out the 30s SSH budget
    /// reduces here to a few KB. The chat appears in seconds; tool
    /// details fill in via `hydrateAssistantToolCalls(...)` and
    /// `hydrateToolResults(...)` in the background.
    ///
    /// `reasoning` is SELECTED (not NULLed) so the REASONING disclosure
    /// renders on resume — matching `messageColumnsLight`, which every
    /// other history path already uses. NULLing it here (pre-fix,
    /// t-aud01) left resumed thinking-model chats with no visible
    /// reasoning at all. The richer `reasoning_content` stays excluded
    /// and lazy-loads per-message via `fetchReasoningContent(for:)`.
    ///
    /// The schema-shape match against `messageFromRow` is exact — same
    /// column ordering as `messageColumnsLight`. `messageFromRow` reads
    /// `reasoning` at index 10 and defaults `reasoning_content` to nil
    /// via the bounds-safe `Row` subscript when the column is absent.
    private var messageColumnsSkeleton: String {
        var cols = """
            id, session_id, role, content, tool_call_id, NULL AS tool_calls,
            tool_name, timestamp, token_count, finish_reason
            """
        if hasV07Schema {
            cols += ", reasoning"
        }
        // Same shape as `messageColumnsLight`: NULL placeholder at index 11 to
        // hold the reasoning_content slot, plus the cheap `hasReasoningContent`
        // boolean so the disclosure shows on resume for reasoning_content-only
        // messages (t-aud27). Blob excluded; lazy-loads on disclosure open.
        if hasV011Schema {
            cols += ", NULL AS reasoning_content, (reasoning_content IS NOT NULL AND reasoning_content != '') AS hasReasoningContent"
        }
        return cols
    }

    // MARK: - Session Queries

    public func fetchSessions(limit: Int = QueryDefaults.sessionLimit) async -> [HermesSession] {
        let sql = "SELECT \(sessionListColumns) FROM \(sessionListFrom) WHERE \(sessionListPredicate) ORDER BY started_at DESC LIMIT ?"
        do {
            let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
            return rows.map { sessionFromRow($0) }
        } catch {
            Self.logger.warning("fetchSessions failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func fetchSessionsInPeriod(since: Date) async -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM \(sessionListFrom) WHERE \(sessionListPredicate) AND started_at >= ? ORDER BY started_at DESC"
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            return rows.map { sessionFromRow($0) }
        } catch {
            return []
        }
    }

    public func fetchSubagentSessions(parentId: String) async -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM \(sessionListFrom) WHERE \(subagentChildPredicate) ORDER BY started_at ASC"
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
            let activeClause = hasMessagesActiveColumn ? " AND active = 1" : ""
            if let before {
                sql = "SELECT \(messageColumnsLight) FROM messages WHERE session_id = ? AND id < ?\(activeClause) ORDER BY id DESC LIMIT ?"
                params = [.text(sessionId), .integer(Int64(before)), .integer(Int64(limit))]
            } else {
                sql = "SELECT \(messageColumnsLight) FROM messages WHERE session_id = ?\(activeClause) ORDER BY id DESC LIMIT ?"
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
            let activeClause = hasMessagesActiveColumn ? " AND active = 1" : ""
            if let before {
                sql = "SELECT \(messageColumnsSkeleton) FROM messages WHERE session_id = ? AND role IN ('user','assistant') AND id < ? \(activeClause) ORDER BY id DESC LIMIT ?"
                params = [.text(sessionId), .integer(Int64(before)), .integer(Int64(limit))]
            } else {
                sql = "SELECT \(messageColumnsSkeleton) FROM messages WHERE session_id = ? AND role IN ('user','assistant') \(activeClause) ORDER BY id DESC LIMIT ?"
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

            // v2.18 perf — batch all pages into ONE remote round-trip.
            // Every page is a separate sqlite3 -json invocation today
            // (one SSH exec per query), so a 30-assistant-message
            // session pays 6 round-trips just to hydrate tool cards.
            // queryBatch folds them into a single sqlite3 process with
            // marker-split result sets (~50-100ms total on a warm
            // ControlMaster vs 6 × cold-start). The existing per-page
            // loop below stays as the fallback when the batch trips
            // the transport timeout (oversized tool_calls blobs), so
            // the whale-isolation behaviour is preserved.
            let batchSQL: [(sql: String, params: [SQLValue])] = pages.map { page in
                let placeholders = Array(repeating: "?", count: page.count).joined(separator: ",")
                let sql = "SELECT id, tool_calls FROM messages WHERE id IN (\(placeholders)) AND tool_calls IS NOT NULL AND tool_calls != '' AND tool_calls != '[]'"
                return (sql: sql, params: page.map { .integer(Int64($0)) })
            }
            if !batchSQL.isEmpty {
                do {
                    let results = try await backend.queryBatch(batchSQL)
                    for (_, rows) in zip(pages, results) {
                        if Task.isCancelled {
                            ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.cancelled", count: 1)
                            return out
                        }
                        for row in rows {
                            let id = row.int(at: 0)
                            let json = row.optionalString(at: 1)
                            let parsed = parseToolCalls(json)
                            if !parsed.isEmpty {
                                out[id] = parsed
                            }
                        }
                    }
                    ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.batch", count: 1)
                    ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.rows", count: out.count)
                    return out
                } catch is CancellationError {
                    return out
                } catch {
                    // Transport timeout / sqlite failure on the whole
                    // batch — fall through to the legacy per-page loop
                    // below, which isolates whales with single-id
                    // retries exactly as before.
                    ScarfMon.event(.sessionLoad, "mac.hydrateToolCalls.batchFallback", count: 1)
                    Self.logger.warning("hydrateToolCalls queryBatch failed, falling back to per-page loop: \(error.localizedDescription, privacy: .public)")
                }
            }
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
            let activeClause = hasMessagesActiveColumn ? " AND active = 1" : ""
            let sql = "SELECT \(messageColumnsLight) FROM messages WHERE session_id = ? AND role = 'tool' AND id >= ? AND id <= ? \(activeClause) ORDER BY id DESC LIMIT ?"
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
        // v0.18 in-place compaction keeps summarized-away rows
        // discoverable: Hermes search_messages includes them
        // (`active = 1 OR compacted = 1`), while rewind/undo rows
        // (active=0, compacted=0) stay hidden. Mirror that so Scarf
        // searches the same ROW SET as `hermes sessions search` on the
        // same DB. Transcript/activity fetches above stay active-only
        // — Hermes reloads only the active set there too.
        //
        // The QUERY TEXT deliberately does NOT match Hermes's: Hermes
        // strips FTS5's special characters
        // (`_FTS5_SPECIAL_CHARS`/`_sanitize_fts5_query`, completed in
        // v0.20.4 by c595dcb955), whereas `sanitizeFTSQuery` below
        // quotes each token as a phrase. Both keep MATCH parsable;
        // quoting additionally preserves the term (`gateway/run.py`
        // stays one phrase rather than becoming `gateway run py`), so
        // Scarf can return hits on punctuated terms that Hermes
        // broadens. Kept on purpose — do not "fix" it into parity.
        let activeClause: String
        if hasMessagesActiveColumn {
            activeClause = hasCompactedColumn
                ? " AND (m.active = 1 OR m.compacted = 1)"
                : " AND m.active = 1"
        } else {
            activeClause = ""
        }
        let sql = """
            SELECT \(msgCols)
            FROM messages_fts fts
            JOIN messages m ON m.id = fts.rowid
            WHERE messages_fts MATCH ? \(activeClause)
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
            let activeClause = hasMessagesActiveColumn ? " AND active = 1" : ""
            let sql = """
                SELECT \(cols)
                FROM messages
                WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != '' \(activeClause)
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
            let activeClause = hasMessagesActiveColumn ? " AND active = 1" : ""
            let sql = """
                SELECT \(messageColumnsLight)
                FROM messages
                WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != '' \(activeClause)
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

    /// Inner "first eligible user row per session" subquery shared by
    /// `fetchSessionPreviews`, `dashboardSnapshot` and
    /// `sessionListSnapshot`. Carries the schema gate for
    /// `messages.active` / `messages.compacted`, so the three call sites
    /// stay a single string interpolation. See `SessionPreviewSQL`.
    private var sessionPreviewFirstRowSQL: String {
        SessionPreviewSQL.firstEligibleUserRowSQL(
            hasActiveColumn: hasMessagesActiveColumn,
            hasCompactedColumn: hasCompactedColumn
        )
    }

    public func fetchSessionPreviews(limit: Int = QueryDefaults.sessionPreviewLimit) async -> [String: String] {
        // Already bounded by `substr(content, 1, previewContentLength)`
        // — wire payload caps at ~limit × 100 bytes. v2.8 added
        // ScarfMon instrumentation + transport-error logging for
        // parity with `fetchRecentToolCallsOutcome`; if this query
        // ever does start timing out on a slow remote we'll see it
        // in captures rather than swallowing the error and returning
        // an empty preview map.
        await ScarfMon.measureAsync(.sessionLoad, "mac.fetchSessionPreviews") {
            let sql = """
                SELECT m.session_id, \(SessionPreviewSQL.rawSelect())
                FROM messages m
                INNER JOIN (
                \(sessionPreviewFirstRowSQL)
                ) first ON m.id = first.min_id
                ORDER BY m.timestamp DESC
                LIMIT ?
                """
            do {
                let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
                var previews: [String: String] = [:]
                for row in rows {
                    previews[row.string(at: 0)] = SessionPreviewSQL.shape(row.string(at: 1))
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

    // MARK: - Canonical Bot Chat resolution (Bot Mode)

    /// A resolved canonical Bot Chat. Two ids, because they are two
    /// different things and conflating them is a real bug:
    /// - `registryId` is the row that holds the `"Bot Chat"` title. It is
    ///   the bot's conversation *identity* and the value to compare against
    ///   on a later re-resolve.
    /// - `liveId` is the compression tip — the session to load, replay, and
    ///   prompt into. On a young chat the two are equal.
    public struct CanonicalBotChat: Sendable, Equatable {
        public let registryId: String
        public let liveId: String

        public init(registryId: String, liveId: String) {
            self.registryId = registryId
            self.liveId = liveId
        }
    }

    /// Fetch the session whose title is EXACTLY `title`, hidden rows
    /// included.
    ///
    /// Deliberately not routed through `sessionListPredicate`: every other
    /// session query in this service appends `hidden = 0` when the column
    /// exists, and Bot Mode's canonical chats are *always* created hidden
    /// (`apps/desktop/src/plugins/hermes-bots/canonical-chat.ts:334-338`
    /// passes `hidden: true`; `hermes_cli/subcommands/peer.py:135-144`
    /// needs `include_hidden=1` for the same reason). Reusing the ordinary
    /// listing here would report "this bot has no conversation" for every
    /// correctly-created bot, and the caller would then try to mint a
    /// duplicate that Hermes' `UNIQUE(title)` guard rejects.
    ///
    /// Hermes enforces title uniqueness, so at most one row can match; the
    /// ordering is a tie-break for a legacy database written before that
    /// guard existed.
    public func fetchSessionByExactTitle(_ title: String) async -> HermesSession? {
        let sql = """
            SELECT \(sessionColumns) FROM sessions
            WHERE title = ?
            ORDER BY started_at DESC
            LIMIT 1
            """
        do {
            let rows = try await backend.query(sql, params: [.text(title)])
            return rows.first.map { sessionFromRow($0) }
        } catch {
            return nil
        }
    }

    /// Project a session id forward through its compression-continuation
    /// chain and return the live tip, or `sessionId` when there is none.
    ///
    /// A long-lived conversation gets compressed: the old session is ended
    /// with `end_reason = 'compression'` and a child row continues it. The
    /// canonical Bot Chat is a *forever* chat, so this is not an edge case
    /// for it — the registry row that holds the title is frequently a dead
    /// ancestor with the conversation living further down the chain.
    /// Opening the ancestor would show a truncated transcript and send new
    /// turns into a closed session.
    ///
    /// Ported from `hermes_state.SessionDB.get_compression_tip` (:10754).
    /// Three properties of that query are load-bearing and kept:
    /// - only children of a **compression-ended parent** are followed. This
    ///   is the whole discriminator. `parent_session_id` is also how
    ///   subagents, branches and delegates hang off a session, so walking
    ///   children without this gate would happily wander into a subagent
    ///   transcript and present it as the bot's chat.
    /// - branch/delegate children (`model_config._branched_from` /
    ///   `._delegate_from`) and `source = 'tool'` children are excluded even
    ///   under a compressed parent.
    /// - a live or still-compressing child outranks a closed sibling (a
    ///   `ws_orphan_reap` stub), so a stale sibling can't capture the walk.
    ///
    /// Hermes' own ordering additionally consults a "last active"
    /// expression; this uses `COALESCE(ended_at, started_at)`, which agrees
    /// with it on every ordinary row and only differs among siblings the
    /// `CASE` has already separated.
    ///
    /// The walk is bounded at 100 hops with a seen-set, so a cyclic or
    /// pathological chain terminates instead of hanging the open.
    public func compressionTip(for sessionId: String) async -> String {
        let hasModelConfig = await sessionsTableHasColumn("model_config")
        // `end_reason` predates every schema Scarf supports, but a database
        // without it cannot express a compression chain at all — the walk
        // would then be unbounded-by-predicate rather than empty, so bail.
        guard await sessionsTableHasColumn("end_reason") else { return sessionId }

        let exclusions = hasModelConfig ? """
              AND json_extract(COALESCE(child.model_config, '{}'), '$._branched_from') IS NULL
              AND json_extract(COALESCE(child.model_config, '{}'), '$._delegate_from') IS NULL
            """ : ""
        let sql = """
            SELECT child.id
            FROM sessions parent
            JOIN sessions child ON child.parent_session_id = parent.id
            WHERE parent.id = ?
              AND parent.end_reason = 'compression'
            \(exclusions)
              AND COALESCE(child.source, '') != 'tool'
            ORDER BY
              CASE
                WHEN child.end_reason = 'compression' THEN 0
                WHEN child.ended_at IS NULL THEN 1
                ELSE 2
              END,
              COALESCE(child.ended_at, child.started_at) DESC,
              child.started_at DESC,
              child.id DESC
            LIMIT 1
            """

        var current = sessionId
        var seen: Set<String> = [current]
        for _ in 0..<100 {
            let next: String?
            do {
                let rows = try await backend.query(sql, params: [.text(current)])
                next = rows.first?.optionalString(at: 0)
            } catch {
                return current
            }
            guard let child = next, !child.isEmpty, !seen.contains(child) else { return current }
            seen.insert(child)
            current = child
        }
        return current
    }

    /// Resolve a bot profile's canonical "Bot Chat" — the registry row that
    /// holds the title, plus the live session id to actually open.
    ///
    /// Returns `nil` when the profile has no Bot Chat yet. That is a normal
    /// state, not an error: the conversation is created by the first message
    /// sent to the bot, never speculatively.
    ///
    /// The service must be pointed at THAT PROFILE's `state.db` — construct
    /// it with `ServerContext.pinnedToProfile(_:)`. Each profile carries its
    /// own database under `<root>/profiles/<name>/state.db`; running this
    /// against the root home finds the *user's* session titled "Bot Chat",
    /// if any, and would render one profile's conversation under another
    /// bot's name.
    public func locateCanonicalBotChat() async -> CanonicalBotChat? {
        guard let registry = await fetchSessionByExactTitle(BotChatSession.canonicalTitle) else {
            return nil
        }
        let tip = await compressionTip(for: registry.id)
        return CanonicalBotChat(registryId: registry.id, liveId: tip)
    }

    /// PRAGMA-driven column probe for the `sessions` table. Scarf never
    /// assumes a schema by Hermes version — the charter is detection, and a
    /// user can be on any build.
    private func sessionsTableHasColumn(_ column: String) async -> Bool {
        do {
            let rows = try await backend.query("PRAGMA table_info(sessions)", params: [])
            return rows.contains { $0.optionalString(at: 1) == column }
        } catch {
            return false
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
            sql = "SELECT id FROM \(sessionListFrom) WHERE \(sessionListPredicate) AND started_at > ? ORDER BY started_at DESC LIMIT 1"
            params = [.real(after.timeIntervalSince1970)]
        } else {
            sql = "SELECT id FROM \(sessionListFrom) WHERE \(sessionListPredicate) ORDER BY started_at DESC LIMIT 1"
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
    /// One row of the Dashboard's per-model usage breakdown (Hermes
    /// v0.20+, aggregated across sessions from `session_model_usage`).
    /// Empty on pre-0.20 DBs — the table doesn't exist there and the
    /// snapshot batch never issues the query.
    public struct ModelUsageStat: Sendable, Identifiable, Equatable {
        public let model: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let reasoningTokens: Int
        public let estimatedCostUSD: Double
        public let actualCostUSD: Double
        public let apiCallCount: Int

        public var id: String { model }
        public var totalTokens: Int { inputTokens + outputTokens + reasoningTokens }
        /// Actual cost when Hermes recorded one, else the estimate —
        /// same preference order as `HermesSession.displayCostUSD`.
        public var displayCostUSD: Double { actualCostUSD > 0 ? actualCostUSD : estimatedCostUSD }

        public init(
            model: String,
            inputTokens: Int,
            outputTokens: Int,
            reasoningTokens: Int,
            estimatedCostUSD: Double,
            actualCostUSD: Double,
            apiCallCount: Int
        ) {
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.estimatedCostUSD = estimatedCostUSD
            self.actualCostUSD = actualCostUSD
            self.apiCallCount = apiCallCount
        }
    }

    /// Aggregate SQL for the per-model breakdown. One GROUP BY over
    /// `session_model_usage` — rides inside the existing snapshot
    /// batch, so it adds zero extra round-trips on remote backends.
    private static let modelUsageSQL = """
        SELECT model, COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
               COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(estimated_cost_usd),0),
               COALESCE(SUM(actual_cost_usd),0), COALESCE(SUM(api_call_count),0)
        FROM session_model_usage
        GROUP BY model
        ORDER BY MAX(COALESCE(SUM(actual_cost_usd),0), COALESCE(SUM(estimated_cost_usd),0)) DESC
        """

    private func modelUsageFromRow(_ row: Row) -> ModelUsageStat {
        ModelUsageStat(
            model: row.string(at: 0),
            inputTokens: row.int(at: 1),
            outputTokens: row.int(at: 2),
            reasoningTokens: row.int(at: 3),
            estimatedCostUSD: row.double(at: 4),
            actualCostUSD: row.double(at: 5),
            apiCallCount: row.int(at: 6)
        )
    }

    public struct DashboardSnapshot: Sendable {
        public let stats: SessionStats
        public let recentSessions: [HermesSession]
        public let sessionPreviews: [String: String]
        public let recentToolCalls: [HermesMessage]
        /// Per-model token/cost breakdown (v0.20+). Empty when the
        /// `session_model_usage` table is absent.
        public let modelUsage: [ModelUsageStat]
    }

    public func dashboardSnapshot(
        sessionLimit: Int = 5,
        previewLimit: Int = 5,
        toolCallLimit: Int = 8
    ) async -> DashboardSnapshot {
        var statements: [(sql: String, params: [SQLValue])] = [
            (statsSQL(), []),
            (
                "SELECT \(sessionColumns) FROM \(sessionListFrom) WHERE \(sessionListPredicate) ORDER BY started_at DESC LIMIT ?",
                [.integer(Int64(sessionLimit))]
            ),
            (
                """
                SELECT m.session_id, \(SessionPreviewSQL.rawSelect())
                FROM messages m
                INNER JOIN (
                \(sessionPreviewFirstRowSQL)
                ) first ON m.id = first.min_id
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
        // v0.20: per-model usage rides in the SAME batch (index 4) when
        // the table exists — no extra round-trip. Pre-0.20 DBs never
        // see the query, so the batch shape is byte-identical to today.
        if hasSessionModelUsageTable {
            statements.append((Self.modelUsageSQL, []))
        }
        do {
            let resultSets = try await backend.queryBatch(statements)
            let stats = resultSets.first?.first.map { statsFromRow($0) } ?? .empty
            let sessions = (resultSets.count > 1 ? resultSets[1] : []).map { sessionFromRow($0) }
            var previews: [String: String] = [:]
            for row in (resultSets.count > 2 ? resultSets[2] : []) {
                previews[row.string(at: 0)] = SessionPreviewSQL.shape(row.string(at: 1))
            }
            let toolCalls = (resultSets.count > 3 ? resultSets[3] : []).map { messageFromRow($0) }
            let modelUsage = (resultSets.count > 4 ? resultSets[4] : []).map { modelUsageFromRow($0) }
            return DashboardSnapshot(
                stats: stats,
                recentSessions: sessions,
                sessionPreviews: previews,
                recentToolCalls: toolCalls,
                modelUsage: modelUsage
            )
        } catch {
            Self.logger.warning("dashboardSnapshot failed: \(error.localizedDescription, privacy: .public)")
            return DashboardSnapshot(
                stats: .empty,
                recentSessions: [],
                sessionPreviews: [:],
                recentToolCalls: [],
                modelUsage: []
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
                "SELECT \(sessionListColumns) FROM \(sessionListFrom) WHERE \(sessionListPredicate) ORDER BY started_at DESC LIMIT ?",
                [.integer(Int64(limit))]
            ),
            (
                """
                SELECT m.session_id, \(SessionPreviewSQL.rawSelect())
                FROM messages m
                INNER JOIN (
                \(sessionPreviewFirstRowSQL)
                ) first ON m.id = first.min_id
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
                previews[row.string(at: 0)] = SessionPreviewSQL.shape(row.string(at: 1))
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
        // v0.16 `rewind_count` is appended LAST in sessionColumns, so its
        // positional index shifts with the v0.7 (+4 cols) and v0.11 (+1
        // col) blocks. Resolve the position by column name via the
        // backend-populated `Row.columnIndex` map rather than hardcoding a
        // conditional offset, then read it with the usual positional
        // accessor. `int(at:)` is bounds-safe and yields 0 if the lookup
        // somehow misses.
        let rewindCount: Int = {
            guard hasRewindCountColumn,
                  let idx = row.columnIndex["rewind_count"] else { return 0 }
            return row.int(at: idx)
        }()
        // v0.20 session-activity columns — appended last in
        // sessionColumns, resolved by column NAME (same rationale as
        // rewind_count above). All read defensively: absent columns
        // yield the pre-0.20 defaults.
        let pinned: Bool = {
            guard hasSessionActivityColumns,
                  let idx = row.columnIndex["pinned"] else { return false }
            return row.int(at: idx) != 0
        }()
        let lastActivityAt: Date? = {
            guard hasSessionActivityColumns,
                  let idx = row.columnIndex["last_activity_at"] else { return nil }
            return row.date(at: idx)
        }()
        let lastActivityDescription: String? = {
            guard hasSessionActivityColumns,
                  let idx = row.columnIndex["last_activity_description"] else { return nil }
            return row.optionalString(at: idx)
        }()
        // v0.20.4 read watermark — same by-NAME resolution. NULL stays
        // nil, which `HermesSession.isUnread` reads as "never tracked =
        // read" (Hermes's `session_unread`, hermes_state.py:8455-8466).
        let lastReadAt: Date? = {
            guard hasLastReadAtColumn,
                  let idx = row.columnIndex["last_read_at"] else { return nil }
            return row.date(at: idx)
        }()
        // Hermes's `_sql_session_last_active`, selected as `last_active`
        // by the LIST queries only (`sessionListColumns`). Absent on the
        // single-session / subagent / analytics shapes — `isUnread` then
        // falls back to the reduced `lastActivityAt ?? startedAt`.
        let lastActive: Date? = {
            guard let idx = row.columnIndex["last_active"] else { return nil }
            return row.date(at: idx)
        }()
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
            rewindCount: rewindCount,
            pinned: pinned,
            lastActivityAt: lastActivityAt,
            lastActivityDescription: lastActivityDescription,
            lastReadAt: lastReadAt,
            lastActive: lastActive
        )
    }

    private func messageFromRow(_ row: Row) -> HermesMessage {
        let toolCallsJSON = row.optionalString(at: 5)
        let toolCalls = parseToolCalls(toolCallsJSON)
        // reasoning lives at index 10 (v0.7+); reasoning_content at 11
        // when v0.11 schema is present. Both columns can carry text
        // simultaneously — UI prefers `reasoningContent`.
        let reasoningContent: String? = hasV011Schema ? row.optionalString(at: 11) : nil
        // Read the cheap availability flag by NAME (order-safe, independent of
        // the schema-conditional column positions): the light/skeleton SELECTs
        // carry `hasReasoningContent` as 0/1; the full SELECT omits it, so fall
        // back to the loaded blob being non-empty. Drives `hasReasoning` so the
        // disclosure shows on resume for reasoning_content-only rows (t-aud27).
        let reasoningContentAvailable: Bool = {
            if case .integer(let n) = row["hasReasoningContent"] { return n != 0 }
            return reasoningContent?.isEmpty == false
        }()
        let content = row.string(at: 3)
        // Hermes persists compaction summaries as ORDINARY active message
        // rows (hermes_state.py archive_and_compact) — no schema flag —
        // so hydration classifies by the handoff markers the compressor
        // embeds in the content itself. This is what drives the
        // collapsed-summary / badge styling for DB-loaded history; the
        // ACP replay path deliberately stays fully suppressed
        // pre-engagement (DB history is authoritative). Rows written by
        // hosts predating the markers simply never match.
        let summaryFlags = HermesMessage.classifyCompactionSummary(content: content)
        return HermesMessage(
            id: row.int(at: 0),
            sessionId: row.string(at: 1),
            role: row.string(at: 2),
            content: content,
            toolCallId: row.optionalString(at: 4),
            toolCalls: toolCalls,
            toolName: row.optionalString(at: 6),
            timestamp: row.date(at: 7),
            tokenCount: row.optionalInt(at: 8),
            finishReason: row.optionalString(at: 9),
            reasoning: hasV07Schema ? row.optionalString(at: 10) : nil,
            reasoningContent: reasoningContent,
            reasoningContentAvailable: reasoningContentAvailable,
            isCompactionSummary: summaryFlags.isSummary,
            containsCompactionSummary: summaryFlags.containsSummary
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
