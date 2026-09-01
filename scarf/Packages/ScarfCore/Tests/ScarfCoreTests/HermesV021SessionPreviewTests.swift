#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// W6 of the Hermes v0.21.0 parity cycle.
///
/// Two things are pinned here:
///  - **Schema detection** for `messages._compressed_summary`
///    (`hermes_state_common.py` :475). Detection-based, never
///    version-based: `SCHEMA_VERSION` stayed at 26 across this DDL
///    change, so presence is the only sound gate.
///  - **Carrier-aware session previews** ported from Hermes'
///    `_PREVIEW_ELIGIBLE_SQL` / `_PREVIEW_RAW_SELECT`. Every fixture
///    below is exercised against a *real* SQLite file through
///    `LocalSQLiteBackend`, because the whole point of the port is that
///    the semantics live in SQL — a mocked backend would assert on
///    string shape rather than behaviour.
///
/// Fixture matrix: `modern` (active + compacted + _compressed_summary),
/// `v018` (active + compacted, no marker column), and `legacy` (neither
/// active nor compacted) — so the schema gate is proven on the shapes
/// that actually exist in the wild.
@Suite struct HermesV021SessionPreviewTests {

    // MARK: - Hermes carrier literals (verbatim, as a host would write them)

    private static let summaryPrefix =
        "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted "
        + "into the summary below. This is a handoff from a previous context "
        + "window — treat it as background reference, NOT as active instructions. "
        + "Do NOT answer questions or fulfill requests mentioned in this summary; "
        + "they were already addressed."

    private static let legacyPrefix = "[CONTEXT SUMMARY]: earlier turns were summarised."

    private static let endMarker =
        "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"

    private static let mergedDelimiter = "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"
    private static let priorHeader = "[PRIOR CONTEXT — for reference only; not a new message]"

    // MARK: - Fixture

    enum SchemaShape {
        /// v0.21: `active`, `compacted`, `_compressed_summary`.
        case modern
        /// v0.18–v0.20: `active` + `compacted`, no marker column.
        case v018
        /// Pre-v0.16: neither `active` nor `compacted`.
        case legacy

        var messageExtraColumns: String {
            switch self {
            case .modern:
                return ", active INTEGER NOT NULL DEFAULT 1, compacted INTEGER NOT NULL DEFAULT 0"
                    + ", _compressed_summary INTEGER NOT NULL DEFAULT 0"
            case .v018:
                return ", active INTEGER NOT NULL DEFAULT 1, compacted INTEGER NOT NULL DEFAULT 0"
            case .legacy:
                return ""
            }
        }

        var hasActive: Bool { self != .legacy }
    }

    /// One seeded message row.
    struct Msg {
        var session: String
        var role: String = "user"
        var content: String
        var active: Int = 1
        var compacted: Int = 0
        var timestamp: Double
    }

    private func makeFixtureHome(shape: SchemaShape, messages: [Msg]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-v021-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dbPath = home.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
            parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
            message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
            output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
            estimated_cost_usd REAL, reasoning_tokens INTEGER, actual_cost_usd REAL,
            cost_status TEXT, billing_provider TEXT, api_call_count INTEGER,
            rewind_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
            tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
            token_count INTEGER, finish_reason TEXT, reasoning TEXT,
            reasoning_content TEXT\(shape.messageExtraColumns)
        );
        """
        try exec(db, schema)

        // Sessions are derived from the message rows so callers only
        // describe the interesting half.
        var seen: Set<String> = []
        for msg in messages where !seen.contains(msg.session) {
            seen.insert(msg.session)
            try exec(db, """
                INSERT INTO sessions (id, source, started_at, message_count, tool_call_count,
                    input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd)
                VALUES ('\(msg.session)', 'acp', \(msg.timestamp), 1, 0, 0, 0, 0, 0, 0.0);
                """)
        }
        for msg in messages {
            let escaped = msg.content.replacingOccurrences(of: "'", with: "''")
            let columns: String
            let values: String
            switch shape {
            case .modern, .v018:
                columns = ", active, compacted"
                values = ", \(msg.active), \(msg.compacted)"
            case .legacy:
                columns = ""
                values = ""
            }
            try exec(db, """
                INSERT INTO messages (session_id, role, content, timestamp\(columns))
                VALUES ('\(msg.session)', '\(msg.role)', '\(escaped)', \(msg.timestamp)\(values));
                """)
        }
        return home
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture SQL failed: \(msg)")
        }
    }

    private func cleanup(_ home: URL) {
        try? FileManager.default.removeItem(at: home)
    }

    /// Open the façade against a fixture and return its previews.
    private func previews(shape: SchemaShape, messages: [Msg]) async throws -> [String: String] {
        let home = try makeFixtureHome(shape: shape, messages: messages)
        defer { cleanup(home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let result = await service.fetchSessionPreviews(limit: 50)
        await service.close()
        return result
    }

    // MARK: - 1. `_compressed_summary` detection

    @Test func localBackendDetectsCompressedSummaryColumn() async throws {
        let home = try makeFixtureHome(
            shape: .modern,
            messages: [Msg(session: "s1", content: "hello", timestamp: 1)]
        )
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasCompressedSummaryColumn)
        // The pre-existing flags must not have shifted underneath it.
        #expect(await backend.hasMessagesActiveColumn)
        #expect(await backend.hasCompactedColumn)
        await backend.close()
    }

    @Test func localBackendReportsAbsentCompressedSummaryOnV018DB() async throws {
        let home = try makeFixtureHome(
            shape: .v018,
            messages: [Msg(session: "s1", content: "hello", timestamp: 1)]
        )
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasCompressedSummaryColumn == false)
        #expect(await backend.hasCompactedColumn)
        await backend.close()
    }

    @Test func localBackendReportsAbsentCompressedSummaryOnLegacyDB() async throws {
        let home = try makeFixtureHome(
            shape: .legacy,
            messages: [Msg(session: "s1", content: "hello", timestamp: 1)]
        )
        defer { cleanup(home) }
        let backend = LocalSQLiteBackend(context: .local(home: home))
        #expect(await backend.open())
        #expect(await backend.hasCompressedSummaryColumn == false)
        #expect(await backend.hasMessagesActiveColumn == false)
        #expect(await backend.hasCompactedColumn == false)
        await backend.close()
    }

    /// The decision, pinned: no Scarf query may reference the column.
    /// Hermes' own preview/listing SQL doesn't either — its sole reader
    /// tags rows in `_rows_to_conversation`. If a future change starts
    /// consulting it, this test should be updated *deliberately*, with
    /// the schema gate proven alongside.
    @Test func previewSQLNeverReferencesCompressedSummaryColumn() {
        let sql = SessionPreviewSQL.firstEligibleUserRowSQL(
            hasActiveColumn: true,
            hasCompactedColumn: true
        ) + SessionPreviewSQL.rawSelect()
        #expect(!sql.contains("_compressed_summary"))
    }

    // MARK: - 2. Schema gating of the preview SQL

    @Test func legacySchemaPreviewSQLReferencesNoOptionalColumns() {
        let sql = SessionPreviewSQL.firstEligibleUserRowSQL(
            hasActiveColumn: false,
            hasCompactedColumn: false
        )
        #expect(!sql.contains(".active"))
        #expect(!sql.contains(".compacted"))
        #expect(!sql.contains("_compressed_summary"))
        // Only `content` and the never-optional identity columns remain.
        #expect(sql.contains("m.content"))
    }

    @Test func activeOnlySchemaOmitsCompactedReference() {
        let sql = SessionPreviewSQL.firstEligibleUserRowSQL(
            hasActiveColumn: true,
            hasCompactedColumn: false
        )
        #expect(sql.contains("m.active = 1"))
        #expect(!sql.contains("m.compacted"))
    }

    @Test func modernSchemaWidensToCompactedRows() {
        let sql = SessionPreviewSQL.firstEligibleUserRowSQL(
            hasActiveColumn: true,
            hasCompactedColumn: true
        )
        #expect(sql.contains("(m.active = 1 OR m.compacted = 1)"))
    }

    /// The end-to-end proof that the gate holds: a legacy DB with no
    /// `active`/`compacted` columns must still return previews rather
    /// than dying on "no such column".
    @Test func legacySchemaStillProducesPreviews() async throws {
        let result = try await previews(
            shape: .legacy,
            messages: [Msg(session: "s1", content: "port the preview query", timestamp: 10)]
        )
        #expect(result["s1"] == "port the preview query")
    }

    /// A plain single-line first message reads identically on all three
    /// schema shapes — no silent behaviour drift for ordinary sessions.
    @Test func plainPreviewIsIdenticalAcrossSchemaShapes() async throws {
        let msgs = [Msg(session: "s1", content: "refactor the transport layer", timestamp: 10)]
        let legacy = try await previews(shape: .legacy, messages: msgs)
        let v018 = try await previews(shape: .v018, messages: msgs)
        let modern = try await previews(shape: .modern, messages: msgs)
        #expect(legacy["s1"] == "refactor the transport layer")
        #expect(legacy == v018)
        #expect(v018 == modern)
    }

    // MARK: - 3. Compaction-carrier stripping

    /// A *pure* standalone carrier — no end marker, nothing after it —
    /// is ineligible. `MIN(id)` must fall through to the next real user
    /// turn instead of showing the boilerplate.
    @Test func pureStandaloneCarrierIsSkipped() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: Self.summaryPrefix + " …summary body…", timestamp: 10),
            Msg(session: "s1", content: "now add the retry", timestamp: 20)
        ])
        #expect(result["s1"] == "now add the retry")
    }

    /// The legacy `[CONTEXT SUMMARY]:` form is recognised too.
    @Test func pureLegacyCarrierIsSkipped() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: Self.legacyPrefix, timestamp: 10),
            Msg(session: "s1", content: "second real turn", timestamp: 20)
        ])
        #expect(result["s1"] == "second real turn")
    }

    /// A force-user-leading carrier stays eligible and its preview is
    /// the text *after* the end marker — the authentic user turn.
    @Test func forceUserCarrierPreviewsTextAfterEndMarker() async throws {
        let content = Self.summaryPrefix + " …body…\n" + Self.endMarker + "\n\nship the release"
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: content, timestamp: 10)
        ])
        #expect(result["s1"] == "ship the release")
    }

    /// …but only when something survives the marker. A carrier whose
    /// tail is blank is a pure carrier in disguise.
    @Test func forceUserCarrierWithBlankTailIsIneligible() async throws {
        let content = Self.summaryPrefix + " …body…\n" + Self.endMarker + "   \n  "
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: content, timestamp: 10),
            Msg(session: "s1", content: "the real question", timestamp: 20)
        ])
        #expect(result["s1"] == "the real question")
    }

    /// Merged-tail carrier: preserved prior content, delimiter, then the
    /// summary. The preview is the prior content with its
    /// `[PRIOR CONTEXT …]` wrapper header stripped.
    @Test func mergedCarrierPreviewsUnwrappedPriorContent() async throws {
        let content = Self.priorHeader + "\nwhat changed in v0.21?\n"
            + Self.mergedDelimiter + "\n" + Self.summaryPrefix + " …body…"
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: content, timestamp: 10)
        ])
        #expect(result["s1"] == "what changed in v0.21?")
    }

    /// Merged carrier without the wrapper header still yields the prior
    /// content verbatim.
    @Test func mergedCarrierWithoutHeaderPreviewsPriorContent() async throws {
        let content = "unwrapped prior turn\n" + Self.mergedDelimiter + "\n"
            + Self.summaryPrefix + " …body…"
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: content, timestamp: 10)
        ])
        #expect(result["s1"] == "unwrapped prior turn")
    }

    /// A merged carrier whose prior half is empty is ineligible.
    @Test func mergedCarrierWithBlankPriorIsIneligible() async throws {
        let content = Self.priorHeader + "\n  \n" + Self.mergedDelimiter + "\n"
            + Self.summaryPrefix + " …body…"
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: content, timestamp: 10),
            Msg(session: "s1", content: "fallback turn", timestamp: 20)
        ])
        #expect(result["s1"] == "fallback turn")
    }

    /// The anti-false-positive rule Hermes matches the *whole* intro
    /// for: an ordinary message that merely opens with the bracketed
    /// label is a real user turn, not a carrier.
    @Test func messageStartingWithBareLabelIsNotACarrier() async throws {
        let content = "[CONTEXT COMPACTION — REFERENCE ONLY] why does this keep firing?"
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: content, timestamp: 10),
            Msg(session: "s1", content: "later turn", timestamp: 20)
        ])
        #expect(result["s1"] == content)
    }

    /// A carrier marker quoted mid-message must not trigger stripping.
    @Test func carrierMarkerMidContentIsNotACarrier() async throws {
        let content = "the docs quote \(Self.legacyPrefix) verbatim, which broke my grep"
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: content, timestamp: 10)
        ])
        #expect(result["s1"] == content)
    }

    /// Carrier stripping is content-based, so it works on a v0.18 DB
    /// that has no `_compressed_summary` column at all — which is the
    /// reason Scarf does not gate the behaviour on that column.
    @Test func carrierStrippingWorksWithoutTheMarkerColumn() async throws {
        let result = try await previews(shape: .v018, messages: [
            Msg(session: "s1", content: Self.summaryPrefix + " …body…", timestamp: 10),
            Msg(session: "s1", content: "still strips", timestamp: 20)
        ])
        #expect(result["s1"] == "still strips")
    }

    // MARK: - 4. Inactive-row exclusion

    /// A rewound first message (`active = 0, compacted = 0`) is no
    /// longer part of the conversation, so it must not be the preview.
    @Test func rewoundFirstMessageIsExcluded() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: "undone opening line", active: 0, timestamp: 10),
            Msg(session: "s1", content: "the surviving turn", timestamp: 20)
        ])
        #expect(result["s1"] == "the surviving turn")
    }

    /// A compaction-archived row (`active = 0, compacted = 1`) IS the
    /// session's real first message — Hermes soft-archives it in place —
    /// so it stays eligible. This is why the filter widens rather than
    /// simply demanding `active = 1`.
    @Test func compactionArchivedFirstMessageIsKept() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: "archived but real", active: 0, compacted: 1, timestamp: 10),
            Msg(session: "s1", content: "later turn", timestamp: 20)
        ])
        #expect(result["s1"] == "archived but real")
    }

    /// On a v0.18 DB the same widening applies (both columns exist).
    @Test func compactionArchivedRowKeptOnV018Schema() async throws {
        let result = try await previews(shape: .v018, messages: [
            Msg(session: "s1", content: "archived but real", active: 0, compacted: 1, timestamp: 10),
            Msg(session: "s1", content: "later turn", timestamp: 20)
        ])
        #expect(result["s1"] == "archived but real")
    }

    /// Exclusion and carrier-stripping compose: a rewound row followed
    /// by a pure carrier followed by a real turn resolves to the turn.
    @Test func inactiveAndCarrierRowsBothFallThrough() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: "rewound", active: 0, timestamp: 10),
            Msg(session: "s1", content: Self.summaryPrefix + " …body…", timestamp: 20),
            Msg(session: "s1", content: "what actually survived", timestamp: 30)
        ])
        #expect(result["s1"] == "what actually survived")
    }

    // MARK: - 5. Shaping

    @Test func multiLineFirstMessageFlattensToOneLine() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: "line one\nline two\r\nline three", timestamp: 10)
        ])
        #expect(result["s1"] == "line one line two  line three")
    }

    @Test func shapeTrimsAndFlattens() {
        #expect(SessionPreviewSQL.shape("  hello\nworld  ") == "hello world")
        #expect(SessionPreviewSQL.shape("\r\n\r\n") == "")
        #expect(SessionPreviewSQL.shape("plain") == "plain")
    }

    /// Only assistant/tool rows in a session ⇒ no preview entry, same as
    /// before. (`role = 'user'` is untouched by this work.)
    @Test func sessionWithNoUserRowsHasNoPreview() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", role: "assistant", content: "unprompted", timestamp: 10)
        ])
        #expect(result["s1"] == nil)
    }

    /// Every row a carrier ⇒ no preview rather than boilerplate. An
    /// empty sidebar line beats "[CONTEXT COMPACTION — REFERENCE ONLY]…".
    @Test func sessionOfNothingButCarriersHasNoPreview() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: Self.summaryPrefix + " …body…", timestamp: 10),
            Msg(session: "s1", content: Self.legacyPrefix, timestamp: 20)
        ])
        #expect(result["s1"] == nil)
    }

    // MARK: - 6. Carrier pre-filter equivalence

    /// The `INSTR(content, '[CONTEXT ') = 0 OR …` short-circuit is a pure
    /// cost optimisation and must never change a result. Every carrier
    /// shape contains that substring, so a row without it cannot be one —
    /// these cases would all break if the pre-filter ever swallowed a row
    /// the full predicate would have judged differently.
    @Test func carrierPreFilterNeverChangesResults() async throws {
        // A row containing the marker mid-content (pre-filter passes it
        // THROUGH to the full predicate, which must judge it ordinary).
        let midContent = "quoting [CONTEXT SUMMARY]: in a sentence"
        let a = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: midContent, timestamp: 10)
        ])
        #expect(a["s1"] == midContent)

        // A row with no marker at all (pre-filter short-circuits it).
        let b = try await previews(shape: .modern, messages: [
            Msg(session: "s2", content: "nothing special here", timestamp: 10)
        ])
        #expect(b["s2"] == "nothing special here")

        // A real carrier (pre-filter passes through, predicate rejects).
        let c = try await previews(shape: .modern, messages: [
            Msg(session: "s3", content: Self.summaryPrefix + " …body…", timestamp: 10),
            Msg(session: "s3", content: "real turn", timestamp: 20)
        ])
        #expect(c["s3"] == "real turn")
    }

    /// The predicate Scarf hands SQLite must stay byte-identical to
    /// Hermes' generated `_PREVIEW_ELIGIBLE_SQL`, which is why the
    /// pre-filter is composed around it rather than folded into it.
    @Test func eligiblePredicateIsNotPollutedByTheOptimisation() {
        #expect(!SessionPreviewSQL.eligiblePredicate().contains("[CONTEXT '"))
        #expect(!SessionPreviewSQL.eligiblePredicate().contains("INSTR(m.content, '[CONTEXT ')"))
        // …and the inner subquery is where it actually lands.
        let inner = SessionPreviewSQL.firstEligibleUserRowSQL(
            hasActiveColumn: true, hasCompactedColumn: true
        )
        #expect(inner.contains("INSTR(m.content, '[CONTEXT ') = 0"))
    }

    /// Prefix windows are sized in Unicode scalars, matching SQLite's
    /// `SUBSTR` and Python's `len` — not Swift grapheme clusters, which
    /// would silently under-size a window for any future prefix carrying
    /// a flag, ZWJ emoji, or combining mark.
    @Test func prefixWindowsAreSizedInUnicodeScalars() {
        let sql = SessionPreviewSQL.eligiblePredicate()
        // The long-form intro is 204 scalars; the legacy prefix 18.
        #expect(sql.contains("1, 204)"))
        #expect(sql.contains("1, 18)"))
        #expect(SessionPreviewSQL.longFormSummaryPrefix.unicodeScalars.count == 204)
        #expect(SessionPreviewSQL.legacySummaryPrefix.unicodeScalars.count == 18)
        #expect(SessionPreviewSQL.summaryEndMarker.unicodeScalars.count == 84)
        #expect(SessionPreviewSQL.mergedSummaryDelimiter.unicodeScalars.count == 49)
        #expect(SessionPreviewSQL.mergedPriorContextHeader.unicodeScalars.count == 55)
    }

    // MARK: - 7. Remote-backend parity

    /// The remote backend ships this SQL as text through a quoted
    /// heredoc into `sqlite3 -readonly -json` and parses JSON back. The
    /// ported predicate is the first Scarf SQL to embed **multi-byte
    /// literals** (four em dashes) and `X'0A'` blob literals, so it is
    /// also the first that could be silently mangled in transit — and a
    /// mangled prefix fails *quietly*, by never matching, rather than
    /// erroring. Driven through `LocalTransport` (the same seam
    /// `RemoteSQLiteBackendPreflightTests` uses) so the real
    /// heredoc + CLI + JSON round-trip is exercised, not a mock.
    @Test func remoteBackendRoundTripsMultiByteLiteralsThroughSQLite() async throws {
        let home = try makeFixtureHome(shape: .modern, messages: [
            Msg(session: "s1", content: Self.summaryPrefix + " …body…", timestamp: 10),
            Msg(session: "s1", content: "survives the wire", timestamp: 20),
            Msg(session: "s2", content: "plain\nmultiline", timestamp: 30)
        ])
        defer { cleanup(home) }
        let context = ServerContext.local(home: home)
        let backend = RemoteSQLiteBackend(
            context: context,
            transport: LocalTransport(contextID: context.id)
        )
        let service = HermesDataService(context: context, backend: backend)
        #expect(await service.open())
        // Detection must agree with the local backend on the same file.
        #expect(await backend.hasCompressedSummaryColumn)
        let result = await service.fetchSessionPreviews(limit: 50)
        // The em-dash-bearing carrier was recognised and skipped: if the
        // prefix had been corrupted in transit this would be the
        // boilerplate instead.
        #expect(result["s1"] == "survives the wire")
        #expect(result["s2"] == "plain multiline")
        await service.close()
    }

    /// Previews stay per-session — the eligibility filter lives inside
    /// the aggregate, so one session's carrier can't leak into another.
    @Test func previewsAreScopedPerSession() async throws {
        let result = try await previews(shape: .modern, messages: [
            Msg(session: "s1", content: Self.summaryPrefix + " …body…", timestamp: 10),
            Msg(session: "s1", content: "s1 real turn", timestamp: 20),
            Msg(session: "s2", content: "s2 first turn", timestamp: 30)
        ])
        #expect(result["s1"] == "s1 real turn")
        #expect(result["s2"] == "s2 first turn")
    }
}

#endif
