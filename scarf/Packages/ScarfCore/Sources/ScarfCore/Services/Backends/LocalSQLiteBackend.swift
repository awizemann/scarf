// MARK: - Platform gate
//
// libsqlite3 is a system module on macOS/iOS but not on swift-corelibs
// foundation. Gate the entire backend so ScarfCore still compiles for
// any future Linux target. Apple platforms — the runtime targets — get
// the full implementation.
#if canImport(SQLite3)

import Foundation
import SQLite3
#if canImport(os)
import os
#endif

/// `HermesQueryBackend` that opens a local SQLite file via libsqlite3
/// and runs queries in-process. Microseconds per query.
///
/// Used for `ServerContext.local` (the user's own `~/.hermes/state.db`)
/// — the previous behaviour of `HermesDataService` lifted out unchanged.
/// For `.ssh` contexts the data service constructs `RemoteSQLiteBackend`
/// instead.
///
/// Actor isolation matches the parent `HermesDataService` actor: queries
/// serialise on this backend's executor, and the data service hops once
/// (`await backend.query…`) per public method call.
public actor LocalSQLiteBackend: HermesQueryBackend {

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "LocalSQLiteBackend")
    #endif

    private var db: OpaquePointer?

    /// `(st_dev, st_ino)` of the file behind the open handle. An open
    /// SQLite connection follows the INODE, not the path, so a state.db
    /// that gets replaced underneath us leaves this backend reading a
    /// file nobody writes to any more — see `refresh(forceFresh:)`.
    private var openedFileIdentity: (dev: UInt64, ino: UInt64)?
    private(set) public var hasV07Schema = false
    private(set) public var hasV011Schema = false
    private(set) public var hasMessagesActiveColumn = false
    private(set) public var hasCompactedColumn = false
    private(set) public var hasCompressedSummaryColumn = false
    private(set) public var hasRewindCountColumn = false
    private(set) public var hasSessionActivityColumns = false
    private(set) public var hasSessionModelUsageTable = false
    private(set) public var hasHiddenColumn = false
    private(set) public var hasLastReadAtColumn = false
    private(set) public var hasListableChildSupport = false
    private(set) public var lastOpenError: String?

    /// True when `open()` had to fall back to a READWRITE handle guarded by
    /// `PRAGMA query_only=1` because the plain READONLY open could not create
    /// the WAL sidecars. Diagnostics only — the connection is still incapable
    /// of writing a row (charter C3).
    private(set) public var isQueryOnlyFallback = false

    private let context: ServerContext

    public init(context: ServerContext) {
        self.context = context
    }

    // MARK: - Lifecycle

    public func open() async -> Bool {
        if db != nil { return true }
        let path = context.paths.stateDB
        guard FileManager.default.fileExists(atPath: path) else {
            lastOpenError = "Hermes state database not found at \(path)."
            return false
        }
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var rc = sqlite3_open_v2(path, &db, flags, nil)

        // `sqlite3_open_v2` is lazy: it allocates the handle without touching
        // the file, so a database Scarf cannot actually read still returns
        // SQLITE_OK here and only fails on the first statement. Probe the
        // schema so `open()` reports the truth its callers assume.
        if rc == SQLITE_OK, let handle = db {
            rc = Self.probeReadable(handle)
        }

        guard rc == SQLITE_OK else {
            let msg: String
            if let db {
                msg = String(cString: sqlite3_errmsg(db))
            } else {
                msg = "sqlite3_open_v2 returned \(rc)"
            }
            // Discard the failed handle before any retry: it must be closed
            // exactly once, and the probe may have left one behind.
            if let db { sqlite3_close(db) }
            db = nil

            // WAL trap: a database left in WAL mode with no -shm/-wal sidecars
            // (CLI-only users, gateway stopped, a fresh home) cannot be READ
            // read-only at all — SQLite must create the shared-memory sidecar
            // before it can read a WAL database, and a READONLY connection
            // can't, so every statement fails SQLITE_CANTOPEN.
            //
            // Creating a sidecar is not a state mutation (charter C3): reopen
            // READWRITE (never CREATE) and immediately clamp the connection
            // with `PRAGMA query_only=1`, which is what makes it incapable of
            // writing a row.
            if rc == SQLITE_CANTOPEN, openQueryOnlyFallback(path: path) {
                #if canImport(os)
                Self.logger.info(
                    "state.db read-only open hit SQLITE_CANTOPEN (WAL without sidecars); reopened query_only at \(path, privacy: .public)"
                )
                #endif
                isQueryOnlyFallback = true
                openedFileIdentity = Self.fileIdentity(of: path)
                lastOpenError = nil
                detectSchema()
                return true
            }

            lastOpenError = "Couldn't open state.db: \(msg)"
            #if canImport(os)
            Self.logger.warning("sqlite3_open_v2 failed (\(rc)) at \(path, privacy: .public): \(msg, privacy: .public)")
            #endif
            return false
        }
        openedFileIdentity = Self.fileIdentity(of: path)
        lastOpenError = nil
        isQueryOnlyFallback = false
        detectSchema()
        return true
    }

    /// Force SQLite to actually touch the database file (and, for a WAL
    /// database, its `-shm` sidecar) by reading the schema. Returns
    /// `SQLITE_OK` when the connection is genuinely usable, otherwise the
    /// result code that the first real statement would have produced.
    private static func probeReadable(_ handle: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil)
        guard prepRC == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return prepRC == SQLITE_OK ? SQLITE_ERROR : prepRC
        }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        return (stepRC == SQLITE_ROW || stepRC == SQLITE_DONE) ? SQLITE_OK : stepRC
    }

    /// Reopen `path` READWRITE (never CREATE) and clamp it with
    /// `PRAGMA query_only=1`. Returns true only when the open, the pragma,
    /// AND the readability probe all succeed; on any failure `db` is left nil
    /// so the caller reports the ORIGINAL error unchanged.
    private func openQueryOnlyFallback(path: String) -> Bool {
        var handle: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        guard sqlite3_exec(handle, "PRAGMA query_only=1", nil, nil, nil) == SQLITE_OK else {
            #if canImport(os)
            Self.logger.warning("PRAGMA query_only=1 failed at \(path, privacy: .public); refusing the writable handle")
            #endif
            sqlite3_close(handle)
            return false
        }
        guard Self.probeReadable(handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        db = handle
        return true
    }

    @discardableResult
    public func refresh(forceFresh: Bool) async -> Bool {
        // Keep the connection open across loads. SQLite's read-only
        // handle picks up Hermes' WAL writes automatically — there's
        // nothing to "refresh" in steady state. Close+reopen on every
        // tick was the dominant cost on a 285 MB state.db + 114 MB WAL
        // (see gh#102): reopening forces SQLite to re-index the WAL
        // page map, and the Dashboard's `.onChange(fileWatcher)` fires
        // that work on every coalesced FSEvent burst.
        //
        // `forceFresh: true` remains the schema-migration escape hatch
        // (rare; only when the user upgrades Hermes and table_info
        // changes mid-session).
        if !forceFresh, db != nil, !stateDBWasReplaced() { return true }
        await close()
        return await open()
    }

    /// True when the file at `context.paths.stateDB` is no longer the
    /// one this handle is reading.
    ///
    /// Hermes v0.21.1 added `quarantine_zeroed_state_db`
    /// (`hermes_state_dbfile.py:238-278`), which MOVES a corrupt state.db
    /// aside — `state.db` → `state.db.zeroed-<ts>-<pid>.bak` — and lets
    /// the next open create a fresh one at the same path. An `sqlite3`
    /// connection is bound to the inode it opened, so without this check
    /// the steady-state `refresh` short-circuit above would keep serving
    /// the quarantined file for the rest of the process's life: no error,
    /// no empty result, just data that silently stops changing. A restore
    /// from backup or a `cp` over the DB has exactly the same shape.
    ///
    /// One `stat(2)` per refresh tick, and only on the path that would
    /// otherwise have done nothing at all. Mirrors Hermes's own
    /// `stat_db_file_identity` (`hermes_state_common.py:245-252`),
    /// including its rule that `st_ino == 0` (some network filesystems)
    /// counts as UNKNOWN — an unknown identity must not be read as a
    /// replacement, or every tick would reopen.
    private func stateDBWasReplaced() -> Bool {
        guard let known = openedFileIdentity,
              let current = Self.fileIdentity(of: context.paths.stateDB) else { return false }
        return known != current
    }

    private static func fileIdentity(of path: String) -> (dev: UInt64, ino: UInt64)? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_ino != 0 else { return nil }
        return (UInt64(st.st_dev), UInt64(st.st_ino))
    }

    public func close() async {
        if let db {
            sqlite3_close(db)
        }
        db = nil
        openedFileIdentity = nil
        isQueryOnlyFallback = false
        resetSchemaFlags()
    }

    deinit {
        // Backstop the file descriptor when the backend is deallocated
        // without an explicit close (e.g., DashboardViewModel teardown
        // on server switch). Actors don't run async cleanup in deinit,
        // but `sqlite3_close` is safe to call from any thread on a
        // pointer no one else holds.
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema detection

    /// Clear every detected-schema flag.
    ///
    /// These are DERIVED state, not accumulated knowledge: they describe the
    /// file behind the current handle. `detectSchema()` only ever sets them
    /// to `true`, so without this a `refresh()` onto a different state.db —
    /// a quarantined-and-recreated one (v0.21.1's
    /// `quarantine_zeroed_state_db`), a restore from backup, a Hermes
    /// DOWNGRADE — kept the previous file's answers and every widened SELECT
    /// then failed with "no such column". `close()` clears them too, so a
    /// refresh whose reopen FAILS reports "no schema" rather than the last
    /// good file's.
    private func resetSchemaFlags() {
        hasV07Schema = false
        hasV011Schema = false
        hasMessagesActiveColumn = false
        hasCompactedColumn = false
        hasCompressedSummaryColumn = false
        hasRewindCountColumn = false
        hasSessionActivityColumns = false
        hasSessionModelUsageTable = false
        hasHiddenColumn = false
        hasLastReadAtColumn = false
        hasListableChildSupport = false
    }

    private func detectSchema() {
        resetSchemaFlags()
        guard let db else { return }

        // sessions schema
        var stmt: OpaquePointer?
        var sawPinned = false
        var sawLastActivityAt = false
        var sawLastActivityDescription = false
        // v0.20.4 listable/ephemeral-child predicate inputs.
        var sawModelConfig = false
        var sawSessionKey = false
        var sawEndReason = false
        var sawStartedAt = false
        var sawEndedAt = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(sessions)", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    let column = String(cString: name)
                    if column == "reasoning_tokens" {
                        hasV07Schema = true
                    }
                    if column == "api_call_count" {
                        hasV011Schema = true
                    }
                    // v0.16+ `sessions.rewind_count` column.
                    if column == "rewind_count" {
                        hasRewindCountColumn = true
                    }
                    // v0.20+ session-activity columns.
                    switch column {
                    case "pinned": sawPinned = true
                    case "last_activity_at": sawLastActivityAt = true
                    case "last_activity_description": sawLastActivityDescription = true
                    // v0.20.4 additive columns.
                    case "hidden": hasHiddenColumn = true
                    case "last_read_at": hasLastReadAtColumn = true
                    case "model_config": sawModelConfig = true
                    case "session_key": sawSessionKey = true
                    case "end_reason": sawEndReason = true
                    case "started_at": sawStartedAt = true
                    case "ended_at": sawEndedAt = true
                    default: break
                    }
                }
            }
        }
        // v0.20: ALL three must be present (belt-and-braces against a
        // partially-migrated DB) before the SELECT shape widens.
        hasSessionActivityColumns = sawPinned && sawLastActivityAt && sawLastActivityDescription

        // v0.20.4: Hermes's listable/ephemeral child predicates. Needs
        // the v0.20.4 marker columns (that release is where Hermes's own
        // listing started surfacing reset children), the columns the
        // predicates read, and a JSON1-capable SQLite for `json_extract`.
        let predicateColumns = sawModelConfig && sawSessionKey
            && sawEndReason && sawStartedAt && sawEndedAt
        hasListableChildSupport = hasHiddenColumn && hasLastReadAtColumn
            && predicateColumns && Self.probeJSON1(db)

        // v0.20+ `session_model_usage` table — detect via sqlite_master.
        var usageStmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'session_model_usage'",
            -1, &usageStmt, nil
        ) == SQLITE_OK {
            defer { sqlite3_finalize(usageStmt) }
            if sqlite3_step(usageStmt) == SQLITE_ROW {
                hasSessionModelUsageTable = sqlite3_column_int64(usageStmt, 0) > 0
            }
        }

        // messages schema — confirm `reasoning_content` is present too.
        // Belt-and-braces: a partially-migrated DB (sessions migrated,
        // messages not) shouldn't blow up reads with "no such column".
        if hasV011Schema {
            var msgStmt: OpaquePointer?
            var sawReasoningContent = false
            if sqlite3_prepare_v2(db, "PRAGMA table_info(messages)", -1, &msgStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(msgStmt) }
                while sqlite3_step(msgStmt) == SQLITE_ROW {
                    if let name = sqlite3_column_text(msgStmt, 1),
                       String(cString: name) == "reasoning_content" {
                        sawReasoningContent = true
                        break
                    }
                }
            }
            if !sawReasoningContent {
                hasV011Schema = false
            }
        }

        // Check for the v0.16+ `messages.active`, v0.18+
        // `messages.compacted` and v0.21 `messages._compressed_summary`
        // columns in one pass.
        var msgActiveStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(messages)", -1, &msgActiveStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(msgActiveStmt) }
            while sqlite3_step(msgActiveStmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(msgActiveStmt, 1) {
                    switch String(cString: name) {
                    case "active":    hasMessagesActiveColumn = true
                    case "compacted": hasCompactedColumn = true
                    case "_compressed_summary": hasCompressedSummaryColumn = true
                    default:          break
                    }
                }
            }
        }
    }

    /// Does this SQLite build carry the JSON1 extension? Built in by
    /// default since 3.38, but a `json_extract` call against a build
    /// without it is a hard "no such function" error that would turn
    /// the whole session list into zero rows — so probe instead of
    /// assuming.
    private static func probeJSON1(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT json_extract('{}', '$.x')", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_finalize(stmt)
        return true
    }

    // MARK: - Queries

    public func query(_ sql: String, params: [SQLValue]) async throws -> [Row] {
        guard let db else { throw BackendError.notOpen }
        return try executeOne(db: db, sql: sql, params: params)
    }

    public func queryBatch(_ statements: [(sql: String, params: [SQLValue])]) async throws -> [[Row]] {
        guard let db else { throw BackendError.notOpen }
        // Local backend has no SSH/process round-trip cost — running
        // sequentially against the open handle is exactly equivalent
        // to running each via `query`. The protocol method exists for
        // remote-backend amortisation; locally we just satisfy the
        // signature.
        var out: [[Row]] = []
        out.reserveCapacity(statements.count)
        for (sql, params) in statements {
            out.append(try executeOne(db: db, sql: sql, params: params))
        }
        return out
    }

    // MARK: - Internals

    private func executeOne(db: OpaquePointer, sql: String, params: [SQLValue]) throws -> [Row] {
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepRC == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw BackendError.sqlite(exitCode: prepRC, stderr: msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in params.enumerated() {
            let col = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, col)
            case .integer(let n):
                rc = sqlite3_bind_int64(stmt, col, n)
            case .real(let d):
                rc = sqlite3_bind_double(stmt, col, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, col, s, -1, sqliteTransient)
            case .blob(let d):
                rc = d.withUnsafeBytes { buf -> Int32 in
                    guard let base = buf.baseAddress else {
                        return sqlite3_bind_zeroblob(stmt, col, 0)
                    }
                    return sqlite3_bind_blob(stmt, col, base, Int32(buf.count), sqliteTransient)
                }
            }
            if rc != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw BackendError.sqlite(exitCode: rc, stderr: msg)
            }
        }

        // Build column-name → index map once per result set, lazily on
        // first row (sqlite3_column_name needs the prepared stmt; cheap
        // either way). For a 0-row result set we still build it so
        // callers that read column names from the first hypothetical
        // row don't error — though `Row.columnIndex` on an empty
        // `[Row]` is moot.
        let columnCount = Int(sqlite3_column_count(stmt))
        var columnIndex: [String: Int] = [:]
        columnIndex.reserveCapacity(columnCount)
        for i in 0..<columnCount {
            if let cstr = sqlite3_column_name(stmt, Int32(i)) {
                columnIndex[String(cString: cstr)] = i
            }
        }

        var rows: [Row] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_DONE { break }
            if stepRC != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(db))
                throw BackendError.sqlite(exitCode: stepRC, stderr: msg)
            }
            var values: [SQLValue] = []
            values.reserveCapacity(columnCount)
            for i in 0..<columnCount {
                let col = Int32(i)
                let type = sqlite3_column_type(stmt, col)
                switch type {
                case SQLITE_NULL:
                    values.append(.null)
                case SQLITE_INTEGER:
                    values.append(.integer(sqlite3_column_int64(stmt, col)))
                case SQLITE_FLOAT:
                    values.append(.real(sqlite3_column_double(stmt, col)))
                case SQLITE_TEXT:
                    if let cstr = sqlite3_column_text(stmt, col) {
                        values.append(.text(String(cString: cstr)))
                    } else {
                        values.append(.text(""))
                    }
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, col))
                    if n > 0, let p = sqlite3_column_blob(stmt, col) {
                        values.append(.blob(Data(bytes: p, count: n)))
                    } else {
                        values.append(.blob(Data()))
                    }
                default:
                    values.append(.null)
                }
            }
            rows.append(Row(values: values, columnIndex: columnIndex))
        }
        return rows
    }
}

#endif // canImport(SQLite3)
