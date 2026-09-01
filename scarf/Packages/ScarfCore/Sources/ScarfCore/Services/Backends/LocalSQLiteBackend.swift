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
    private var openedAtPath: String?
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
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg: String
            if let db {
                msg = String(cString: sqlite3_errmsg(db))
            } else {
                msg = "sqlite3_open_v2 returned \(rc)"
            }
            lastOpenError = "Couldn't open state.db: \(msg)"
            #if canImport(os)
            Self.logger.warning("sqlite3_open_v2 failed (\(rc)) at \(path, privacy: .public): \(msg, privacy: .public)")
            #endif
            db = nil
            return false
        }
        openedAtPath = path
        lastOpenError = nil
        detectSchema()
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
        if !forceFresh, db != nil { return true }
        await close()
        return await open()
    }

    public func close() async {
        if let db {
            sqlite3_close(db)
        }
        db = nil
        openedAtPath = nil
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

    private func detectSchema() {
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
