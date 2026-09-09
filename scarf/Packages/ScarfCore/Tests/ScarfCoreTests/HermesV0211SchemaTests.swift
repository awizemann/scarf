#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Hermes v0.21.1 (`v2026.9.7`) state.db shape.
///
/// The audit verdict for this release is "additive": `messages` is
/// byte-identical to v0.21.0, `sessions` gains `tool_names` and
/// `compression_recovery_deadline`, and there is one new table
/// (`conversation_generations`) plus one new index
/// (`idx_sessions_effective_activity`) that Scarf does not read.
///
/// A schema test for a release that changed nothing Scarf reads is
/// exactly the test worth having: it fails the day that stops being
/// true. The DDL below is transcribed from
/// `hermes_state_common.py` at `v2026.9.7` (`sessions` :279-340,
/// `messages` :~400, `conversation_generations`, and the index at
/// :529-530), so the fixture is the release rather than a paraphrase.
@Suite struct HermesV0211SchemaTests {

    /// `messages` at v2026.9.7 — column-for-column, in order. Verified
    /// identical to the v2026.8.31 (v0.21.0) DDL, so this constant is
    /// also the v0.21.0 fixture.
    static let messagesDDL = """
    CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        role TEXT NOT NULL,
        content TEXT,
        tool_call_id TEXT,
        tool_calls TEXT,
        tool_name TEXT,
        effect_disposition TEXT,
        timestamp REAL NOT NULL,
        token_count INTEGER,
        finish_reason TEXT,
        reasoning TEXT,
        reasoning_content TEXT,
        reasoning_details TEXT,
        codex_reasoning_items TEXT,
        codex_message_items TEXT,
        platform_message_id TEXT,
        observed INTEGER DEFAULT 0,
        _compressed_summary INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1,
        compacted INTEGER NOT NULL DEFAULT 0,
        api_content TEXT,
        display_kind TEXT,
        display_metadata TEXT
    );
    """

    /// `sessions` at v2026.9.7. The two additions over v0.21.0 are
    /// `compression_recovery_deadline` and the trailing `tool_names`.
    static let sessionsDDL = """
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        user_id TEXT,
        session_key TEXT,
        chat_id TEXT,
        chat_type TEXT,
        thread_id TEXT,
        display_name TEXT,
        origin_json TEXT,
        expiry_finalized INTEGER DEFAULT 0,
        model TEXT,
        model_config TEXT,
        system_prompt TEXT,
        system_prompt_hash TEXT,
        parent_session_id TEXT,
        started_at REAL NOT NULL,
        ended_at REAL,
        end_reason TEXT,
        message_count INTEGER DEFAULT 0,
        tool_call_count INTEGER DEFAULT 0,
        input_tokens INTEGER DEFAULT 0,
        output_tokens INTEGER DEFAULT 0,
        cache_read_tokens INTEGER DEFAULT 0,
        cache_write_tokens INTEGER DEFAULT 0,
        reasoning_tokens INTEGER DEFAULT 0,
        cwd TEXT,
        git_branch TEXT,
        git_repo_root TEXT,
        git_metadata_generation INTEGER NOT NULL DEFAULT 0,
        billing_provider TEXT,
        billing_base_url TEXT,
        billing_mode TEXT,
        estimated_cost_usd REAL,
        actual_cost_usd REAL,
        cost_status TEXT,
        cost_source TEXT,
        pricing_version TEXT,
        title TEXT,
        title_source TEXT,
        last_activity_at REAL,
        last_activity_description TEXT,
        last_activity_provenance TEXT,
        api_call_count INTEGER DEFAULT 0,
        handoff_state TEXT,
        handoff_platform TEXT,
        handoff_error TEXT,
        compression_failure_cooldown_until REAL,
        compression_failure_error TEXT,
        compression_fallback_streak INTEGER NOT NULL DEFAULT 0,
        compression_ineffective_count INTEGER NOT NULL DEFAULT 0,
        compression_recovery_deadline REAL,
        profile_name TEXT,
        rewind_count INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0,
        hidden INTEGER NOT NULL DEFAULT 0,
        last_read_at REAL,
        tool_names TEXT
    );
    """

    static let extrasDDL = """
    CREATE TABLE conversation_generations (
        source TEXT NOT NULL,
        session_key TEXT NOT NULL,
        generation INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source, session_key)
    );
    CREATE TABLE state_meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE session_model_usage (
        session_id TEXT NOT NULL, model TEXT NOT NULL, task TEXT NOT NULL DEFAULT '',
        input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
        cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
        reasoning_tokens INTEGER DEFAULT 0, estimated_cost_usd REAL DEFAULT 0,
        api_call_count INTEGER DEFAULT 0,
        PRIMARY KEY (session_id, model, task)
    );
    CREATE INDEX idx_sessions_effective_activity
        ON sessions(COALESCE(last_activity_at, started_at) DESC, started_at DESC);
    CREATE VIRTUAL TABLE messages_fts USING fts5(
        content, tool_name, tool_calls, content='messages', content_rowid='id'
    );
    """

    private func makeFixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-v0211-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("state.db").path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let ddl = Self.sessionsDDL + "\n" + Self.messagesDDL + "\n" + Self.extrasDDL + """

        INSERT INTO sessions (id, source, started_at, message_count, tool_call_count,
                              input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                              estimated_cost_usd, tool_names, compression_recovery_deadline)
        VALUES ('s1', 'acp', 1.0, 1, 0, 0, 0, 0, 0, 0.0, '["read_file","bash"]', 99.0);
        INSERT INTO messages (id, session_id, role, content, timestamp)
        VALUES (1, 's1', 'user', 'hello', 1.0);
        INSERT INTO conversation_generations VALUES ('acp', 'k1', 3);
        INSERT INTO messages_fts (rowid, content, tool_name, tool_calls)
        VALUES (1, 'hello', NULL, NULL);
        """
        guard sqlite3_exec(db, ddl, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "DDL failed: \(message)")
        }
        return home
    }

    private func cleanup(_ home: URL) { try? FileManager.default.removeItem(at: home) }

    // MARK: - Tolerance

    /// Every schema probe Scarf owns lands on the right answer, and the
    /// two new `sessions` columns plus the new table are simply ignored.
    @Test func v0211SchemaIsFullyDetected() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasV07Schema)
        #expect(await backend.hasV011Schema)
        #expect(await backend.hasMessagesActiveColumn)
        #expect(await backend.hasCompactedColumn)
        #expect(await backend.hasCompressedSummaryColumn)
        #expect(await backend.hasRewindCountColumn)
        #expect(await backend.hasSessionActivityColumns)
        #expect(await backend.hasSessionModelUsageTable)
        #expect(await backend.hasHiddenColumn)
        #expect(await backend.hasLastReadAtColumn)
        #expect(await backend.hasListableChildSupport)
        #expect(await backend.lastOpenError == nil)
        await backend.close()
    }

    /// Every column Scarf's own SELECTs name must exist on the v0.21.1
    /// shape — the real read paths, not a hand-listed column set.
    @Test func everyColumnScarfSelectsExists() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        #expect(await service.fetchSessions().count == 1)
        #expect(await service.fetchMessages(sessionId: "s1", limit: 10).count == 1)
        _ = await service.fetchSessionPreviews()
        _ = await service.fetchRecentToolCalls()
        _ = await service.fetchRecentToolCallSkeleton()
        _ = await service.fetchSubagentSessions(parentId: "s1")
        // The search path names its own column set (and, on a v0.21.1 host,
        // a second LIKE pass over `messages`) — it belongs in this sweep or
        // its columns are only ever exercised against a paraphrased DDL.
        #expect(await service.searchMessages(query: "hello").count == 1)
        // A failed SELECT is swallowed into an empty result by design, so
        // a missing column would surface here rather than as a throw.
        #expect(await service.lastOpenError == nil)
        await service.close()
    }

    /// `messages` did not change in v0.21.1. Pinned through a REAL database
    /// built from the release DDL and read back with `PRAGMA table_info` —
    /// the same probe production uses — rather than by re-parsing this
    /// file's own string constant, which proves nothing about either the
    /// release or Scarf. The day the constant stops matching
    /// `hermes_state_common.py`, this list has to move with it and the
    /// search/transcript column sets need re-checking.
    @Test func messagesDDLIsUnchangedFromV0210() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        let rows = try await backend.query("PRAGMA table_info(messages)", params: [])
        let columns = rows.map { $0.optionalString(at: 1) ?? "" }
        #expect(columns == [
            "id", "session_id", "role", "content", "tool_call_id", "tool_calls",
            "tool_name", "effect_disposition", "timestamp", "token_count",
            "finish_reason", "reasoning", "reasoning_content", "reasoning_details",
            "codex_reasoning_items", "codex_message_items", "platform_message_id",
            "observed", "_compressed_summary", "active", "compacted", "api_content",
            "display_kind", "display_metadata",
        ])
        // The v0.21 marker column is present and no v0.21.1 column joined it
        // — `tool_names` landed on `sessions`, not here.
        #expect(await backend.hasCompressedSummaryColumn)
        #expect(!columns.contains("tool_names"))
        await backend.close()
    }

    /// `sessions.tool_names` is a JSON array of the tools enabled for a
    /// session. Decoding is probe-gated and has no UI — this pins the
    /// shape so a future badge has something trustworthy to read.
    @Test func toolNamesDecodesAsAJSONArray() async throws {
        let home = try makeFixtureHome()
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        let rows = try await backend.query("SELECT tool_names FROM sessions WHERE id = 's1'", params: [])
        let raw = try #require(rows.first?.optionalString(at: 0))
        let decoded = try JSONDecoder().decode([String].self, from: Data(raw.utf8))
        #expect(decoded == ["read_file", "bash"])
        await backend.close()
    }
}

#endif // canImport(SQLite3)
