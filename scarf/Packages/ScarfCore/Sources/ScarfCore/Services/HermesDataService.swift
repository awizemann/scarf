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
    private var hasArchivedColumn = false
    private var hasDisplayKindColumn = false

    /// Cached `state_meta.fts_tool_full_content_high_water`, read once
    /// per open on the first search that needs it. `.some(nil)` means
    /// "probed, and this host does not bound tool indexing"; `nil` means
    /// "not probed yet". The value is immutable for the life of a DB —
    /// Hermes stamps it once and returns early ever after
    /// (`hermes_state_schema.py:292-295`) — so caching it is sound, and
    /// `open()`/`refresh()` clear it anyway. The v0.21.4 aligned-layout
    /// probe folded into it changes only at a Hermes open's one-time
    /// realign, which the next `refresh()` picks up.
    private var ftsToolPrefixHighWaterProbe: Int??

    /// Last error from `open()` / `refresh()`, user-presentable. `nil`
    /// means the last attempt succeeded. Views surface this when their
    /// own load path fails, so the user sees "Permission denied
    /// reading state.db" instead of an empty Dashboard with no
    /// explanation. A remote host without `sqlite3` gets `humanize`'s
    /// install hint rather than the raw `/bin/sh: 2: sqlite3: not found`
    /// (gh#141); see `adoptOpenError`.
    public private(set) var lastOpenError: String?

    /// What kind of failure `lastOpenError` describes, so a view can
    /// title its banner accurately instead of calling every failure a
    /// connection issue. `nil` when the last open succeeded.
    public private(set) var lastOpenErrorKind: OpenErrorKind?

    /// Coarse classes of `open()` failure (see `adoptOpenError`).
    public enum OpenErrorKind: Sendable, Equatable {
        /// The remote host has no `sqlite3` binary on PATH.
        case sqlite3Missing
        /// Anything else — SSH, permissions, a missing state.db.
        case other
    }

    /// A query that failed AFTER a good `open()`, carrying `humanize`'s
    /// one-line text. Thrown by the `…Checked` fetches so a view can tell
    /// "the query failed" from "the query found nothing" — the non-checked
    /// forms collapse both into `[]`, which rendered a failed search as
    /// "No matches" and a failed session list as "No sessions yet".
    public struct QueryFailure: LocalizedError, Sendable, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

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
        hasArchivedColumn = await backend.hasArchivedColumn
        hasDisplayKindColumn = await backend.hasDisplayKindColumn
        ftsToolPrefixHighWaterProbe = nil
        adoptOpenError(await backend.lastOpenError)
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
        hasArchivedColumn = await backend.hasArchivedColumn
        hasDisplayKindColumn = await backend.hasDisplayKindColumn
        ftsToolPrefixHighWaterProbe = nil
        adoptOpenError(await backend.lastOpenError)
        return ok
    }

    public func close() async {
        await backend.close()
    }

    /// Publish the backend's open error. The remote preflight's first
    /// command is `sqlite3 --version`, so a host without the CLI fails
    /// open() with the shell's raw "not found" line (gh#141: dash prints
    /// `/bin/sh: 2: sqlite3: not found`). That one case is rewritten with
    /// `humanize`'s install hint and tagged so the banner can say what is
    /// actually wrong.
    ///
    /// Deliberately NOT the whole `humanize` ladder: open() failures also
    /// carry SSH-layer text (`Permission denied (publickey)`, an identity
    /// file's `No such file or directory`), which the permission and
    /// not-found rungs would mislabel as Hermes-state problems. Those keep
    /// their raw text, as before.
    private func adoptOpenError(_ raw: String?) {
        guard let raw else {
            lastOpenError = nil
            lastOpenErrorKind = nil
            return
        }
        if context.isRemote && Self.mentionsMissingSQLite3(raw) {
            lastOpenError = sqlite3MissingMessage()
            lastOpenErrorKind = .sqlite3Missing
        } else {
            lastOpenError = raw
            lastOpenErrorKind = .other
        }
    }

    /// The shells' "no such command" wordings: bash
    /// (`sqlite3: command not found`), dash/busybox (`sqlite3: not found`),
    /// zsh (`command not found: sqlite3`).
    private nonisolated static func mentionsMissingSQLite3(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("sqlite3: command not found")
            || lower.contains("sqlite3: not found")
            || lower.contains("command not found: sqlite3")
    }

    /// Localized through the app's catalogue (`String(localized:)` resolves
    /// against the main bundle, like the other ScarfCore sentences). The key
    /// is hand-maintained in `Localizable.xcstrings`: this package has no
    /// catalogue of its own, so extraction never sees it.
    private nonisolated func sqlite3MissingMessage() -> String {
        let host = context.displayName
        return String(localized: "sqlite3 is not installed on \(host). Install it with `apt install sqlite3` (Ubuntu/Debian) or `yum install sqlite` (RHEL/Fedora).")
    }

    /// Turn a transport / backend error into the one-line string Dashboard
    /// shows. Adds hints for the common "sqlite3 not installed" and
    /// "permission denied" cases so users know what to do. Mirrors the
    /// pre-v2.7 humanise behaviour exactly so existing UI banners
    /// continue to render with the same copy.
    private nonisolated func humanize(_ error: Error) -> String {
        let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = desc.lowercased()
        if Self.mentionsMissingSQLite3(desc) {
            return sqlite3MissingMessage()
        }
        if lower.contains("permission denied") {
            return "Permission denied reading Hermes state on \(context.displayName). The SSH user may not have read access to ~/.hermes/state.db — try Run Diagnostics."
        }
        if lower.contains("no such file") || lower.contains("unable to open database file") {
            return "Hermes state not found at ~/.hermes on \(context.displayName). If Hermes is installed elsewhere, set its data directory in Manage Servers."
        }
        return desc
    }

    /// Wrap a failed query for the `…Checked` fetches. `BackendError` is
    /// not a `LocalizedError`, so `humanize` alone would render sqlite3's
    /// actual complaint as "The operation couldn't be completed"; lift the
    /// carried text out first, then run it through the same hint ladder.
    private nonisolated func queryFailure(_ error: Error) -> QueryFailure {
        let raw: String
        switch error as? BackendError {
        case .sqlite(let exitCode, let stderr)?:
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            raw = text.isEmpty ? String(localized: "sqlite3 exited \(exitCode) with no output") : text
        case .transport(let reason)?:
            raw = reason
        case .notOpen?:
            raw = String(localized: "The Hermes state database is not open.")
        case .parseFailure?:
            raw = String(localized: "Couldn't parse sqlite3's output.")
        case nil:
            return QueryFailure(message: humanize(error))
        }
        return QueryFailure(message: humanize(QueryFailure(message: raw)))
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
    ///
    /// The last two clauses are the rest of Hermes's default listing
    /// filter (`_session_filter_where`, hermes_state_sessions.py:103-127
    /// @ v2026.9.24):
    /// - `_delegate_from IS NULL` — a delegate subagent whose parent was
    ///   deleted is left as a parentless row that Hermes tags
    ///   `_delegate_from = '__orphaned__'` (schema migration v16,
    ///   hermes_state_schema.py:1011-1027) so it stays out of listings.
    ///   Rides with the listable-child predicate, which already proved
    ///   `model_config` and JSON1 exist. Written with Hermes's
    ///   `json_valid` guard (`_sql_json_extract`,
    ///   hermes_state_common.py:67-74) so one malformed `model_config`
    ///   cannot fail the whole list.
    /// - `archived = 0` — sessions the user soft-hid with
    ///   `hermes sessions archive` or the Hermes dashboards. Gated on the
    ///   column existing (v0.16+); older hosts emit the same SQL as before.
    private var sessionListPredicate: String {
        var clauses: [String] = []
        if hasListableChildSupport {
            let branch = """
                \(Self.jsonMarker("s.model_config", "$._branched_from")) IS NOT NULL \
                OR EXISTS (SELECT 1 FROM sessions p WHERE p.id = s.parent_session_id \
                AND p.end_reason = 'branched' AND s.started_at >= p.ended_at)
                """
            clauses.append("(s.parent_session_id IS NULL OR \(branch) OR \(Self.resetChildSQL))")
            clauses.append("\(Self.jsonMarker("s.model_config", "$._delegate_from")) IS NULL")
        } else {
            clauses.append("parent_session_id IS NULL")
        }
        if hasArchivedColumn {
            clauses.append(hasListableChildSupport ? "s.archived = 0" : "archived = 0")
        }
        if hasHiddenColumn {
            clauses.append(hasListableChildSupport ? "s.hidden = 0" : "hidden = 0")
        }
        return clauses.joined(separator: " AND ")
    }

    /// Hermes's non-throwing JSON marker lookup (`_sql_json_extract`,
    /// hermes_state_common.py:67-74 @ v2026.9.24): `json_extract` over the
    /// column when it holds valid JSON, over an empty object otherwise.
    private static func jsonMarker(_ column: String, _ path: String) -> String {
        "json_extract(CASE WHEN json_valid(\(column)) THEN \(column) ELSE json_object() END, '\(path)')"
    }

    /// Hermes's `_RESET_CHILD_SQL` (hermes_state_common.py:139-143)
    /// against the outer alias `s`: the durable `_reset_from` marker,
    /// or the pre-marker heuristic — a child riding its parent's exact
    /// non-empty routing key where the parent ended at a reset
    /// boundary. `_RESET_END_REASONS` is copied verbatim from :100-113.
    private static let resetChildSQL = resetChildSQL(alias: "s")

    /// `resetChildSQL` against any outer alias — the compression-chain
    /// walk needs it against `child` (`_CHAIN_STEP_SQL`,
    /// hermes_state_compression.py:29-49 @ v2026.9.24).
    private static func resetChildSQL(alias a: String) -> String {
        """
        \(jsonMarker("\(a).model_config", "$._reset_from")) IS NOT NULL \
        OR EXISTS (SELECT 1 FROM sessions p WHERE p.id = \(a).parent_session_id \
        AND p.end_reason IN ('session_reset', 'session_switch', 'idle', 'daily', 'suspended', 'resume_pending_expired') \
        AND \(a).session_key IS NOT NULL AND \(a).session_key != '' AND \(a).session_key = p.session_key)
        """
    }

    /// Hermes's `_ephemeral_child_sql` (hermes_state_common.py:178-190)
    /// for the children of one parent: subagent runs only — not branch,
    /// reset, or compression continuations. Used by
    /// `fetchSubagentSessions` so a post-reset conversation isn't
    /// rendered as a subagent run of the session it continued.
    private var subagentChildPredicate: String {
        guard hasListableChildSupport else { return "parent_session_id = ?" }
        let branch = """
            \(Self.jsonMarker("s.model_config", "$._branched_from")) IS NOT NULL \
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
        (try? await fetchSessionsChecked(limit: limit)) ?? []
    }

    /// `fetchSessions` that reports a failed query as `QueryFailure`
    /// instead of an empty list. Same SQL.
    public func fetchSessionsChecked(limit: Int = QueryDefaults.sessionLimit) async throws -> [HermesSession] {
        let sql = "SELECT \(sessionListColumns) FROM \(sessionListFrom) WHERE \(sessionListPredicate) ORDER BY started_at DESC LIMIT ?"
        do {
            let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
            let listed = rows.map { sessionFromRow($0) }
            return await projectCompressionTips(listed, columns: sessionListColumns).sessions
        } catch {
            Self.logger.warning("fetchSessions failed: \(error.localizedDescription, privacy: .public)")
            throw queryFailure(error)
        }
    }

    /// Every listable session started at or after `since`, newest first,
    /// capped at `limit` rows.
    ///
    /// The cap is not cosmetic: Insights' "All Time" period passes epoch
    /// zero, so on a long-lived store this SELECT materialised the entire
    /// `sessions` table — 20+ columns per row — into one wire payload and
    /// one array. `QueryDefaults.periodSessionLimit` bounds it to the most
    /// recent window; the aggregates it feeds are then honestly "over the
    /// most recent N sessions in the period" rather than an unbounded
    /// query that times out on the hosts that need it most.
    public func fetchSessionsInPeriod(
        since: Date,
        limit: Int = QueryDefaults.periodSessionLimit
    ) async -> [HermesSession] {
        (try? await fetchSessionsInPeriodChecked(since: since, limit: limit)) ?? []
    }

    /// `fetchSessionsInPeriod` that reports a failed query as
    /// `QueryFailure` instead of an empty list. Same SQL.
    public func fetchSessionsInPeriodChecked(
        since: Date,
        limit: Int = QueryDefaults.periodSessionLimit
    ) async throws -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM \(sessionListFrom) WHERE \(sessionListPredicate) AND started_at >= ? ORDER BY started_at DESC LIMIT ?"
        do {
            let rows = try await backend.query(
                sql,
                params: [.real(since.timeIntervalSince1970), .integer(Int64(limit))]
            )
            return rows.map { sessionFromRow($0) }
        } catch {
            Self.logger.warning("fetchSessionsInPeriod failed: \(error.localizedDescription, privacy: .public)")
            throw queryFailure(error)
        }
    }

    // MARK: - Usage population (what `hermes insights` sums)

    /// One group of the usage population's sums: every session row in the
    /// window sharing a model, a source and a cost state. Insights folds
    /// these into its totals and its model / platform breakdowns.
    public struct UsageAggregate: Sendable, Equatable {
        public let model: String?
        public let source: String
        /// The group's `cost_status` (nil on a host without the column).
        public let costStatus: String?
        /// Whether the host's `sessions` table has `cost_status` — the same
        /// probe `HermesSession.hasCostStatusColumn` records.
        public let hasCostStatusColumn: Bool
        /// Whether the group's rows carry a positive usable cost (the
        /// first branch of `SessionCostDisplay`'s rule).
        public let hasPositiveCost: Bool
        public let sessions: Int
        public let messages: Int
        public let toolCalls: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let reasoningTokens: Int
        /// Sum of `actual_cost_usd ?? estimated_cost_usd` per row — the same
        /// preference order as `HermesSession.displayCostUSD`.
        public let costUSD: Double

        public init(
            model: String?, source: String, costStatus: String?,
            hasCostStatusColumn: Bool, hasPositiveCost: Bool, sessions: Int,
            messages: Int, toolCalls: Int, inputTokens: Int, outputTokens: Int,
            cacheReadTokens: Int, cacheWriteTokens: Int, reasoningTokens: Int,
            costUSD: Double
        ) {
            self.model = model
            self.source = source
            self.costStatus = costStatus
            self.hasCostStatusColumn = hasCostStatusColumn
            self.hasPositiveCost = hasPositiveCost
            self.sessions = sessions
            self.messages = messages
            self.toolCalls = toolCalls
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.costUSD = costUSD
        }

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
        }

        /// How many of this group's sessions Hermes never priced. The ONE
        /// cost rule (`SessionCostDisplay`) decides; every row in a group
        /// shares the inputs it reads, so the answer is all or none.
        public var unknownCostSessions: Int {
            let display = SessionCostDisplay(
                actualCostUSD: hasPositiveCost ? 1 : nil,
                estimatedCostUSD: nil,
                costStatus: costStatus,
                hasCostStatusColumn: hasCostStatusColumn
            )
            return display.isUnknown ? sessions : 0
        }
    }

    /// The usage population's sums for every session row started at or
    /// after `since`, aggregated IN SQL and uncapped.
    ///
    /// `hermes insights` sums every row in the window with no listing
    /// filter and no row cap (`InsightsEngine._GET_SESSIONS_ALL`,
    /// agent/insights.py:92-96 @ v2026.9.24): delegate subagents (their own
    /// session rows, `tools/delegate_tool.py:246,277`), rotated compression
    /// continuations, hidden and archived rows all carry real tokens and
    /// cost. This used to fetch the rows themselves, capped at
    /// `QueryDefaults.periodSessionLimit` (2000) to bound the wire payload,
    /// so a busy host's "All Time" spend silently stopped at its newest
    /// 2000 rows — sooner for anyone whose agent delegates. A GROUP BY
    /// returns a handful of rows however large the window is.
    ///
    /// Counters come from `usageSessionsSource`, so on a v0.20+ host they
    /// include the auxiliary usage Hermes records only per model.
    public func fetchUsageAggregatesInPeriod(since: Date) async -> [UsageAggregate] {
        (try? await fetchUsageAggregatesInPeriodChecked(since: since)) ?? []
    }

    /// `fetchUsageAggregatesInPeriod` that reports a failed query as
    /// `QueryFailure` instead of an empty result. Same SQL.
    public func fetchUsageAggregatesInPeriodChecked(since: Date) async throws -> [UsageAggregate] {
        let hasStatus = hasV07Schema
        // `SessionCostDisplay.usableAmount`: finite and non-negative, and
        // the actual figure wins over the estimate when it is usable.
        // SQLite has no NaN; 9e999 is its infinity.
        func usable(_ column: String) -> String {
            "(\(column) IS NOT NULL AND \(column) >= 0 AND \(column) < 9e999)"
        }
        let positive = hasStatus
            ? "CASE WHEN \(usable("actual_cost_usd")) THEN actual_cost_usd > 0 ELSE (\(usable("estimated_cost_usd")) AND estimated_cost_usd > 0) END"
            : "(\(usable("estimated_cost_usd")) AND estimated_cost_usd > 0)"
        let status = hasStatus ? "cost_status" : "NULL"
        let cost = hasStatus ? "COALESCE(actual_cost_usd, estimated_cost_usd)" : "estimated_cost_usd"
        let reasoning = hasStatus ? "COALESCE(SUM(reasoning_tokens),0)" : "0"
        let sql = """
            SELECT model, COALESCE(source, ''), \(status) AS cost_state, (\(positive)) AS has_positive,
                   COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                   COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_write_tokens),0),
                   \(reasoning), COALESCE(SUM(\(cost)),0)
            FROM \(usageSessionsSource)
            WHERE started_at >= ?
            GROUP BY model, COALESCE(source, ''), cost_state, has_positive
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            return rows.map { row in
                UsageAggregate(
                    model: row.optionalString(at: 0),
                    source: row.string(at: 1),
                    costStatus: row.optionalString(at: 2),
                    hasCostStatusColumn: hasStatus,
                    hasPositiveCost: row.int(at: 3) != 0,
                    sessions: row.int(at: 4),
                    messages: row.int(at: 5),
                    toolCalls: row.int(at: 6),
                    inputTokens: row.int(at: 7),
                    outputTokens: row.int(at: 8),
                    cacheReadTokens: row.int(at: 9),
                    cacheWriteTokens: row.int(at: 10),
                    reasoningTokens: row.int(at: 11),
                    costUSD: row.double(at: 12)
                )
            }
        } catch {
            Self.logger.warning("fetchUsageAggregatesInPeriod failed: \(error.localizedDescription, privacy: .public)")
            throw queryFailure(error)
        }
    }

    /// Counter columns whose totals Hermes reconciles against
    /// `session_model_usage`.
    private static let usageReconciledColumns: Set<String> = [
        "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
        "reasoning_tokens", "estimated_cost_usd", "api_call_count"
    ]

    /// `FROM` source for usage sums: `sessions` itself, or — when the
    /// v0.20 `session_model_usage` table exists — a derived table with the
    /// same column names whose token/cost counters are the larger of the
    /// session's own counter and the sum of its per-model rows.
    ///
    /// Why: session counters carry main-loop usage only, while auxiliary
    /// calls (vision, compression, titles) land only in
    /// `session_model_usage`. Hermes's overview totals therefore sum the
    /// per-model rows plus each session's non-negative residual
    /// (`_compute_model_breakdown`, agent/insights.py:346-368, used for the
    /// overview at :271-292), which per session is exactly
    /// `MAX(session counter, SUM(per-model rows))`. A session with no
    /// per-model rows keeps its own values, NULL cost included.
    /// `actual_cost_usd` is not reconciled: Hermes's overview reads it from
    /// the session row (:287).
    private var usageSessionsSource: String {
        guard hasSessionModelUsageTable else { return "sessions" }
        let columns = sessionColumns
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let select = columns.map { column -> String in
            guard Self.usageReconciledColumns.contains(column) else { return "s.\(column)" }
            return "CASE WHEN u.session_id IS NULL THEN s.\(column) ELSE MAX(COALESCE(s.\(column), 0), u.\(column)) END AS \(column)"
        }.joined(separator: ", ")
        let sums = Self.usageReconciledColumns.sorted()
            .map { "SUM(\($0)) AS \($0)" }
            .joined(separator: ", ")
        return """
            (SELECT \(select) FROM sessions s LEFT JOIN (\
            SELECT session_id, \(sums) FROM session_model_usage GROUP BY session_id\
            ) u ON u.session_id = s.id) usage_sessions
            """
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
        await fetchMessagesOutcome(sessionIds: [sessionId], limit: limit, before: before)
    }

    /// `fetchMessagesOutcome` across several sessions — a rotated
    /// compression chain (`HermesSession.lineageIds`), whose turns are
    /// spread over the root and every continuation. Hermes shows such a
    /// conversation as one transcript spanning the whole lineage
    /// (`get_resume_conversations`, hermes_state_messages.py:1273-1293 @
    /// v2026.9.24). Message ids are global and monotonic, so ordering by id
    /// interleaves the segments correctly. One id runs the single-session
    /// SQL unchanged.
    public func fetchMessagesOutcome(
        sessionIds: [String],
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
            let owner = Self.sessionIdPredicate(sessionIds)
            guard !owner.params.isEmpty else { return MessageFetchOutcome(messages: [], transportError: nil) }
            let sql: String
            let params: [SQLValue]
            let activeClause = transcriptVisibleClause
            if let before {
                sql = "SELECT \(messageColumnsLight) FROM messages WHERE \(owner.sql) AND id < ?\(activeClause) ORDER BY id DESC LIMIT ?"
                params = owner.params + [.integer(Int64(before)), .integer(Int64(limit))]
            } else {
                sql = "SELECT \(messageColumnsLight) FROM messages WHERE \(owner.sql)\(activeClause) ORDER BY id DESC LIMIT ?"
                params = owner.params + [.integer(Int64(limit))]
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

    /// `session_id = ?` for one id — the single-session SQL, byte for
    /// byte — or `session_id IN (?, …)` for a compression lineage. Empty
    /// ids are dropped; no ids gives no params (callers return empty).
    static func sessionIdPredicate(_ sessionIds: [String]) -> (sql: String, params: [SQLValue]) {
        var seen = Set<String>()
        let ids = sessionIds.filter { !$0.isEmpty && seen.insert($0).inserted }
        if ids.count == 1 { return ("session_id = ?", [.text(ids[0])]) }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return ("session_id IN (\(placeholders))", ids.map { .text($0) })
    }

    /// The newest `limit` transcript rows across several sessions, oldest
    /// first — see `fetchMessagesOutcome(sessionIds:limit:before:)`.
    public func fetchMessages(sessionIds: [String], limit: Int, before: Int? = nil) async -> [HermesMessage] {
        await fetchMessagesOutcome(sessionIds: sessionIds, limit: limit, before: before).messages
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
        await fetchSkeletonMessages(sessionIds: [sessionId], limit: limit, before: before)
    }

    /// `fetchSkeletonMessages` across a compression lineage (see
    /// `fetchMessagesOutcome(sessionIds:limit:before:)`). One id runs the
    /// single-session SQL unchanged.
    public func fetchSkeletonMessages(
        sessionIds: [String],
        limit: Int,
        before: Int? = nil
    ) async -> MessageFetchOutcome {
        await ScarfMon.measureAsync(.sessionLoad, "mac.fetchSkeletonMessages") {
            let owner = Self.sessionIdPredicate(sessionIds)
            guard !owner.params.isEmpty else { return MessageFetchOutcome(messages: [], transportError: nil) }
            let sql: String
            let params: [SQLValue]
            let activeClause = transcriptVisibleClause
            if let before {
                sql = "SELECT \(messageColumnsSkeleton) FROM messages WHERE \(owner.sql) AND role IN ('user','assistant') AND id < ? \(activeClause) ORDER BY id DESC LIMIT ?"
                params = owner.params + [.integer(Int64(before)), .integer(Int64(limit))]
            } else {
                sql = "SELECT \(messageColumnsSkeleton) FROM messages WHERE \(owner.sql) AND role IN ('user','assistant') \(activeClause) ORDER BY id DESC LIMIT ?"
                params = owner.params + [.integer(Int64(limit))]
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
                            let parsed = Self.parseToolCalls(json)
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
                        let parsed = Self.parseToolCalls(json)
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
                                let parsed = Self.parseToolCalls(json)
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
        await fetchToolResultsInRange(sessionIds: [sessionId], minId: minId, maxId: maxId, limit: limit)
    }

    /// `fetchToolResultsInRange` across a compression lineage. One id runs
    /// the single-session SQL unchanged.
    public func fetchToolResultsInRange(
        sessionIds: [String],
        minId: Int,
        maxId: Int,
        limit: Int = 50
    ) async -> [HermesMessage] {
        await ScarfMon.measureAsync(.sessionLoad, "mac.hydrateToolResults") {
            let owner = Self.sessionIdPredicate(sessionIds)
            guard !owner.params.isEmpty else { return [] }
            let activeClause = transcriptVisibleClause
            let sql = "SELECT \(messageColumnsLight) FROM messages WHERE \(owner.sql) AND role = 'tool' AND id >= ? AND id <= ? \(activeClause) ORDER BY id DESC LIMIT ?"
            let params: [SQLValue] = owner.params + [
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
        let sql = "SELECT \(messageColumns) FROM messages WHERE session_id = ?\(displayVisibleClause()) ORDER BY timestamp ASC"
        do {
            let rows = try await backend.query(sql, params: [.text(sessionId)])
            return rows.map { messageFromRow($0) }
        } catch {
            return []
        }
    }

    public func searchMessages(query: String, limit: Int = QueryDefaults.messageSearchLimit) async -> [HermesMessage] {
        (try? await searchMessagesChecked(query: query, limit: limit)) ?? []
    }

    /// `searchMessages` that reports a failed FTS query as `QueryFailure`
    /// instead of an empty result, so the UI can say "search failed"
    /// rather than "No matches". The deep tool-content top-up stays
    /// best-effort: when it fails, the FTS hits are still returned.
    public func searchMessagesChecked(query: String, limit: Int = QueryDefaults.messageSearchLimit) async throws -> [HermesMessage] {
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
        let activeClause = searchActiveClause(alias: "m.")
        let sql = """
            SELECT \(msgCols)
            FROM messages_fts fts
            JOIN messages m ON m.id = fts.rowid
            WHERE messages_fts MATCH ? \(activeClause)
            ORDER BY rank
            LIMIT ?
            """
        let matches: [HermesMessage]
        do {
            let rows = try await backend.query(sql, params: [.text(sanitized), .integer(Int64(limit))])
            matches = rows.map { messageFromRow($0) }
        } catch {
            Self.logger.warning("searchMessages failed: \(error.localizedDescription, privacy: .public)")
            throw queryFailure(error)
        }

        // v0.21.1 (A10): on a host that bounds tool-row indexing to the
        // first 8 KB of `content`, a term occurring only DEEPER than that
        // is invisible to MATCH — so top up with a bounded scan the FTS
        // pass could not have seen. Everything about this is conditional
        // on the `state_meta` marker being present, so a pre-v0.21.1 DB
        // issues byte-identical SQL to the release before this one, and a
        // full result set skips it regardless (there is no room to add).
        guard matches.count < limit,
              let highWater = await ftsToolPrefixHighWater() else { return matches }
        let extra = await deepToolContentMatches(
            query: query,
            highWater: highWater,
            msgCols: msgCols,
            limit: limit - matches.count
        )
        guard !extra.isEmpty else { return matches }
        let seen = Set(matches.map(\.id))
        return matches + extra.filter { !seen.contains($0.id) }
    }

    /// The message id above which tool rows are prefix-truncated in
    /// `messages_fts`, or nil when this host does not bound tool-row FTS
    /// indexing. Probed at most once per `open()`.
    ///
    /// Two detected layouts, never a version (charter C4):
    /// - `messages_fts` reads the `messages_fts_src` view (v0.21.4+
    ///   aligned layout) ⇒ EVERY tool row is truncated ⇒ `0`. That
    ///   migration also deletes the high-water marker, which the older
    ///   rule below would misread as "nothing truncated".
    /// - otherwise `state_meta.fts_tool_full_content_high_water` exactly
    ///   as before; a DB old enough to lack `state_meta` entirely throws
    ///   and is cached as "no bound", same as a missing key.
    private func ftsToolPrefixHighWater() async -> Int? {
        if let cached = ftsToolPrefixHighWaterProbe { return cached }
        var value: Int?
        if await ftsReadsAlignedProjection() {
            value = 0
        } else {
            do {
                let rows = try await backend.query(
                    "SELECT CAST(value AS INTEGER) AS v FROM state_meta WHERE key = ? LIMIT 1",
                    params: [.text(HermesFTSIndex.toolFullContentHighWaterKey)]
                )
                value = rows.first?.optionalInt(at: 0)
            } catch {
                value = nil
            }
        }
        ftsToolPrefixHighWaterProbe = .some(value)
        return value
    }

    /// True when `messages_fts` is external-content over the
    /// `messages_fts_src` projection view. Same discriminator Hermes uses
    /// for its own realign migration (`_fts_index_is_misaligned_source`:
    /// the vtable's `sqlite_master.sql` naming `messages_fts_src`,
    /// `hermes_state_schema.py:283-293` @ v2026.9.21). Any failure reads
    /// as "not aligned", i.e. the pre-v0.21.4 path.
    private func ftsReadsAlignedProjection() async -> Bool {
        do {
            let rows = try await backend.query(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts' LIMIT 1",
                params: []
            )
            return rows.first?.optionalString(at: 0)?
                .contains(HermesFTSIndex.alignedSourceViewName) == true
        } catch {
            return false
        }
    }

    /// The LIKE half of the v0.21.1 search fallback: tool rows above the
    /// prefix high-water whose payload is longer than the indexed prefix
    /// and which contain every search term somewhere.
    ///
    /// **Why it is bounded by rows READ, not by rows returned.** A plain
    /// `WHERE … LIKE … LIMIT n` lets SQLite scan the whole tool history
    /// looking for the n-th match, and each candidate here is by
    /// definition a >8 KB (often multi-megabyte) payload it must read off
    /// disk. The inner `LIMIT` pins the work to the newest
    /// `fallbackScanBudget` candidates instead, so the cost of a
    /// no-result search is the same as a full-result one and does not
    /// grow with the size of state.db.
    ///
    /// Matching deliberately runs over the WHOLE content rather than
    /// `substr(content, 8193)`: a term straddling the prefix boundary
    /// would fall between the two windows, and rows the FTS pass already
    /// returned are removed by id afterwards anyway.
    /// The "rows a search may return" predicate, optionally alias-qualified
    /// (`"m."` for the FTS join, `""` for a query over bare `messages`).
    /// One definition, so the two search passes cannot drift apart: a
    /// rewound row excluded by one and admitted by the other would make a
    /// hit appear or vanish depending on which pass found it.
    ///
    /// Also drops `display_kind = 'hidden'` rows when that column exists:
    /// Hermes's search never returns model-facing scaffolding the person
    /// never saw (hermes_state_search.py:149-150 @ v2026.9.24).
    private func searchActiveClause(alias: String) -> String {
        let hidden = displayVisibleClause(alias: alias)
        guard hasMessagesActiveColumn else { return hidden }
        return (hasCompactedColumn
            ? " AND (\(alias)active = 1 OR \(alias)compacted = 1)"
            : " AND \(alias)active = 1") + hidden
    }

    /// ` AND COALESCE(<alias>display_kind, '') <> 'hidden'` when
    /// `messages.display_kind` exists (Hermes v0.19.1+), else `""`.
    /// `alias` is a qualifier prefix such as `"m."`, or `""` for bare
    /// `messages`.
    ///
    /// Hermes tags three kinds of row this way — an empty placeholder for
    /// an interrupted assistant reply (agent/conversation_loop.py:309-311),
    /// muted diagnostic replies (agent/session_persistence.py:249-252) and
    /// suppressed async-delegation notices (hermes_state_messages.py:340) —
    /// and none of its own displays paint them
    /// (tui_gateway/session_history.py:211-213). Scarf's transcripts,
    /// search and previews drop them the same way.
    private func displayVisibleClause(alias: String = "") -> String {
        hasDisplayKindColumn ? " AND COALESCE(\(alias)display_kind, '') <> 'hidden'" : ""
    }

    /// Row filter for transcript reads over bare `messages`: the active
    /// set (see the O1 decision in `fetchMessagesOutcome`), minus rows
    /// Hermes hides from every display.
    private var transcriptVisibleClause: String {
        (hasMessagesActiveColumn ? " AND active = 1" : "") + displayVisibleClause()
    }

    private func deepToolContentMatches(
        query: String,
        highWater: Int,
        msgCols: String,
        limit: Int
    ) async -> [HermesMessage] {
        // The SAME terms the FTS pass matched (quotes stripped, empties
        // dropped). Raw tokens kept a typed `"` — `"foo"` became
        // `LIKE '%"foo"%'`, so a quoted search found the FTS hits but never
        // the deep ones past the 8 KB prefix.
        let terms = Array(Self.searchTerms(query).prefix(HermesFTSIndex.fallbackMaxTerms))
        guard !terms.isEmpty else { return [] }

        // The inner query is over bare `messages`, so it needs the SAME
        // clause without the alias — built from the shared helper, not by
        // string surgery on the outer one (which would also rewrite an `m.`
        // that turned up anywhere else in the text).
        let innerActive = searchActiveClause(alias: "")
        let likeClause = terms.map { _ in "m.content LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        let sql = """
            SELECT \(msgCols)
            FROM (
                SELECT * FROM messages
                WHERE role = 'tool' AND id > ? AND length(content) > ?\(innerActive)
                ORDER BY id DESC
                LIMIT ?
            ) m
            WHERE \(likeClause)
            ORDER BY m.id DESC
            LIMIT ?
            """
        var params: [SQLValue] = [
            .integer(Int64(highWater)),
            .integer(Int64(HermesFTSIndex.toolContentPrefixChars)),
            .integer(Int64(HermesFTSIndex.fallbackScanBudget))
        ]
        params.append(contentsOf: terms.map { .text("%\(Self.escapedForLIKE($0))%") })
        params.append(.integer(Int64(limit)))

        return await ScarfMon.measureAsync(.sessionLoad, "mac.searchDeepToolContent") {
            do {
                let rows = try await backend.query(sql, params: params)
                ScarfMon.event(.sessionLoad, "mac.searchDeepToolContent.rows", count: rows.count)
                return rows.map { messageFromRow($0) }
            } catch {
                Self.logger.warning("deep tool-content search failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
    }

    /// Neutralise SQL LIKE's wildcards in a user term. Paired with
    /// `ESCAPE '\'` at the call site — without it, searching for `100%`
    /// or `snake_case` silently matches far more than the user asked for.
    private nonisolated static func escapedForLIKE(_ term: String) -> String {
        var out = ""
        out.reserveCapacity(term.count)
        for ch in term {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// What `messages_fts` can currently answer for. Read fresh (the
    /// rebuild markers move while a backfill runs, and vanish when it
    /// finishes), off the main actor, in one round-trip. A DB with no
    /// `state_meta` reports a healthy index.
    public func searchIndexStatus() async -> HermesSearchIndexStatus {
        var status = HermesSearchIndexStatus(toolPrefixHighWater: await ftsToolPrefixHighWater())
        do {
            let rows = try await backend.query(
                "SELECT key AS k, CAST(value AS INTEGER) AS v FROM state_meta WHERE key IN (?, ?)",
                params: [
                    .text(HermesFTSIndex.rebuildProgressKey),
                    .text(HermesFTSIndex.rebuildHighWaterKey)
                ]
            )
            for row in rows {
                switch row.string(at: 0) {
                case HermesFTSIndex.rebuildProgressKey: status.rebuildProgress = row.optionalInt(at: 1)
                case HermesFTSIndex.rebuildHighWaterKey: status.rebuildHighWater = row.optionalInt(at: 1)
                default: break
                }
            }
        } catch {
            return status
        }
        // Hermes deletes BOTH markers together when the backfill lands
        // (`_CLEAR_REBUILD_MARKERS_SQL`), so presence is the signal. A
        // progress that has caught up with the high-water is a rebuild in
        // its last moments, not a finished one — still honestly partial.
        status.isRebuilding = status.rebuildHighWater != nil || status.rebuildProgress != nil
        return status
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
            hasCompactedColumn: hasCompactedColumn,
            hasDisplayKindColumn: hasDisplayKindColumn
        )
    }

    /// The preview statement for exactly the rows the listing statement
    /// (`sessionListFrom` + `sessionListPredicate`, newest first, `limit`)
    /// returns, so it can ride in the same batch.
    ///
    /// It used to be "the newest `limit` first-user-message rows across
    /// every session", a different population from the rows it labels:
    /// delegate subagents, hidden and archived rows all have user rows, so
    /// a busy delegating agent pushed an untitled listed session out of
    /// the window and its row showed a raw id. Hermes computes the preview
    /// per listed row (`_PREVIEW_RAW_SUBQUERY_SQL`,
    /// hermes_state_common.py:163-165 @ v2026.9.24).
    private func listedSessionPreviewStatement(limit: Int) -> (sql: String, params: [SQLValue]) {
        (
            """
            SELECT m.session_id, \(SessionPreviewSQL.rawSelect())
            FROM messages m
            INNER JOIN (
            \(sessionPreviewFirstRowSQL)
            ) first ON m.id = first.min_id
            WHERE m.session_id IN (
            SELECT id FROM \(sessionListFrom) WHERE \(sessionListPredicate) ORDER BY started_at DESC LIMIT ?
            )
            """,
            [.integer(Int64(limit))]
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

    /// Carrier-aware previews for a KNOWN set of session ids.
    ///
    /// Same machinery as `fetchSessionPreviews`, through
    /// `SessionPreviewSQL.firstEligibleUserRowSQL(sessionIdCount:…)`.
    /// Exists for the surfaces whose rows come from `messages` rather than
    /// from a session list — Activity above all, whose filter labels have
    /// to name the sessions ITS rows belong to. Asking the list form for
    /// "the 50 newest previews" answers a different question and left most
    /// labels as bare UUIDs.
    ///
    /// Returns `[:]` for an empty id set without touching the backend.
    public func fetchSessionPreviews(sessionIds: [String]) async -> [String: String] {
        let ids = Array(Set(sessionIds)).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [:] }
        let sql = """
            SELECT m.session_id, \(SessionPreviewSQL.rawSelect())
            FROM messages m
            INNER JOIN (
            \(SessionPreviewSQL.firstEligibleUserRowSQL(
                sessionIdCount: ids.count,
                hasActiveColumn: hasMessagesActiveColumn,
                hasCompactedColumn: hasCompactedColumn,
                hasDisplayKindColumn: hasDisplayKindColumn
            ))
            ) first ON m.id = first.min_id
            """
        do {
            let rows = try await backend.query(sql, params: ids.map { .text($0) })
            var previews: [String: String] = [:]
            for row in rows {
                let shaped = SessionPreviewSQL.shape(row.string(at: 1))
                if !shaped.isEmpty { previews[row.string(at: 0)] = shaped }
            }
            return previews
        } catch {
            Self.logger.warning("fetchSessionPreviews(sessionIds:) failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// The carrier-aware preview of ONE session.
    ///
    /// Same machinery as `fetchSessionPreviews`, through
    /// `SessionPreviewSQL.firstEligibleUserRowSQL(sessionScoped:…)` — carrier
    /// stripping, the schema-gated active-row clause and the pre-filter are
    /// the shared expressions, not a re-derivation. Exists because the Bots
    /// roster asks for one bot's preview at a time: running the list
    /// aggregate per bot would `GROUP BY` the whole `messages` table N times
    /// and discard all but one row of each result.
    ///
    /// Returns `nil` when the session has no eligible user message (a brand
    /// new chat, or one whose only user rows are pure compaction carriers) and
    /// on any query failure — a roster line is not worth an error banner.
    public func fetchSessionPreview(sessionId: String) async -> String? {
        let sql = """
            SELECT m.session_id, \(SessionPreviewSQL.rawSelect())
            FROM messages m
            INNER JOIN (
            \(SessionPreviewSQL.firstEligibleUserRowSQL(
                sessionScoped: true,
                hasActiveColumn: hasMessagesActiveColumn,
                hasCompactedColumn: hasCompactedColumn,
                hasDisplayKindColumn: hasDisplayKindColumn
            ))
            ) first ON m.id = first.min_id
            LIMIT 1
            """
        do {
            let rows = try await backend.query(sql, params: [.text(sessionId)])
            guard let row = rows.first else { return nil }
            let shaped = SessionPreviewSQL.shape(row.string(at: 1))
            return shaped.isEmpty ? nil : shaped
        } catch {
            Self.logger.warning("fetchSessionPreview failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// When a session last moved. `nil` for a session with no messages.
    public func fetchLastMessageDate(sessionId: String) async -> Date? {
        do {
            let rows = try await backend.query(
                "SELECT MAX(timestamp) FROM messages WHERE session_id = ?",
                params: [.text(sessionId)]
            )
            guard let row = rows.first, let value = row.optionalDouble(at: 0), value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        } catch {
            return nil
        }
    }

    /// The roster's activity line for the bot this service is pinned to.
    ///
    /// The service MUST be built from `ServerContext.pinnedToProfile(_:)` —
    /// every bot profile carries its own `state.db`, migrated independently,
    /// which is why `open()` (and its per-database schema probe) has to run
    /// per profile rather than once for the host.
    ///
    /// Returns `nil` when the profile has no canonical Bot Chat. That is the
    /// resting state of a bot nobody has messaged, and of a database whose
    /// schema is too old to answer — neither is an error, and neither may
    /// produce a fabricated preview.
    ///
    /// The two halves are read from the two ends of the compression chain on
    /// purpose: **activity** comes from the live tip (where new turns land),
    /// **preview** from the registry row (which holds the conversation's first
    /// message — on a compressed chat the tip's earliest rows are carriers or
    /// mid-conversation turns, and would read as a preview of nothing).
    public func fetchBotChatActivity() async -> BotActivity? {
        guard let canonical = await locateCanonicalBotChat() else { return nil }
        let lastMessageAt = await fetchLastMessageDate(sessionId: canonical.liveId)
        let preview = await fetchSessionPreview(sessionId: canonical.registryId)
        return BotActivity(lastMessageAt: lastMessageAt, preview: preview ?? "")
    }

    // MARK: - Single-Row Queries

    public struct MessageFingerprint: Equatable, Sendable {
        let count: Int
        let maxId: Int
        let maxTimestamp: Double

        static let empty = MessageFingerprint(count: 0, maxId: 0, maxTimestamp: 0)
    }

    public func fetchMessageFingerprint(sessionId: String) async -> MessageFingerprint {
        await fetchMessageFingerprint(sessionIds: [sessionId])
    }

    /// `fetchMessageFingerprint` across a compression lineage.
    public func fetchMessageFingerprint(sessionIds: [String]) async -> MessageFingerprint {
        let owner = Self.sessionIdPredicate(sessionIds)
        guard !owner.params.isEmpty else { return .empty }
        let sql = "SELECT COUNT(*), COALESCE(MAX(id), 0), COALESCE(MAX(timestamp), 0) FROM messages WHERE \(owner.sql)"
        do {
            let rows = try await backend.query(sql, params: owner.params)
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

    public func fetchSession(id: String) async -> HermesSession? {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE id = ? LIMIT 1"
        do {
            let rows = try await backend.query(sql, params: [.text(id)])
            return rows.first.map { sessionFromRow($0) }
        } catch {
            return nil
        }
    }

    /// A session opened by id from outside the list (a search hit), as
    /// the detail view should show it.
    public struct SessionDetailLookup: Sendable {
        /// The row to show: the hit's own session, or — when the hit lies
        /// in a rotated compression chain — the chain projected onto its
        /// tip with the whole lineage, as the list would show it.
        public let session: HermesSession
        /// `archived = 1` on the conversation's row (v0.16+ hosts).
        public let isArchived: Bool
        /// Whether the session list's predicate admits the conversation
        /// (false for archived, hidden, and delegate-subagent rows).
        public let isListed: Bool
    }

    /// Resolve a session by id for display, whether or not the session
    /// list shows it (R14-1). Search covers every row — Scarf does not
    /// drop archived rows the way `hermes sessions search` does by default
    /// (hermes_state_search.py:137-162 @ v2026.9.24) — so a hit can land on
    /// an archived session, an orphaned or live delegate subagent, a
    /// middle segment of a compression chain, or a conversation older than
    /// the loaded list. Clicking such a hit used to do nothing.
    ///
    /// A hit in a compression chain resolves to the whole chain: parents
    /// are followed while they ended by compression (bounded, cycle-safe,
    /// like `acp_adapter/provenance.py`), then the chain is walked to its
    /// tip with the list's own step query. Nil when the id is not in
    /// state.db.
    public func fetchSessionForDetail(id: String) async -> SessionDetailLookup? {
        guard let hit = await fetchSession(id: id) else { return nil }
        // Walk up to the conversation's root through compression parents.
        var root = hit
        var seen: Set<String> = [hit.id]
        for _ in 0..<100 {
            guard let parentId = root.parentSessionId, !parentId.isEmpty, !seen.contains(parentId),
                  let parent = await fetchSession(id: parentId),
                  parent.endReason == "compression" else { break }
            seen.insert(parentId)
            root = parent
        }
        var shown = hit
        if hasListableChildSupport, root.endReason == "compression",
           let chain = try? await compressionChains(for: [root.id])[root.id],
           let tipId = chain.last,
           let tip = await fetchSession(id: tipId) {
            SessionLineageIndex.shared.record(server: context.id, lineage: chain)
            shown = root.projectedOntoCompressionTip(tip, lineage: chain)
        }
        let idColumn = hasListableChildSupport ? "s.id" : "id"
        var isListed = false
        if let rows = try? await backend.query(
            "SELECT COUNT(*) FROM \(sessionListFrom) WHERE \(sessionListPredicate) AND \(idColumn) = ?",
            params: [.text(root.id)]
        ) {
            isListed = (rows.first?.int(at: 0) ?? 0) > 0
        }
        var isArchived = false
        if hasArchivedColumn,
           let rows = try? await backend.query("SELECT archived FROM sessions WHERE id = ?", params: [.text(root.id)]) {
            isArchived = (rows.first?.int(at: 0) ?? 0) != 0
        }
        return SessionDetailLookup(session: shown, isArchived: isArchived, isListed: isListed)
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

        /// The `sessions.source` of the LIVE tip — `"cli"`, `"acp"`,
        /// `"gateway"`, … — read at resolve time because it decides the
        /// transport. Hermes' ACP adapter refuses to restore any session
        /// whose source is not exactly `"acp"`
        /// (`acp_adapter/session.py:527`, v2026.8.31), so a Bot Chat born
        /// over the CLI or the gateway — which is every Bot Chat Scarf or
        /// Hermes Desktop creates — can never be `session/load`-ed and must
        /// be conversed with over the CLI transport instead. `nil` means
        /// the row predates the resolve carrying it (tests) or the source
        /// column couldn't be read; both are treated as NOT ACP-born, which
        /// is the safe direction — the CLI transport works for every
        /// session, the ACP resume only for `"acp"` ones.
        public let liveSource: String?

        /// Whether Hermes' ACP adapter is able to `session/load` the live
        /// tip. Only a session created BY ACP qualifies.
        public var isACPBorn: Bool { liveSource == "acp" }

        public init(registryId: String, liveId: String, liveSource: String? = nil) {
            self.registryId = registryId
            self.liveId = liveId
            self.liveSource = liveSource
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

        let sql = compressionChainStepSQL(
            parentId: "?",
            markerExclusions: hasModelConfig,
            resetExclusion: hasListableChildSupport
        )

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

    /// One step of Hermes's compression-chain walk (`_CHAIN_STEP_SQL`,
    /// hermes_state_compression.py:29-49 @ v2026.9.24): the continuation
    /// child of the session whose id is the SQL expression `parentId`, or
    /// no row. Shared by `compressionTip(for:)` (bound `?`) and
    /// `compressionChains(for:)` (correlated to the recursive CTE), so the
    /// two walks cannot disagree about which child continues a chain.
    ///
    /// `resetExclusion` adds Hermes's `NOT (_RESET_CHILD_SQL)` — a reset
    /// fork of a compression-ended parent is its own conversation, not the
    /// continuation (#114271). It reads `session_key`, so it rides only
    /// where the listable-child predicate already proved that column.
    private func compressionChainStepSQL(
        parentId: String,
        markerExclusions: Bool,
        resetExclusion: Bool
    ) -> String {
        var exclusions = ""
        if markerExclusions {
            exclusions += """

                  AND \(Self.jsonMarker("child.model_config", "$._branched_from")) IS NULL
                  AND \(Self.jsonMarker("child.model_config", "$._delegate_from")) IS NULL
                """
        }
        if resetExclusion {
            exclusions += """

                  AND NOT (\(Self.resetChildSQL(alias: "child")))
                """
        }
        return """
            SELECT child.id
            FROM sessions parent
            JOIN sessions child ON child.parent_session_id = parent.id
            WHERE parent.id = \(parentId)
              AND parent.end_reason = 'compression'\(exclusions)
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
    }

    /// Root-to-tip compression chains for `rootIds`, in ONE query (a
    /// recursive CTE over `compressionChainStepSQL`), keyed by root id.
    /// Only chains that actually moved (two or more ids) are returned.
    ///
    /// One statement rather than `compressionTip(for:)`'s per-hop loop
    /// because this runs on list loads, and on a remote host every hop
    /// would be an SSH round-trip. The recursion is capped at 100 hops and
    /// each chain is cut at its first repeated id, matching the per-hop
    /// walk's seen-set, so a cyclic chain terminates.
    func compressionChains(for rootIds: [String]) async throws -> [String: [String]] {
        let ids = Array(Set(rootIds)).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let step = compressionChainStepSQL(
            parentId: "chain.cur_id",
            markerExclusions: true,
            resetExclusion: true
        )
        let sql = """
            WITH RECURSIVE chain(root_id, cur_id, depth) AS (
                SELECT id, id, 0 FROM sessions WHERE id IN (\(placeholders))
                UNION ALL
                SELECT chain.root_id, (\(step)), chain.depth + 1
                FROM chain
                WHERE chain.cur_id IS NOT NULL AND chain.depth < 100
            )
            SELECT root_id, cur_id FROM chain
            WHERE cur_id IS NOT NULL
            ORDER BY root_id, depth
            """
        let rows = try await backend.query(sql, params: ids.map { .text($0) })
        var chains: [String: [String]] = [:]
        var closed: Set<String> = []
        for row in rows {
            let root = row.string(at: 0)
            let cur = row.string(at: 1)
            guard !root.isEmpty, !cur.isEmpty, !closed.contains(root) else { continue }
            var chain = chains[root, default: []]
            if chain.contains(cur) {
                closed.insert(root)
                continue
            }
            chain.append(cur)
            chains[root] = chain
        }
        return chains.filter { $0.value.count > 1 }
    }

    /// Project every compression-ended root in `sessions` onto the live
    /// tip of its chain, the way every Hermes listing does
    /// (`_project_compression_tips`, hermes_state_sessions.py:1028-1065 @
    /// v2026.9.24, on by default in `list_sessions_rich`).
    ///
    /// A chain is created when a session compresses in rotation mode
    /// (`compression.in_place: false`, or any Hermes before in-place
    /// became the default): the root ends with `end_reason =
    /// 'compression'` and every later turn lands on a continuation row the
    /// list predicate rightly hides. Without this the list showed the
    /// ended root — its stale title and counts — and the conversation's
    /// later turns were unreachable.
    ///
    /// `columns` is the SELECT shape the caller's list used, so the tip
    /// rows decode exactly like the rows they replace. Rows keep their
    /// order (Hermes keeps the root's `started_at` for that reason).
    ///
    /// Gated on the listable-child predicate (v0.20.4+ hosts with JSON1):
    /// older hosts get their list back untouched. Best-effort: if either
    /// query fails, the unprojected list is returned.
    ///
    /// Returns the projected rows plus a root-id → tip-id map so callers
    /// holding per-id side tables (previews) can re-key them.
    private func projectCompressionTips(
        _ sessions: [HermesSession],
        columns: String
    ) async -> (sessions: [HermesSession], tipByRoot: [String: String]) {
        guard hasListableChildSupport else { return (sessions, [:]) }
        let roots = sessions.filter { $0.endReason == "compression" }.map(\.id)
        guard !roots.isEmpty else { return (sessions, [:]) }
        do {
            let chains = try await compressionChains(for: roots)
            guard !chains.isEmpty else { return (sessions, [:]) }
            let tipIds = Array(Set(chains.values.compactMap(\.last)))
            let placeholders = Array(repeating: "?", count: tipIds.count).joined(separator: ",")
            let rows = try await backend.query(
                "SELECT \(columns) FROM \(sessionListFrom) WHERE s.id IN (\(placeholders))",
                params: tipIds.map { .text($0) }
            )
            var tips: [String: HermesSession] = [:]
            for row in rows {
                let tip = sessionFromRow(row)
                tips[tip.id] = tip
            }
            var tipByRoot: [String: String] = [:]
            let projected = sessions.map { session -> HermesSession in
                guard let chain = chains[session.id],
                      let tipId = chain.last,
                      let tip = tips[tipId] else { return session }
                tipByRoot[session.id] = tipId
                // Lets id-keyed lookups (project attribution on resume)
                // find the root the chat was started under.
                SessionLineageIndex.shared.record(server: context.id, lineage: chain)
                return session.projectedOntoCompressionTip(tip, lineage: chain)
            }
            return (projected, tipByRoot)
        } catch {
            Self.logger.warning("compression-tip projection failed: \(error.localizedDescription, privacy: .public)")
            return (sessions, [:])
        }
    }

    /// Re-key `previews` after `projectCompressionTips`: each projected row
    /// shows its tip's preview, as Hermes's listing does, falling back to
    /// the root's opening line when the tip has no eligible user row yet.
    private func rekeyPreviews(
        _ previews: [String: String],
        tipByRoot: [String: String]
    ) async -> [String: String] {
        guard !tipByRoot.isEmpty else { return previews }
        let tipPreviews = await fetchSessionPreviews(sessionIds: Array(tipByRoot.values))
        var result = previews
        for (root, tip) in tipByRoot {
            if let preview = tipPreviews[tip] ?? previews[root] {
                result[tip] = preview
            }
        }
        return result
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
        // The tip's `source` decides the conversation transport (see
        // `CanonicalBotChat.liveSource`). When the walk didn't move, the
        // registry row already carries it; otherwise one more row read.
        let liveSource: String?
        if tip == registry.id {
            liveSource = registry.source
        } else {
            liveSource = await fetchSession(id: tip)?.source
        }
        return CanonicalBotChat(registryId: registry.id, liveId: tip, liveSource: liveSource)
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

    /// Store-wide totals. `since` bounds them to sessions STARTED at or
    /// after that instant; `nil` (the default) keeps the all-time shape
    /// every existing caller had.
    public func fetchStats(since: Date? = nil) async -> SessionStats {
        let sql = statsSQL(since: since)
        do {
            let rows = try await backend.query(sql, params: Self.statsParams(since: since))
            return rows.first.map { statsFromRow($0) } ?? .empty
        } catch {
            return .empty
        }
    }

    /// `statsSQL` binds `since` twice: once in the list-population count
    /// subquery, once for the usage sums.
    private static func statsParams(since: Date?) -> [SQLValue] {
        guard let since else { return [] }
        let bound = SQLValue.real(since.timeIntervalSince1970)
        return [bound, bound]
    }

    /// Aggregate SQL for the stat cards.
    ///
    /// Things this query used NOT to do, each of which made it lie:
    ///
    /// * **`since`.** The Dashboard has always labelled these cards "Last
    ///   7 days" while the query had no `WHERE` at all, so every number
    ///   was an all-time total. The bound is on `started_at`, matching
    ///   `fetchSessionsInPeriod` — the per-session counters it sums are
    ///   lifetime counters for the session, so a long-running session
    ///   started inside the window contributes all of itself, exactly as
    ///   the Insights period aggregates already do.
    /// * **Two populations, on purpose.** The session COUNT is the
    ///   session list's (`sessionListPredicate`): "Sessions: 412" over a
    ///   list of 96 is a different question, not a rounding difference.
    ///   The SUMS (messages, tool calls, tokens, cost) are over every
    ///   session row in the window, as `hermes insights` sums them
    ///   (`fetchUsageAggregatesInPeriod`): spend recorded on a delegate
    ///   subagent or a compression continuation is still spend, and
    ///   dropping it under-reported cost for anyone whose agent delegates.
    ///   Parameters: the `since` bound binds twice when present (count
    ///   subquery, then the sums) — see `statsParams`.
    private func statsSQL(since: Date? = nil) -> String {
        let listStartedAt = hasListableChildSupport ? "s.started_at" : "started_at"
        let listSince = since == nil ? "" : " AND \(listStartedAt) >= ?"
        let count = "(SELECT COUNT(*) FROM \(sessionListFrom) WHERE \(sessionListPredicate)\(listSince))"
        let cols: String
        if hasV07Schema {
            cols = """
                SELECT \(count), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(estimated_cost_usd),0),
                       COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(actual_cost_usd),0)
                """
        } else {
            cols = """
                SELECT \(count), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(estimated_cost_usd),0)
                """
        }
        let sinceClause = since == nil ? "" : " WHERE started_at >= ?"
        return """
            \(cols)
            FROM \(usageSessionsSource)\(sinceClause)
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
        /// Why the batch failed, when it did. `nil` on success —
        /// including a successful load of a genuinely empty store.
        ///
        /// The failure path returns all-zero stats and empty lists, which
        /// on screen is indistinguishable from a fresh Hermes install. So
        /// a dropped SSH channel used to render as "you have done nothing
        /// this week" with no banner and no retry affordance. The
        /// Dashboard surfaces this string instead.
        public let queryError: String?

        public init(
            stats: SessionStats,
            recentSessions: [HermesSession],
            sessionPreviews: [String: String],
            recentToolCalls: [HermesMessage],
            modelUsage: [ModelUsageStat],
            queryError: String? = nil
        ) {
            self.stats = stats
            self.recentSessions = recentSessions
            self.sessionPreviews = sessionPreviews
            self.recentToolCalls = recentToolCalls
            self.modelUsage = modelUsage
            self.queryError = queryError
        }
    }

    /// - Parameter statsSince: bounds the stat-card totals to sessions
    ///   started at or after this instant. The Dashboard passes its
    ///   "Last 7 days" window; `nil` keeps the all-time totals.
    ///
    /// Previews come for exactly the `sessionLimit` listed rows
    /// (`listedSessionPreviewStatement`); there is no separate preview
    /// window any more.
    public func dashboardSnapshot(
        sessionLimit: Int = 5,
        toolCallLimit: Int = 8,
        statsSince: Date? = nil
    ) async -> DashboardSnapshot {
        var statements: [(sql: String, params: [SQLValue])] = [
            (statsSQL(since: statsSince), Self.statsParams(since: statsSince)),
            (
                "SELECT \(sessionColumns) FROM \(sessionListFrom) WHERE \(sessionListPredicate) ORDER BY started_at DESC LIMIT ?",
                [.integer(Int64(sessionLimit))]
            ),
            listedSessionPreviewStatement(limit: sessionLimit),
            (
                // `messageColumnsLight`, not `messageColumns`: the
                // Dashboard's "Recent activity" card renders a tool NAME
                // and an argument summary, and never the chain-of-thought
                // — but the heavy `reasoning_content` blob (20+ KB per
                // thinking-model row) was travelling with every one of
                // these rows on every watcher tick. `active = 1` matches
                // what `fetchRecentToolCallsOutcome` and the Activity feed
                // already filter on, so a rewound tool call stops
                // resurfacing on the Dashboard after the user undid it.
                """
                SELECT \(messageColumnsLight)
                FROM messages
                WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != ''\(hasMessagesActiveColumn ? " AND active = 1" : "")
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
            let listed = (resultSets.count > 1 ? resultSets[1] : []).map { sessionFromRow($0) }
            var previews: [String: String] = [:]
            for row in (resultSets.count > 2 ? resultSets[2] : []) {
                previews[row.string(at: 0)] = SessionPreviewSQL.shape(row.string(at: 1))
            }
            let projection = await projectCompressionTips(listed, columns: sessionColumns)
            let sessions = projection.sessions
            previews = await rekeyPreviews(previews, tipByRoot: projection.tipByRoot)
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
                modelUsage: [],
                queryError: humanize(error)
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
        /// Why the batch failed, when it did; `nil` on success, including
        /// a store that really has no sessions. The failure path returns
        /// empty lists, which on screen read as "No sessions match this
        /// filter" — same reason as `DashboardSnapshot.queryError`.
        public let queryError: String?

        public init(sessions: [HermesSession], previews: [String: String], queryError: String? = nil) {
            self.sessions = sessions
            self.previews = previews
            self.queryError = queryError
        }
    }

    /// - Parameter includeUnreadActivity: selects Hermes's `last_active`
    ///   recency expression alongside the session columns. It is a
    ///   correlated `MAX(messages.timestamp)` subquery **per row**, and the
    ///   ONLY thing that reads it is `HermesSession.isUnread` — whose only
    ///   consumer in the app is the chat sidebar's unread dot
    ///   (`ChatSessionListPane`). The Sessions tab renders no unread
    ///   indicator and asks for 500 rows (ten times the sidebar's 50), so
    ///   it was paying 500 correlated subqueries per watcher tick for a
    ///   column nothing on that screen reads. Pass `false` there.
    ///   `sessionListColumns` is itself gated on `last_read_at` existing,
    ///   so on a pre-v0.20.4 host both settings emit identical SQL.
    public func sessionListSnapshot(
        limit: Int = QueryDefaults.sessionLimit,
        includeUnreadActivity: Bool = true
    ) async -> SessionListSnapshot {
        let columns = includeUnreadActivity ? sessionListColumns : sessionColumns
        let statements: [(sql: String, params: [SQLValue])] = [
            (
                "SELECT \(columns) FROM \(sessionListFrom) WHERE \(sessionListPredicate) ORDER BY started_at DESC LIMIT ?",
                [.integer(Int64(limit))]
            ),
            listedSessionPreviewStatement(limit: limit)
        ]
        do {
            let resultSets = try await backend.queryBatch(statements)
            let listed = (resultSets.first ?? []).map { sessionFromRow($0) }
            var previews: [String: String] = [:]
            for row in (resultSets.count > 1 ? resultSets[1] : []) {
                previews[row.string(at: 0)] = SessionPreviewSQL.shape(row.string(at: 1))
            }
            let projection = await projectCompressionTips(listed, columns: columns)
            previews = await rekeyPreviews(previews, tipByRoot: projection.tipByRoot)
            return SessionListSnapshot(sessions: projection.sessions, previews: previews)
        } catch {
            Self.logger.warning("sessionListSnapshot failed: \(error.localizedDescription, privacy: .public)")
            return SessionListSnapshot(sessions: [], previews: [:], queryError: queryFailure(error).message)
        }
    }

    /// Bundle the queries Insights fires on every load into one
    /// backend round-trip — same rationale as `dashboardSnapshot`.
    public struct InsightsSnapshot: Sendable {
        public let userMessageCount: Int
        public let toolUsage: [(name: String, count: Int)]
        public let startHours: [Int: Int]
        public let daysOfWeek: [Int: Int]
        /// Why the batch failed, when it did; `nil` on success. The failure
        /// path returns zeros, which read as "no usage in this period".
        public var queryError: String? = nil
    }

    /// - Parameter limit: row cap for the histogram query, which returns
    ///   one row per session in the period. Pass the SAME value the caller
    ///   passes `fetchSessionsInPeriod` so both halves of the Insights page
    ///   describe the same set of sessions.
    ///
    /// **Population.** The start-time histogram counts CONVERSATIONS, so
    /// it runs over `sessionListPredicate` — the identical predicate
    /// `fetchSessionsInPeriod` uses. The user-message count and the tool
    /// histogram measure USAGE, so they run over every session row in the
    /// window, like `fetchUsageAggregatesInPeriod` and like `hermes
    /// insights`: a delegate subagent's tool calls happened. (Pre-2026-09
    /// all three used a hand-rolled `parent_session_id IS NULL`, which
    /// matched neither population.)
    public func insightsSnapshot(
        since: Date,
        limit: Int = QueryDefaults.periodSessionLimit
    ) async -> InsightsSnapshot {
        let sinceTs = since.timeIntervalSince1970
        // The predicate is written against `s`, which the JOINs below
        // already alias `sessions` to — and `sessionListFrom` supplies the
        // alias for the standalone histogram query.
        let joinPredicate = sessionListPredicate
        let outerStartedAt = hasListableChildSupport ? "s.started_at" : "started_at"
        let statements: [(sql: String, params: [SQLValue])] = [
            // Usage counts: every session row in the window, the way
            // `hermes insights` counts messages and tool calls
            // (agent/insights.py:108-137 @ v2026.9.24 — a plain
            // `JOIN sessions s … WHERE s.started_at >= ?`). See
            // `fetchUsageAggregatesInPeriod`.
            (
                """
                SELECT COUNT(*) FROM messages m
                JOIN sessions us ON m.session_id = us.id
                WHERE m.role = 'user' AND us.started_at >= ?
                """,
                [.real(sinceTs)]
            ),
            (
                """
                SELECT m.tool_name, COUNT(*) as cnt
                FROM messages m
                JOIN sessions us ON m.session_id = us.id
                WHERE m.tool_name IS NOT NULL AND m.tool_name <> '' AND us.started_at >= ?
                GROUP BY m.tool_name
                ORDER BY cnt DESC
                """,
                [.real(sinceTs)]
            ),
            (
                """
                SELECT \(outerStartedAt) FROM \(sessionListFrom)
                WHERE \(joinPredicate) AND \(outerStartedAt) >= ?
                ORDER BY \(outerStartedAt) DESC LIMIT ?
                """,
                [.real(sinceTs), .integer(Int64(limit))]
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
            Self.logger.warning("insightsSnapshot failed: \(error.localizedDescription, privacy: .public)")
            return InsightsSnapshot(
                userMessageCount: 0, toolUsage: [], startHours: [:], daysOfWeek: [:],
                queryError: queryFailure(error).message
            )
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
        // v0.11 `api_call_count` is appended by the v0.11 block in
        // `sessionColumns`, so its position depends on whether the v0.7
        // block ran — and the analytics / subagent SELECT shapes don't
        // include it at all. Resolve by column NAME (same rule as
        // `rewind_count` / `last_read_at` below); a hardcoded index 20
        // read whatever column happened to sit there on a v0.11 host
        // without the v0.7 columns.
        let apiCallCount: Int = {
            guard hasV011Schema, let idx = row.columnIndex["api_call_count"] else { return 0 }
            return row.int(at: idx)
        }()
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
            // Record that the COLUMN was in the SELECT, not just that the
            // value came back nil. `costStatus` is nil in both cases and
            // they mean opposite things — see
            // `HermesSession.hasCostStatusColumn`. This is the one place any
            // HermesSession is built from a DB row, for BOTH the local and
            // the remote/SSH backend (they share `Row` and this parser), so
            // stamping it here covers every decode path.
            hasCostStatusColumn: hasV07Schema,
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
        let toolCalls = Self.parseToolCalls(toolCallsJSON)
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

    /// Decode `messages.tool_calls` into models, **dropping only the
    /// elements that fail**.
    ///
    /// `HermesToolCall.init(from:)` rejects a call id outside the safe
    /// charset (see `isValidCallId`) — a real guard, since the id is
    /// provider-written and flows into SQL. But decoding the array in one
    /// `decode([HermesToolCall].self)` made that guard **whole-message**:
    /// one hostile or merely unusual id and every *other* tool call on that
    /// assistant turn vanished from the transcript too, silently. A user
    /// reading history would see a reply that referenced work with no calls
    /// under it, and nothing on screen would say why.
    ///
    /// Element-wise decoding keeps the guard exactly as strict for the call
    /// that failed while leaving its siblings — which are addressable, and
    /// whose ids passed — visible. Per-call degradation is the honest
    /// failure mode: drop what we cannot address, render what we can. (F9)
    ///
    /// A payload that isn't a JSON array at all still yields `[]` — there
    /// are no elements to salvage.
    nonisolated static func parseToolCalls(_ json: String?) -> [HermesToolCall] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        // Fast path: the whole array decodes, which is the overwhelmingly
        // common case and avoids re-serialising every element.
        if let calls = try? JSONDecoder().decode([HermesToolCall].self, from: data) {
            return calls
        }
        // Something in there failed. Split the array and decode each element
        // on its own so one bad entry costs only itself.
        guard let elements = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            Self.logger.error("tool_calls payload is not a JSON array; dropping all calls for this message")
            return []
        }
        var calls: [HermesToolCall] = []
        var dropped = 0
        for element in elements {
            guard JSONSerialization.isValidJSONObject([element]),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let call = try? JSONDecoder().decode(HermesToolCall.self, from: elementData)
            else {
                dropped += 1
                continue
            }
            calls.append(call)
        }
        // Count is public (it's a decision about our own data); nothing from
        // the payload is logged — the id is exactly the attacker-influenced
        // string we refused to trust.
        Self.logger.error(
            "dropped \(dropped, privacy: .public) undecodable tool call(s); kept \(calls.count, privacy: .public)"
        )
        return calls
    }

    /// Wraps each whitespace-delimited token in double quotes to prevent FTS5 parse errors
    /// on terms containing dots, hyphens, or FTS5 operators (e.g., "v0.7.0", "config.yaml").
    ///
    /// Splitting on **all** whitespace, not just `" "`: a pasted multi-line
    /// query used to keep its newlines inside a token, and that token was
    /// shipped verbatim as a `.text` param into the remote heredoc. The
    /// heredoc side is now newline-safe on its own (``SQLValueInliner``),
    /// but a newline was never a legitimate part of an FTS phrase either —
    /// tokenizing it away is the correct search behaviour and removes the
    /// vector at the source.
    private func sanitizeFTSQuery(_ raw: String) -> String {
        Self.searchTerms(raw)
            .map { "\"\($0)\"" }
            .joined(separator: " ")
    }

    /// Whitespace-split search terms with every `"` removed and empty
    /// tokens dropped. Shared by the FTS phrase quoting above and the deep
    /// tool-content LIKE fallback so both passes search for the same words.
    private nonisolated static func searchTerms(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
    }
}

#endif // canImport(SQLite3)
