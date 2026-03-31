import Foundation
import SQLite3

actor HermesDataService {
    private var db: OpaquePointer?

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
        return true
    }

    func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    func fetchSessions(limit: Int = 100) -> [HermesSession] {
        guard let db else { return [] }
        let sql = """
            SELECT id, source, user_id, model, title, parent_session_id,
                   started_at, ended_at, end_reason, message_count, tool_call_count,
                   input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                   estimated_cost_usd
            FROM sessions
            ORDER BY started_at DESC
            LIMIT ?
            """
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

    func fetchMessages(sessionId: String) -> [HermesMessage] {
        guard let db else { return [] }
        let sql = """
            SELECT id, session_id, role, content, tool_call_id, tool_calls,
                   tool_name, timestamp, token_count, finish_reason
            FROM messages
            WHERE session_id = ?
            ORDER BY timestamp ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var messages: [HermesMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            messages.append(messageFromRow(stmt!))
        }
        return messages
    }

    func searchMessages(query: String, limit: Int = 50) -> [HermesMessage] {
        guard let db else { return [] }
        let sql = """
            SELECT m.id, m.session_id, m.role, m.content, m.tool_call_id, m.tool_calls,
                   m.tool_name, m.timestamp, m.token_count, m.finish_reason
            FROM messages_fts fts
            JOIN messages m ON m.id = fts.rowid
            WHERE messages_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, query, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var messages: [HermesMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            messages.append(messageFromRow(stmt!))
        }
        return messages
    }

    func fetchRecentToolCalls(limit: Int = 50) -> [HermesMessage] {
        guard let db else { return [] }
        let sql = """
            SELECT id, session_id, role, content, tool_call_id, tool_calls,
                   tool_name, timestamp, token_count, finish_reason
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

    struct SessionStats: Sendable {
        let totalSessions: Int
        let totalMessages: Int
        let totalToolCalls: Int
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCostUSD: Double
    }

    func fetchStats() -> SessionStats {
        guard let db else {
            return SessionStats(totalSessions: 0, totalMessages: 0, totalToolCalls: 0,
                                totalInputTokens: 0, totalOutputTokens: 0, totalCostUSD: 0)
        }
        let sql = """
            SELECT COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                   COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(estimated_cost_usd),0)
            FROM sessions
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return SessionStats(totalSessions: 0, totalMessages: 0, totalToolCalls: 0,
                                totalInputTokens: 0, totalOutputTokens: 0, totalCostUSD: 0)
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return SessionStats(totalSessions: 0, totalMessages: 0, totalToolCalls: 0,
                                totalInputTokens: 0, totalOutputTokens: 0, totalCostUSD: 0)
        }
        return SessionStats(
            totalSessions: Int(sqlite3_column_int(stmt, 0)),
            totalMessages: Int(sqlite3_column_int(stmt, 1)),
            totalToolCalls: Int(sqlite3_column_int(stmt, 2)),
            totalInputTokens: Int(sqlite3_column_int(stmt, 3)),
            totalOutputTokens: Int(sqlite3_column_int(stmt, 4)),
            totalCostUSD: sqlite3_column_double(stmt, 5)
        )
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
            estimatedCostUSD: sqlite3_column_type(stmt, 15) != SQLITE_NULL ? sqlite3_column_double(stmt, 15) : nil
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
            finishReason: columnOptionalText(stmt, 9)
        )
    }

    private func parseToolCalls(_ json: String?) -> [HermesToolCall] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([HermesToolCall].self, from: data)) ?? []
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
}
