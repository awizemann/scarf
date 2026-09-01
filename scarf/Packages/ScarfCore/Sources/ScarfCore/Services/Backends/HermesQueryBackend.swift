import Foundation

/// Pluggable query engine for `HermesDataService`. Two implementations
/// today:
///
/// * `LocalSQLiteBackend` — opens the local `~/.hermes/state.db` via
///   libsqlite3 and runs queries in-process. Microseconds per query.
/// * `RemoteSQLiteBackend` — invokes `sqlite3 -readonly -json` over an
///   SSH session (ControlMaster keeps the channel warm), parses the
///   JSON response into `Row`s. ~50–100 ms per query.
///
/// The data service picks one based on `ServerContext.isRemote`. View
/// models are oblivious — they keep calling `await dataService.fetch…`
/// like before.
///
/// **Why a protocol, not a class hierarchy.** Backends have very
/// different internals (libsqlite3 handles vs. SSH script piping) but
/// the call-site shape is identical. A protocol lets us hand the data
/// service either backend through one stored property without
/// abstract-class ceremony, and keeps the test mock (see
/// `MockHermesQueryBackend` in tests) free of inheritance baggage.
///
/// **Sendable.** Concrete impls are actors, so they're trivially
/// `Sendable`. The protocol conforms to `Sendable` to satisfy Swift 6
/// strict-concurrency for the data-service stored property.
public protocol HermesQueryBackend: Sendable {

    /// True iff the connected DB has the v0.7 columns (`reasoning_tokens`,
    /// `actual_cost_usd`, `cost_status`, `billing_provider` on
    /// `sessions` plus `reasoning` on `messages`). Detected once at
    /// `open()` time.
    var hasV07Schema: Bool { get async }

    /// True iff the connected DB has the v0.11 columns
    /// (`api_call_count` on `sessions`, `reasoning_content` on
    /// `messages`). Belt-and-braces: BOTH must be present (a
    /// partially-migrated DB stays on the v0.7 path to avoid "no such
    /// column" failures).
    var hasV011Schema: Bool { get async }

    /// True iff the connected DB has the v0.16 `messages.active`
    /// column (soft-delete marker for rewound/undone messages).
    /// Detection is one-time at `open()` — the column only exists in
    /// v0.16+, so older DBs get false and bypass the active=1 filter
    /// to avoid "no such column" errors.
    var hasMessagesActiveColumn: Bool { get async }

    /// True iff the connected DB has the v0.18 `messages.compacted`
    /// column. In-place compaction soft-archives the summarized-away
    /// rows as `active=0, compacted=1` (distinct from rewind/undo's
    /// `active=0, compacted=0`), and Hermes search includes them — so
    /// search filters widen to `(active = 1 OR compacted = 1)` when
    /// this column exists. Detected one-time at `open()`.
    var hasCompactedColumn: Bool { get async }

    /// True iff the connected DB has the v0.21 `messages._compressed_summary`
    /// column — the schema-side marker Hermes stamps on rows it wrote as
    /// context-compaction summaries (`hermes_state_common.py` :475;
    /// writers `hermes_state.py` :11620, :12065).
    ///
    /// Detected one-time at `open()` for the same reason every other flag
    /// here is: `SCHEMA_VERSION` stayed at 26 across this DDL change, so
    /// presence — never a version number — is the only sound gate.
    ///
    /// **No Scarf query consults it, deliberately.** Hermes' only reader
    /// (`_rows_to_conversation`, `hermes_state.py` :12899/:12965) uses it
    /// to tag rows when `include_summary_markers` is set; its own session
    /// preview and listing queries ignore it entirely. Scarf already
    /// classifies carriers from content
    /// (`HermesMessage.classifyCompactionSummary`), which works on every
    /// supported host including the pre-v0.21 ones where this column does
    /// not exist — so consulting it would add a schema dependency without
    /// adding information. Kept detected so a future reader has the gate
    /// ready. See `SessionPreviewSQL` for the full rationale.
    var hasCompressedSummaryColumn: Bool { get async }

    /// True iff the connected DB has the v0.16 `sessions.rewind_count`
    /// column (count of how many times a session was rewound). Detected
    /// one-time at `open()` — the column only exists in v0.16+, so older
    /// DBs get false and the column is omitted from the SELECT to avoid
    /// "no such column" errors.
    var hasRewindCountColumn: Bool { get async }

    /// True iff the connected DB has the v0.20 session-activity columns
    /// (`pinned`, `last_activity_at`, `last_activity_description` on
    /// `sessions`). Belt-and-braces: ALL must be present — a partially
    /// migrated DB stays on the old SELECT shape to avoid "no such
    /// column" failures. Detected one-time at `open()`.
    var hasSessionActivityColumns: Bool { get async }

    /// True iff the connected DB has the v0.20 `session_model_usage`
    /// table (per-model token/cost breakdown per session). Detected via
    /// `sqlite_master` one-time at `open()` — absent on pre-v0.20 DBs,
    /// in which case the Dashboard per-model breakdown is skipped
    /// entirely.
    var hasSessionModelUsageTable: Bool { get async }

    /// True iff the connected DB has the v0.20.4 `sessions.hidden`
    /// column (Hermes hides a session from its own listings without
    /// deleting it). Detected one-time at `open()`; when present the
    /// session-list queries add `hidden = 0` so Scarf shows the same
    /// set Hermes does. Absent (pre-v0.20.4) → the filter is omitted
    /// and the emitted SQL is byte-identical to the pre-v0.20.4 shape.
    var hasHiddenColumn: Bool { get async }

    /// True iff the connected DB has the v0.20.4
    /// `sessions.last_read_at` column — the read watermark Hermes
    /// stamps via `set_session_read`. Detected one-time at `open()`;
    /// when present it joins the session SELECT shape and drives the
    /// unread indicator (`HermesSession.isUnread`). Scarf never WRITES
    /// it — state.db is opened read-only and Scarf is a reader of
    /// Hermes state.
    var hasLastReadAtColumn: Bool { get async }

    /// True iff this DB can evaluate Hermes's `_LISTABLE_CHILD_SQL` /
    /// `_ephemeral_child_sql` predicates — i.e. it is a v0.20.4+ DB
    /// (`hidden` AND `last_read_at` present, the release that made
    /// Hermes's own listing surface reset children), it carries the
    /// columns those predicates read (`model_config`, `session_key`,
    /// `end_reason`, `started_at`, `ended_at`), and the SQLite doing
    /// the work has the JSON1 `json_extract` function.
    ///
    /// Gating on the v0.20.4 marker columns (rather than merely on
    /// `model_config` existing, which is ancient) is deliberate: it
    /// keeps every pre-v0.20.4 host on the exact roots-only listing
    /// query it has today, results included, while v0.20.4+ hosts get
    /// the same roots + branch + reset set `hermes sessions list`
    /// shows.
    var hasListableChildSupport: Bool { get async }

    /// User-presentable error from the most recent `open()` (or the
    /// most recent failed query for the remote backend's
    /// connectivity-loss codepath). `nil` means everything is healthy.
    var lastOpenError: String? { get async }

    /// One-time setup. Local: `sqlite3_open_v2` + `PRAGMA table_info`
    /// schema detection. Remote: one SSH round-trip running
    /// `sqlite3 --version` plus the two PRAGMA queries.
    ///
    /// Returns `false` on any failure; detail is in `lastOpenError`.
    /// Calling `open()` on an already-open backend is a no-op that
    /// returns `true`.
    func open() async -> Bool

    /// Local backend: `close()` then `open(forceFresh:)` — re-pulls
    /// the SQLite handle so a Hermes-side migration becomes visible.
    /// Remote backend: a no-op when `forceFresh: false` (every query
    /// is already fresh — there's nothing to refresh). `forceFresh:
    /// true` re-runs the schema preflight, covering the rare "user
    /// upgraded Hermes on the remote, my schema flags are stale" case.
    @discardableResult
    func refresh(forceFresh: Bool) async -> Bool

    /// Drop any persistent resources. Idempotent.
    func close() async

    /// Run a single SQL statement and collect every row before
    /// returning. SQL uses `?` placeholders; `params` is bound
    /// positionally (one entry per `?`).
    ///
    /// Local backend: `sqlite3_prepare_v2` + `sqlite3_bind_*` +
    /// `sqlite3_step` loop, materialising each row into a `Row`.
    /// Remote backend: inlines params via `SQLValueInliner` to produce
    /// a final SQL string, runs `sqlite3 -readonly -json` over SSH,
    /// parses the resulting JSON array.
    ///
    /// Throws `BackendError` on any failure. The data-service façade
    /// generally catches and returns empty results to preserve the
    /// existing "show empty UI on error" behaviour.
    func query(_ sql: String, params: [SQLValue]) async throws -> [Row]

    /// Run several statements in one round-trip, returning each
    /// statement's row set in order. Lets multi-query view loads
    /// (Dashboard's 4-query pattern, Insights' 5-query pattern)
    /// amortise the SSH/sqlite3 cold-start cost.
    ///
    /// Each `(sql, params)` pair has the same shape as `query` —
    /// `?` placeholders bound positionally per pair.
    func queryBatch(_ statements: [(sql: String, params: [SQLValue])]) async throws -> [[Row]]
}

/// Errors that backends raise. Mapped into user-facing messages by the
/// `humanize` helper that lives alongside `HermesDataService`.
public enum BackendError: Error, Sendable, Equatable {
    /// Backend is not open — caller should `open()` first.
    case notOpen

    /// Connectivity failure (SSH down, ControlMaster dead, transport
    /// can't reach the host). Carries a short human-readable reason.
    /// Triggers the data-service's `lastOpenError` populate path.
    case transport(String)

    /// sqlite3 itself reported an error — non-zero exit, parse failure,
    /// schema mismatch. `exitCode` is the sqlite3 process exit (or
    /// libsqlite3 result code on the local backend); `stderr` is the
    /// sqlite3-emitted message (already user-readable in most cases).
    case sqlite(exitCode: Int32, stderr: String)

    /// JSON-parsing failed on remote-backend output. Indicates either a
    /// sqlite3 binary that didn't honour `-json`, or output corruption
    /// (rare). Carries the first 200 bytes of stdout for diagnostics.
    case parseFailure(stdoutHead: String)
}
