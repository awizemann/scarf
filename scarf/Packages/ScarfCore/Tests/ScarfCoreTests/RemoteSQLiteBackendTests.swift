#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

// MARK: - LocalSQLite3Transport

/// Test-only transport that runs the script through `/bin/sh -c` on the
/// local machine. Lets `RemoteSQLiteBackend`'s production codepath
/// (which calls `transport.streamScript`) drive a real local sqlite3
/// invocation against a tmp fixture DB. No SSH, no Citadel — the
/// backend doesn't care how `streamScript` gets its bytes.
private struct LocalSQLite3Transport: ServerTransport {
    let contextID: ServerID
    let isRemote: Bool = false
    /// When set, exported as `HOME` to the `/bin/sh` that `streamScript`
    /// spawns, so a `~`/`$HOME`-relative path in the script (e.g. the
    /// default `~/.hermes/state.db`) expands to an isolated temp dir
    /// instead of the developer's real home (t-aud25).
    let homeOverride: String?

    init(contextID: ServerID = ServerContext.local.id, homeOverride: String? = nil) {
        self.contextID = contextID
        self.homeOverride = homeOverride
    }

    func readFile(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }
    func writeFile(_ path: String, data: Data) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
    func stat(_ path: String) -> FileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        return FileStat(size: size, mtime: mtime, isDirectory: isDir)
    }
    func listDirectory(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }
    func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    func removeFile(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
        throw TransportError.other(message: "LocalSQLite3Transport.runProcess unused in tests")
    }

    #if !os(iOS)
    func makeProcess(executable: String, args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        return p
    }
    #endif

    func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// The actual workhorse: feed the script to `/bin/sh -c` so heredocs
    /// and command substitution behave exactly as they would on the
    /// remote end of an SSH session. Capture stdout / stderr / exit
    /// code into a `ProcessResult`.
    func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        let homeOverride = self.homeOverride
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments = ["-c", script]
                if let homeOverride {
                    // Deterministic child environment — do NOT snapshot the
                    // live process environment here. Reading
                    // `ProcessInfo.processInfo.environment` (or getenv) races
                    // with sibling suites that mutate the process-global
                    // environment via `setenv` (e.g. HermesProfileResolverTests):
                    // `setenv` can `realloc` `environ` underneath this read,
                    // which under the FULL parallel suite intermittently yielded
                    // a torn/empty `HOME` and a spurious "unable to open database
                    // file" failure (the test passed in isolation). A fixed env
                    // removes the read entirely, so this test is hermetic
                    // regardless of what other suites do to the environment.
                    // `/usr/bin` carries the system sqlite3 (see requireSqlite3).
                    proc.environment = [
                        "HOME": homeOverride,
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
                    ]
                }
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: TransportError.other(
                        message: "Failed to launch /bin/sh: \(error.localizedDescription)"
                    ))
                    return
                }
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                proc.waitUntilExit()
                let stdout = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderr = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }
        }
    }

    func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Suite

/// Integration tests for `RemoteSQLiteBackend`. Drives the real backend
/// against a local sqlite3 binary (via `LocalSQLite3Transport`) and a
/// per-test fixture state.db on disk.
@Suite struct RemoteSQLiteBackendTests {

    // MARK: - Fixture builders

    /// Build a minimal v0.6 baseline state.db (no v0.7, no v0.11 columns).
    /// Each test takes ownership of cleanup via `defer`.
    private func makeFixtureStateDB(
        addV07Columns: Bool = false,
        addV011SessionsColumn: Bool = false,
        addV011MessagesColumn: Bool = false
    ) throws -> URL {
        // Each test gets its own isolated parent dir. We can't dump the
        // fixture directly into `temporaryDirectory` because the symlink
        // we create alongside (`<parent>/state.db`) would clobber a
        // sibling test's symlink when the suite runs in parallel.
        let testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let url = testDir.appendingPathComponent("fixture.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        var sessionsExtra = ""
        if addV07Columns {
            sessionsExtra += ", reasoning_tokens INTEGER, actual_cost_usd REAL, cost_status TEXT, billing_provider TEXT"
        }
        if addV011SessionsColumn {
            sessionsExtra += ", api_call_count INTEGER"
        }
        var messagesExtra = ""
        if addV011MessagesColumn {
            messagesExtra += ", reasoning_content TEXT"
        }

        let schema = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            source TEXT,
            user_id TEXT,
            model TEXT,
            title TEXT,
            parent_session_id TEXT,
            started_at REAL,
            ended_at REAL,
            end_reason TEXT,
            message_count INTEGER,
            tool_call_count INTEGER,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cache_read_tokens INTEGER,
            cache_write_tokens INTEGER,
            estimated_cost_usd REAL\(sessionsExtra)
        );
        INSERT INTO sessions (id, source, user_id, model, title, parent_session_id, started_at, ended_at, end_reason, message_count, tool_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd)
        VALUES ('s1', 'acp', 'u1', 'gpt-5', 'Test', NULL, 1700000000.0, NULL, NULL, 5, 2, 100, 200, 0, 0, 0.05);
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY,
            session_id TEXT,
            role TEXT,
            content TEXT,
            tool_call_id TEXT,
            tool_calls TEXT,
            tool_name TEXT,
            timestamp REAL,
            token_count INTEGER,
            finish_reason TEXT\(messagesExtra)
        );
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason)
        VALUES (1, 's1', 'user', 'hi', NULL, NULL, NULL, 1700000001.0, NULL, NULL);
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, schema, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw TransportError.other(message: "sqlite3_exec failed: \(msg)")
        }
        return url
    }

    /// Construct a remote-shaped context whose `paths.stateDB` points at
    /// the fixture file. We embed the absolute path under a fake
    /// `remoteHome` whose final `/.hermes/state.db` resolves to our
    /// real DB on disk.
    private func makeFixtureContext(dbURL: URL) -> ServerContext {
        // The DB the backend opens is `<paths.home>/state.db`. We point
        // `remoteHome` at the parent dir of the fixture file and then
        // symlink `state.db` to the fixture so the backend's resolved
        // path lands on it.
        let parent = dbURL.deletingLastPathComponent()
        let stateLink = parent.appendingPathComponent("state.db")
        // Replace any prior symlink/file at the canonical "state.db" path.
        try? FileManager.default.removeItem(at: stateLink)
        try? FileManager.default.createSymbolicLink(at: stateLink, withDestinationURL: dbURL)
        return ServerContext(
            id: UUID(),
            displayName: "fixture",
            kind: .ssh(SSHConfig(host: "fake.invalid", remoteHome: parent.path))
        )
    }

    /// Skip the test if /usr/bin/sqlite3 isn't available. Mirrors how
    /// other Apple-only tests gate on system tooling.
    private func requireSqlite3() throws {
        let path = "/usr/bin/sqlite3"
        let exists = FileManager.default.isExecutableFile(atPath: path)
        try #require(exists, "Test requires /usr/bin/sqlite3")
    }

    // MARK: - open() / schema detection

    /// Regression: a default-config remote with `paths.stateDB ==
    /// "~/.hermes/state.db"` previously hit `unable to open database
    /// "~/.hermes/state.db"` because the backend single-quoted the
    /// path and sqlite3 doesn't expand `~` itself. Verify the
    /// $HOME-rewrite path works against a real shell.
    //
    // t-aud25: this used to manipulate the REAL ~/.hermes (move state.db
    // aside, symlink a fixture, restore) and was `.enabled(if:)`-skipped on
    // dev machines as a result. Now we point HOME at a temp dir via the
    // transport's `homeOverride`, so `~`/`$HOME` in the script expands to an
    // isolated home and the real ~/.hermes is never touched — the test runs
    // everywhere, no skip. The probe (`runProcess`) still throws, so the
    // backend falls back to the `"$HOME/..."` rewrite this test exercises.
    @Test func openWithDefaultTildeHomeExpands() async throws {
        try requireSqlite3()
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-tildehome-\(UUID().uuidString)", isDirectory: true)
        let hermesDir = tempHome.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }
        // Symlink the fixture at <tempHome>/.hermes/state.db so the
        // shell-expanded `~/.hermes/state.db` resolves to it.
        let stateLink = hermesDir.appendingPathComponent("state.db")
        try FileManager.default.createSymbolicLink(at: stateLink, withDestinationURL: dbURL)

        // Default remote home → "~/.hermes" (no remoteHome override).
        let ctx = ServerContext(
            id: UUID(),
            displayName: "fixture",
            kind: .ssh(SSHConfig(host: "fake.invalid"))
        )
        // Prime resolvedUserHome to "~" so `open()` skips its probe. That
        // probe runs through `context.makeTransport()` + the process-global
        // `ServerContext.sshTransportFactory`, which a concurrent suite
        // (M5FeatureVMTests) sets/clears — intermittently handing this test a
        // bogus resolved home and a wrong absolute DB path. Priming "~" forces
        // the deterministic "$HOME"-rewrite fallback this test is meant to
        // exercise, independent of that global.
        await ServerContext.primeResolvedHome("~", forServerID: ctx.id)
        let backend = RemoteSQLiteBackend(
            context: ctx,
            transport: LocalSQLite3Transport(homeOverride: tempHome.path)
        )

        let opened = await backend.open()
        #expect(opened)
        let err = await backend.lastOpenError
        #expect(err == nil)

        // And actually run a query through the same expansion path.
        let rows = try await backend.query("SELECT id FROM sessions", params: [])
        #expect(rows.count == 1)
    }

    @Test func openProbesSchemaSuccessfully() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())

        let opened = await backend.open()
        #expect(opened)
        let v07 = await backend.hasV07Schema
        let v011 = await backend.hasV011Schema
        #expect(v07 == false)
        #expect(v011 == false)
        let err = await backend.lastOpenError
        #expect(err == nil)
    }

    @Test func openOnV07SchemaDB() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB(addV07Columns: true)
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())

        let opened = await backend.open()
        #expect(opened)
        let v07 = await backend.hasV07Schema
        let v011 = await backend.hasV011Schema
        #expect(v07 == true)
        #expect(v011 == false)
    }

    @Test func openOnV011SchemaDB() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB(
            addV07Columns: true,
            addV011SessionsColumn: true,
            addV011MessagesColumn: true
        )
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())

        let opened = await backend.open()
        #expect(opened)
        let v011 = await backend.hasV011Schema
        #expect(v011 == true)
    }

    @Test func partialMigrationStaysOnV07() async throws {
        try requireSqlite3()
        // sessions has api_call_count but messages lacks reasoning_content
        // — the belt-and-braces guard should keep hasV011Schema false.
        let dbURL = try makeFixtureStateDB(
            addV07Columns: true,
            addV011SessionsColumn: true,
            addV011MessagesColumn: false
        )
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())

        let opened = await backend.open()
        #expect(opened)
        let v011 = await backend.hasV011Schema
        #expect(v011 == false)
        let v07 = await backend.hasV07Schema
        #expect(v07 == true)
    }

    // MARK: - query()

    @Test func queryReturnsRows() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        let rows = try await backend.query("SELECT id FROM sessions", params: [])
        #expect(rows.count == 1)
        if case .text(let id) = rows[0][0] {
            #expect(id == "s1")
        } else {
            Issue.record("Expected .text id, got \(rows[0][0])")
        }
    }

    @Test func queryWithIntParam() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        let rows = try await backend.query(
            "SELECT id FROM sessions WHERE message_count >= ?",
            params: [.integer(5)]
        )
        #expect(rows.count == 1)
    }

    @Test func queryWithTextParamEscapesQuotes() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        // Injection-shaped value — should be escaped to a harmless literal,
        // matching nothing in the fixture.
        let rows = try await backend.query(
            "SELECT id FROM sessions WHERE id = ?",
            params: [.text("s' OR 1=1 --")]
        )
        #expect(rows.isEmpty)
    }

    @Test func queryEmptyResultSet() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        let rows = try await backend.query(
            "SELECT id FROM sessions WHERE id = ?",
            params: [.text("does-not-exist")]
        )
        #expect(rows.isEmpty)
    }

    @Test func queryNullValuesPreserved() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        let rows = try await backend.query(
            "SELECT id, ended_at, end_reason FROM sessions WHERE id = ?",
            params: [.text("s1")]
        )
        #expect(rows.count == 1)
        // ended_at and end_reason are NULL in the fixture row.
        #expect(rows[0].isNull(at: 1))
        #expect(rows[0].isNull(at: 2))
    }

    // MARK: - queryBatch()

    @Test func queryBatchSplitsResultsCorrectly() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        let results = try await backend.queryBatch([
            (sql: "SELECT id FROM sessions", params: []),
            (sql: "SELECT id FROM messages WHERE session_id = ?", params: [.text("s1")]),
            (sql: "SELECT COUNT(*) FROM sessions", params: [])
        ])
        #expect(results.count == 3)
        // Slot 0: one session row.
        #expect(results[0].count == 1)
        if case .text(let sid) = results[0][0][0] {
            #expect(sid == "s1")
        } else {
            Issue.record("Expected .text in slot 0")
        }
        // Slot 1: one message row.
        #expect(results[1].count == 1)
        // Slot 2: one count row with integer 1.
        #expect(results[2].count == 1)
        if case .integer(let n) = results[2][0][0] {
            #expect(n == 1)
        } else {
            Issue.record("Expected .integer in slot 2")
        }
    }

    @Test func queryBatchHandlesEmptyResultSets() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        // Middle statement returns 0 rows; outer slots should still be
        // populated correctly.
        let results = try await backend.queryBatch([
            (sql: "SELECT id FROM sessions", params: []),
            (sql: "SELECT id FROM messages WHERE session_id = ?", params: [.text("does-not-exist")]),
            (sql: "SELECT COUNT(*) FROM messages", params: [])
        ])
        #expect(results.count == 3)
        #expect(results[0].count == 1)
        #expect(results[1].isEmpty)
        #expect(results[2].count == 1)
    }

    /// Hardening: a hostile/corrupted remote emitting a marker row with an
    /// out-of-range index (e.g. `__SCARF_RS_BEGIN__999`) must throw
    /// `BackendError.parseFailure`, not crash with index-out-of-range.
    /// We provoke it through the public API: a SELECT whose result row is
    /// itself marker-shaped, so the parser reads it as marker 999.
    @Test func queryBatchRejectsOutOfRangeMarkerIndex() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        await #expect(throws: BackendError.self) {
            _ = try await backend.queryBatch([
                (sql: "SELECT '__SCARF_RS_BEGIN__999' AS marker", params: [])
            ])
        }
    }

    // MARK: - Column-order preservation (v2.18 parser)

    /// Insert a raw row directly via libsqlite3 (the backend opens the
    /// DB read-only, so fixtures must be seeded outside it).
    private func insertFixtureRow(_ sql: String, dbURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 (seed) failed")
        }
        defer { sqlite3_close(db) }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw TransportError.other(message: "sqlite3_exec seed failed: \(msg)")
        }
    }

    /// Regression for the v2.18 byte-scan parser: `extractFirstObjectKeys`
    /// must preserve SELECT column order even when row values contain
    /// JSON-ish punctuation (braces, brackets, commas, colons, quotes),
    /// backslash escapes, and multi-byte UTF-8 — anything that could
    /// fool a naive depth/string tracker. The fixture message content
    /// is deliberately hostile to the parser.
    @Test func preservesColumnOrderWithHostileValues() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        // Insert a message whose content is hostile: nested braces,
        // brackets, commas, colons, escaped quotes, backslashes, and
        // multi-byte UTF-8 (Vietnamese).
        let hostile = """
        {"nested": {"a": [1,2,{"x":"y"}]}, "escaped": "quote:\\"comma,colon:brace{", "utf8": "Xin chào — Việt Nam 🇻🇳"}
        """
        let insert = """
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason)
        VALUES (99, 's1', 'assistant', '\(hostile)', NULL, NULL, NULL, 1700000099.0, NULL, NULL);
        """
        try insertFixtureRow(insert, dbURL: dbURL)

        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        // SELECT with a column order the row parser depends on.
        let rows = try await backend.query(
            "SELECT id, role, content, tool_calls, token_count FROM messages WHERE id = 99",
            params: []
        )
        #expect(rows.count == 1)
        let row = rows[0]
        // Positional access proves the key order survived parsing.
        #expect(row.int(at: 0) == 99)
        if case .text(let role) = row[1] {
            #expect(role == "assistant")
        } else {
            Issue.record("Expected .text role at index 1")
        }
        if case .text(let content) = row[2] {
            #expect(content == hostile)
        } else {
            Issue.record("Expected .text content at index 2")
        }
        #expect(row.isNull(at: 3))
        #expect(row.isNull(at: 4))
    }

    /// v2.18 parser: keys must be extracted from the FIRST object only,
    /// and a nested object inside a value must not leak its keys into
    /// the column list. Uses the tool_calls column with a real nested
    /// array-of-objects blob.
    @Test func parserIgnoresNestedObjectKeys() async throws {
        try requireSqlite3()
        let dbURL = try makeFixtureStateDB()
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("state.db"))
        }
        let toolCalls = """
        [{"id":"call_1","name":"search","arguments":"{\\"q\\":\\"x\\"}"},{"id":"call_2","name":"read","arguments":"{}"}]
        """
        let insert = """
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason)
        VALUES (100, 's1', 'assistant', 'nested', NULL, '\(toolCalls)', NULL, 1700000100.0, NULL, NULL);
        """
        try insertFixtureRow(insert, dbURL: dbURL)

        let ctx = makeFixtureContext(dbURL: dbURL)
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())
        _ = await backend.open()

        let rows = try await backend.query(
            "SELECT id, tool_calls FROM messages WHERE id = 100",
            params: []
        )
        #expect(rows.count == 1)
        #expect(rows[0].int(at: 0) == 100)
        if case .text(let tc) = rows[0][1] {
            #expect(tc == toolCalls)
        } else {
            Issue.record("Expected .text tool_calls at index 1")
        }
    }

    // MARK: - Failure paths

    @Test func nonZeroExitThrowsSqliteError() async throws {
        try requireSqlite3()
        // Point at a parent dir with no state.db symlink — sqlite3 will
        // open a brand-new empty DB, so the schema PRAGMAs return empty
        // tables. That actually succeeds. Instead, point remoteHome at
        // a path under a non-existent directory so sqlite3 can't open
        // the file at all.
        let nonExistentParent = "/var/empty/scarf-test-no-such-dir-\(UUID().uuidString)"
        let ctx = ServerContext(
            id: UUID(),
            displayName: "broken",
            kind: .ssh(SSHConfig(host: "fake.invalid", remoteHome: nonExistentParent))
        )
        let backend = RemoteSQLiteBackend(context: ctx, transport: LocalSQLite3Transport())

        let opened = await backend.open()
        #expect(opened == false)
        let err = await backend.lastOpenError
        #expect(err != nil)
        #expect(!(err ?? "").isEmpty)
    }
}

#endif // canImport(SQLite3)
