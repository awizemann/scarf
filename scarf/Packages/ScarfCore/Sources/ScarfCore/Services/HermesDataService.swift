// MARK: - Platform gate
//
// `SQLite3` is a system module on macOS/iOS but not on Linux
// swift-corelibs-foundation. Everything below depends on it heavily, so the
// whole file is gated on `canImport(SQLite3)`. On Linux the types
// (`HermesDataService`, `SnapshotCoordinator`, and helpers) simply don't
// exist — nothing in ScarfCore compiled for Linux references them, so
// there's no downstream breakage. Apple platforms — the only real runtime
// targets — get the full implementation unchanged.
#if canImport(SQLite3)

import Foundation
import SQLite3
#if canImport(os)
import os
#endif

/// Dedupes concurrent `snapshotSQLite` calls for the same server. When the
/// file watcher ticks, Dashboard + Sessions + Activity (+ Chat's loadHistory)
/// can all ask for a fresh snapshot within the same millisecond — without
/// coordination they each spawn their own `ssh host sqlite3 .backup; scp`
/// round-trip, three parallel backups of the same DB. Callers in flight for
/// the same `ServerID` await the first caller's Task and share its result.
public actor SnapshotCoordinator {
    public static let shared = SnapshotCoordinator()
    private var inFlight: [ServerID: Task<URL, Error>] = [:]

    public func snapshot(
        remotePath: String,
        contextID: ServerID,
        transport: any ServerTransport
    ) async throws -> URL {
        if let existing = inFlight[contextID] {
            return try await existing.value
        }
        let task = Task<URL, Error> {
            try transport.snapshotSQLite(remotePath: remotePath)
        }
        inFlight[contextID] = task
        defer { inFlight[contextID] = nil }
        return try await task.value
    }
}

public actor HermesDataService {
    private static let logger = Logger(subsystem: "com.scarf", category: "HermesDataService")

    private var db: OpaquePointer?
    private var hasV07Schema = false
    /// Local filesystem path we last opened. For remote contexts this is
    /// the cached snapshot under `~/Library/Caches/scarf/snapshots/<id>/`.
    private var openedAtPath: String?
    /// Last error from `open()` / `refresh()`, user-presentable. `nil` means
    /// the last attempt succeeded. Views surface this when their own load
    /// path fails, so the user sees "Permission denied reading state.db"
    /// instead of an empty Dashboard with no explanation.
    public private(set) var lastOpenError: String?

    public let context: ServerContext
    private let transport: any ServerTransport

    public init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    public func open() async -> Bool {
        if db != nil { return true }
        let localPath: String
        if context.isRemote {
            // Pull a fresh snapshot from the remote host. Uses `sqlite3
            // .backup` on the remote, which is WAL-safe; a plain cp would
            // corrupt. Routed through SnapshotCoordinator so concurrent
            // view models don't each spawn a parallel SSH backup for the
            // same server.
            do {
                let url = try await SnapshotCoordinator.shared.snapshot(
                    remotePath: context.paths.stateDB,
                    contextID: context.id,
                    transport: transport
                )
                localPath = url.path
                lastOpenError = nil
            } catch {
                lastOpenError = humanize(error)
                Self.logger.warning("snapshotSQLite failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        } else {
            localPath = context.paths.stateDB
            guard FileManager.default.fileExists(atPath: localPath) else {
                lastOpenError = "Hermes state database not found at \(localPath)."
                return false
            }
        }
        // Remote snapshots are point-in-time copies that no one writes to;
        // opening them with `immutable=1` tells SQLite to skip WAL/SHM and
        // locking entirely, which is both faster and avoids spurious
        // "unable to open database file" errors if the snapshot ever gets
        // pulled mid-checkpoint. Local points at the live Hermes DB where
        // the process already has WAL enabled in the header, so a plain
        // readonly open is the right thing.
        let flags: Int32
        let openPath: String
        if context.isRemote {
            openPath = "file:\(localPath)?immutable=1"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        } else {
            openPath = localPath
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        }
        let result = sqlite3_open_v2(openPath, &db, flags, nil)
        guard result == SQLITE_OK else {
            let msg: String
            if let db {
                msg = String(cString: sqlite3_errmsg(db))
            } else {
                msg = "sqlite3_open_v2 returned \(result)"
            }
            lastOpenError = "Couldn't open state.db: \(msg)"
            Self.logger.warning("sqlite3_open_v2 failed (\(result)) at \(localPath, privacy: .public): \(msg, privacy: .public)")
            db = nil
            return false
        }
        openedAtPath = localPath
        lastOpenError = nil
        detectSchema()
        return true
    }

    /// Turn a transport error into the one-line string Dashboard shows. Adds
    /// hints for the common "sqlite3 not installed" and "permission denied"
    /// cases so users know what to do.
    private nonisolated func humanize(_ error: Error) -> String {
        let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = desc.lowercased()
        if lower.contains("sqlite3: command not found") || lower.contains("sqlite3: not found") {
            return "sqlite3 is not installed on \(context.displayName). Install it with `apt install sqlite3` (Ubuntu/Debian) or `yum install sqlite` (RHEL/Fedora)."
        }
        if lower.contains("permission denied") {
            return "Permission denied reading Hermes state on \(context.displayName). The SSH user may not have read access to ~/.hermes/state.db — try Run Diagnostics."
        }
        if lower.contains("no such file") {
            return "Hermes state not found at ~/.hermes on \(context.displayName). If Hermes is installed elsewhere, set its data directory in Manage Servers."
        }
        return desc
    }

    /// Force a fresh snapshot pull + reopen. Used on session-load and in
    /// any path that needs the UI to reflect writes Hermes just made.
    /// Without this, remote snapshots would be frozen at the first `open()`
    /// for the app's lifetime — new messages added to a resumed session
    /// would never appear because the snapshot was pulled before they were
    /// written. Local contexts pay essentially nothing: close+reopen on a
    /// live DB is a no-op.
    @discardableResult
    public func refresh() async -> Bool {
        close()
        return await open()
    }

    public func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Schema Detection

    private func detectSchema() {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(sessions)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == "reasoning_tokens" {
                hasV07Schema = true
                return
            }
        }
    }

    // MARK: - Session Queries

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
        return cols
    }

    public func fetchSessions(limit: Int = QueryDefaults.sessionLimit) -> [HermesSession] {
        guard let db else { return [] }
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var sessions: [HermesSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            sessions.append(sessionFromRow(stmt!))
        }
        return sessions
    }

    public func fetchSessionsInPeriod(since: Date) -> [HermesSession] {
        guard let db else { return [] }
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL AND started_at >= ? ORDER BY started_at DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

        var sessions: [HermesSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            sessions.append(sessionFromRow(stmt!))
        }
        return sessions
    }

    public func fetchSubagentSessions(parentId: String) -> [HermesSession] {
        guard let db else { return [] }
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id = ? ORDER BY started_at ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, parentId, -1, sqliteTransient)

        var sessions: [HermesSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            sessions.append(sessionFromRow(stmt!))
        }
        return sessions
    }

    // MARK: - Message Queries

    private var messageColumns: String {
        var cols = """
            id, session_id, role, content, tool_call_id, tool_calls,
            tool_name, timestamp, token_count, finish_reason
            """
        if hasV07Schema {
            cols += ", reasoning"
        }
        return cols
    }

    public func fetchMessages(sessionId: String) -> [HermesMessage] {
        guard let db else { return [] }
        let sql = "SELECT \(messageColumns) FROM messages WHERE session_id = ? ORDER BY timestamp ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, sqliteTransient)

        var messages: [HermesMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            messages.append(messageFromRow(stmt!))
        }
        return messages
    }

    public func searchMessages(query: String, limit: Int = QueryDefaults.messageSearchLimit) -> [HermesMessage] {
        guard let db else { return [] }
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        let msgCols = hasV07Schema
            ? "m.id, m.session_id, m.role, m.content, m.tool_call_id, m.tool_calls, m.tool_name, m.timestamp, m.token_count, m.finish_reason, m.reasoning"
            : "m.id, m.session_id, m.role, m.content, m.tool_call_id, m.tool_calls, m.tool_name, m.timestamp, m.token_count, m.finish_reason"
        let sql = """
            SELECT \(msgCols)
            FROM messages_fts fts
            JOIN messages m ON m.id = fts.rowid
            WHERE messages_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sanitized, -1, sqliteTransient)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var messages: [HermesMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            messages.append(messageFromRow(stmt!))
        }
        return messages
    }

    public func fetchToolResult(callId: String) -> String? {
        guard let db else { return nil }
        let sql = "SELECT content FROM messages WHERE role = 'tool' AND tool_call_id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, callId, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt!, 0)
    }

    public func fetchRecentToolCalls(limit: Int = QueryDefaults.toolCallLimit) -> [HermesMessage] {
        guard let db else { return [] }
        let sql = """
            SELECT \(messageColumns)
            FROM messages
            WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != ''
            ORDER BY timestamp DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var messages: [HermesMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            messages.append(messageFromRow(stmt!))
        }
        return messages
    }

    public func fetchSessionPreviews(limit: Int = QueryDefaults.sessionPreviewLimit) -> [String: String] {
        guard let db else { return [:] }
        let sql = """
            SELECT m.session_id, substr(m.content, 1, \(QueryDefaults.previewContentLength))
            FROM messages m
            INNER JOIN (
                SELECT session_id, MIN(id) as min_id
                FROM messages
                WHERE role = 'user' AND content <> ''
                GROUP BY session_id
            ) first ON m.id = first.min_id
            ORDER BY m.timestamp DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var previews: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = columnText(stmt!, 0)
            let preview = columnText(stmt!, 1)
            previews[sessionId] = preview
        }
        return previews
    }

    // MARK: - Single-Row Queries

    public struct MessageFingerprint: Equatable, Sendable {
        let count: Int
        let maxId: Int
        let maxTimestamp: Double

        static let empty = MessageFingerprint(count: 0, maxId: 0, maxTimestamp: 0)
    }

    public func fetchMessageFingerprint(sessionId: String) -> MessageFingerprint {
        guard let db else { return .empty }
        let sql = "SELECT COUNT(*), COALESCE(MAX(id), 0), COALESCE(MAX(timestamp), 0) FROM messages WHERE session_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .empty }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .empty }
        return MessageFingerprint(
            count: Int(sqlite3_column_int(stmt, 0)),
            maxId: Int(sqlite3_column_int(stmt, 1)),
            maxTimestamp: sqlite3_column_double(stmt, 2)
        )
    }

    public func fetchMessageCount(sessionId: String) -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM messages WHERE session_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    public func fetchSession(id: String) -> HermesSession? {
        guard let db else { return nil }
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sessionFromRow(stmt!)
    }

    public func fetchMostRecentlyActiveSessionId() -> String? {
        guard let db else { return nil }
        let sql = "SELECT session_id FROM messages ORDER BY timestamp DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt!, 0)
    }

    public func fetchMostRecentlyStartedSessionId(after: Date? = nil) -> String? {
        guard let db else { return nil }
        let sql: String
        if after != nil {
            sql = "SELECT id FROM sessions WHERE parent_session_id IS NULL AND started_at > ? ORDER BY started_at DESC LIMIT 1"
        } else {
            sql = "SELECT id FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT 1"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        if let after {
            sqlite3_bind_double(stmt, 1, after.timeIntervalSince1970)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt!, 0)
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

    public func fetchStats() -> SessionStats {
        guard let db else { return .empty }
        let sql: String
        if hasV07Schema {
            sql = """
                SELECT COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(estimated_cost_usd),0),
                       COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(actual_cost_usd),0)
                FROM sessions
                """
        } else {
            sql = """
                SELECT COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(estimated_cost_usd),0)
                FROM sessions
                """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .empty }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .empty }
        return SessionStats(
            totalSessions: Int(sqlite3_column_int(stmt, 0)),
            totalMessages: Int(sqlite3_column_int(stmt, 1)),
            totalToolCalls: Int(sqlite3_column_int(stmt, 2)),
            totalInputTokens: Int(sqlite3_column_int(stmt, 3)),
            totalOutputTokens: Int(sqlite3_column_int(stmt, 4)),
            totalCostUSD: sqlite3_column_double(stmt, 5),
            totalReasoningTokens: hasV07Schema ? Int(sqlite3_column_int(stmt, 6)) : 0,
            totalActualCostUSD: hasV07Schema ? sqlite3_column_double(stmt, 7) : 0
        )
    }

    // MARK: - Insights Queries

    public func fetchUserMessageCount(since: Date) -> Int {
        guard let db else { return 0 }
        let sql = """
            SELECT COUNT(*) FROM messages m
            JOIN sessions s ON m.session_id = s.id
            WHERE m.role = 'user' AND s.parent_session_id IS NULL AND s.started_at >= ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    public func fetchToolUsage(since: Date) -> [(name: String, count: Int)] {
        guard let db else { return [] }
        let sql = """
            SELECT m.tool_name, COUNT(*) as cnt
            FROM messages m
            JOIN sessions s ON m.session_id = s.id
            WHERE m.tool_name IS NOT NULL AND m.tool_name <> '' AND s.parent_session_id IS NULL AND s.started_at >= ?
            GROUP BY m.tool_name
            ORDER BY cnt DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

        var results: [(name: String, count: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = columnText(stmt!, 0)
            let count = Int(sqlite3_column_int(stmt!, 1))
            results.append((name: name, count: count))
        }
        return results
    }

    public func fetchSessionStartHours(since: Date) -> [Int: Int] {
        guard let db else { return [:] }
        let sql = """
            SELECT started_at FROM sessions WHERE parent_session_id IS NULL AND started_at >= ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

        var hours: [Int: Int] = [:]
        let calendar = Calendar.current
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt!, 0)
            let date = Date(timeIntervalSince1970: ts)
            let hour = calendar.component(.hour, from: date)
            hours[hour, default: 0] += 1
        }
        return hours
    }

    public func fetchSessionDaysOfWeek(since: Date) -> [Int: Int] {
        guard let db else { return [:] }
        let sql = """
            SELECT started_at FROM sessions WHERE parent_session_id IS NULL AND started_at >= ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

        var days: [Int: Int] = [:]
        let calendar = Calendar.current
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt!, 0)
            let date = Date(timeIntervalSince1970: ts)
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7 // Mon=0
            days[weekday, default: 0] += 1
        }
        return days
    }

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

    private func sessionFromRow(_ stmt: OpaquePointer) -> HermesSession {
        HermesSession(
            id: columnText(stmt, 0),
            source: columnText(stmt, 1),
            userId: columnOptionalText(stmt, 2),
            model: columnOptionalText(stmt, 3),
            title: columnOptionalText(stmt, 4),
            parentSessionId: columnOptionalText(stmt, 5),
            startedAt: columnDate(stmt, 6),
            endedAt: columnDate(stmt, 7),
            endReason: columnOptionalText(stmt, 8),
            messageCount: Int(sqlite3_column_int(stmt, 9)),
            toolCallCount: Int(sqlite3_column_int(stmt, 10)),
            inputTokens: Int(sqlite3_column_int(stmt, 11)),
            outputTokens: Int(sqlite3_column_int(stmt, 12)),
            cacheReadTokens: Int(sqlite3_column_int(stmt, 13)),
            cacheWriteTokens: Int(sqlite3_column_int(stmt, 14)),
            estimatedCostUSD: sqlite3_column_type(stmt, 15) != SQLITE_NULL ? sqlite3_column_double(stmt, 15) : nil,
            reasoningTokens: hasV07Schema ? Int(sqlite3_column_int(stmt, 16)) : 0,
            actualCostUSD: hasV07Schema && sqlite3_column_type(stmt, 17) != SQLITE_NULL ? sqlite3_column_double(stmt, 17) : nil,
            costStatus: hasV07Schema ? columnOptionalText(stmt, 18) : nil,
            billingProvider: hasV07Schema ? columnOptionalText(stmt, 19) : nil
        )
    }

    private func messageFromRow(_ stmt: OpaquePointer) -> HermesMessage {
        let toolCallsJSON = columnOptionalText(stmt, 5)
        let toolCalls = parseToolCalls(toolCallsJSON)
        return HermesMessage(
            id: Int(sqlite3_column_int(stmt, 0)),
            sessionId: columnText(stmt, 1),
            role: columnText(stmt, 2),
            content: columnText(stmt, 3),
            toolCallId: columnOptionalText(stmt, 4),
            toolCalls: toolCalls,
            toolName: columnOptionalText(stmt, 6),
            timestamp: columnDate(stmt, 7),
            tokenCount: sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 8)) : nil,
            finishReason: columnOptionalText(stmt, 9),
            reasoning: hasV07Schema ? columnOptionalText(stmt, 10) : nil
        )
    }

    private func parseToolCalls(_ json: String?) -> [HermesToolCall] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([HermesToolCall].self, from: data)
        } catch {
            print("[Scarf] Failed to decode tool calls: \(error.localizedDescription)")
            return []
        }
    }

    private func columnText(_ stmt: OpaquePointer, _ col: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, col) {
            return String(cString: cStr)
        }
        return ""
    }

    private func columnOptionalText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }

    private func columnDate(_ stmt: OpaquePointer, _ col: Int32) -> Date? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(stmt, col)
        return Date(timeIntervalSince1970: value)
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
