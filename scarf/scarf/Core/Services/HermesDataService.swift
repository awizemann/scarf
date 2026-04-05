import Foundation
import SQLite3

actor HermesDataService {
    private var db: OpaquePointer?
    private var hasV07Schema = false

    func open() -> Bool {
        let path = HermesPaths.stateDB
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK else {
            db = nil
            return false
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        detectSchema()
        return true
    }

    func close() {
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

    func fetchSessions(limit: Int = QueryDefaults.sessionLimit) -> [HermesSession] {
        guard let db else { return [] }
        let sql = "SELECT \(sessionColumns) FROM sessions ORDER BY started_at DESC LIMIT ?"
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

    func fetchSessionsInPeriod(since: Date) -> [HermesSession] {
        guard let db else { return [] }
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE started_at >= ? ORDER BY started_at DESC"
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

    func fetchMessages(sessionId: String) -> [HermesMessage] {
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

    func searchMessages(query: String, limit: Int = QueryDefaults.messageSearchLimit) -> [HermesMessage] {
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

    func fetchRecentToolCalls(limit: Int = QueryDefaults.toolCallLimit) -> [HermesMessage] {
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

    func fetchSessionPreviews(limit: Int = QueryDefaults.sessionPreviewLimit) -> [String: String] {
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

    // MARK: - Stats

    struct SessionStats: Sendable {
        let totalSessions: Int
        let totalMessages: Int
        let totalToolCalls: Int
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCostUSD: Double
        let totalReasoningTokens: Int
        let totalActualCostUSD: Double

        static let empty = SessionStats(
            totalSessions: 0, totalMessages: 0, totalToolCalls: 0,
            totalInputTokens: 0, totalOutputTokens: 0, totalCostUSD: 0,
            totalReasoningTokens: 0, totalActualCostUSD: 0
        )
    }

    func fetchStats() -> SessionStats {
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

    func fetchUserMessageCount(since: Date) -> Int {
        guard let db else { return 0 }
        let sql = """
            SELECT COUNT(*) FROM messages m
            JOIN sessions s ON m.session_id = s.id
            WHERE m.role = 'user' AND s.started_at >= ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func fetchToolUsage(since: Date) -> [(name: String, count: Int)] {
        guard let db else { return [] }
        let sql = """
            SELECT m.tool_name, COUNT(*) as cnt
            FROM messages m
            JOIN sessions s ON m.session_id = s.id
            WHERE m.tool_name IS NOT NULL AND m.tool_name <> '' AND s.started_at >= ?
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

    func fetchSessionStartHours(since: Date) -> [Int: Int] {
        guard let db else { return [:] }
        let sql = """
            SELECT started_at FROM sessions WHERE started_at >= ?
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

    func fetchSessionDaysOfWeek(since: Date) -> [Int: Int] {
        guard let db else { return [:] }
        let sql = """
            SELECT started_at FROM sessions WHERE started_at >= ?
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

    func stateDBModificationDate() -> Date? {
        let walPath = HermesPaths.stateDB + "-wal"
        let dbPath = HermesPaths.stateDB
        let fm = FileManager.default
        let walDate = (try? fm.attributesOfItem(atPath: walPath))?[.modificationDate] as? Date
        let dbDate = (try? fm.attributesOfItem(atPath: dbPath))?[.modificationDate] as? Date
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
