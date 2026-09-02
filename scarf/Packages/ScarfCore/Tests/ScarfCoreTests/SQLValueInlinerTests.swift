import Testing
import Foundation
@testable import ScarfCore

/// Pure unit tests on `try SQLValueInliner.inline(_:params:)` and
/// `SQLValueInliner.encode(_:)`. No backend, no transport, no actor —
/// these are the lexical-substitution rules that drive the remote
/// SQLite backend's `?` → literal pipeline.
@Suite struct SQLValueInlinerTests {

    // MARK: - encode(_:) per SQLValue case

    @Test func encodeNullProducesNULL() {
        #expect(SQLValueInliner.encode(.null) == "NULL")
    }

    @Test func encodeIntegerProducesUnquotedDigits() {
        #expect(SQLValueInliner.encode(.integer(42)) == "42")
        #expect(SQLValueInliner.encode(.integer(-7)) == "-7")
        #expect(SQLValueInliner.encode(.integer(0)) == "0")
        #expect(SQLValueInliner.encode(.integer(Int64.max)) == "9223372036854775807")
    }

    @Test func encodeRealUsesPercent17gFormat() {
        // %.17g round-trips a Double precisely as decimal. Verify the
        // formatted string parses back to the exact same Double.
        let original: Double = 3.14
        let encoded = SQLValueInliner.encode(.real(original))
        #expect(encoded == String(format: "%.17g", original))
        // Round-trip: encoded value re-parsed must equal the source.
        #expect(Double(encoded) == original)

        // Tricky case: 0.1 + 0.2 has imprecise binary representation.
        let imprecise = 0.1 + 0.2
        let encodedImprecise = SQLValueInliner.encode(.real(imprecise))
        #expect(Double(encodedImprecise) == imprecise)
    }

    @Test func encodeTextWrapsInSingleQuotes() {
        #expect(SQLValueInliner.encode(.text("hi")) == "'hi'")
        #expect(SQLValueInliner.encode(.text("")) == "''")
    }

    @Test func encodeTextDoublesEmbeddedSingleQuotes() {
        // SQL literal escape: `it's` becomes `'it''s'`.
        #expect(SQLValueInliner.encode(.text("it's")) == "'it''s'")
        // Multiple embedded quotes — each one is doubled.
        #expect(SQLValueInliner.encode(.text("a'b'c")) == "'a''b''c'")
        // The classic injection-shaped value gets escaped to harmless.
        #expect(SQLValueInliner.encode(.text("' OR 1=1 --")) == "''' OR 1=1 --'")
    }

    @Test func encodeBlobProducesHexLiteral() {
        // Two-byte blob: `X'dead'`.
        #expect(SQLValueInliner.encode(.blob(Data([0xde, 0xad]))) == "X'dead'")
        // Empty blob: `X''`.
        #expect(SQLValueInliner.encode(.blob(Data())) == "X''")
        // Lowercase hex, full byte range, with leading zero preserved.
        #expect(SQLValueInliner.encode(.blob(Data([0x00, 0x0f, 0xff]))) == "X'000fff'")
    }

    // MARK: - inline(_:params:) substitution rules

    @Test func inlineSubstitutesPlaceholdersInOrder() throws {
        let out = try SQLValueInliner.inline(
            "INSERT INTO t VALUES (?, ?, ?)",
            params: [.integer(1), .text("two"), .real(3.0)]
        )
        // Order is preserved: integer 1, text 'two', real 3.0.
        #expect(out.hasPrefix("INSERT INTO t VALUES ("))
        #expect(out.contains("1"))
        #expect(out.contains("'two'"))
        // Real 3.0 should round-trip via %.17g.
        let real3 = String(format: "%.17g", 3.0)
        #expect(out.contains(real3))
    }

    @Test func inlineSkipsPlaceholderInsideStringLiteral() throws {
        // The `?` inside `'?'` is part of a string and must not be bound.
        // Only the trailing `?` (outside the quotes) consumes the param.
        let out = try SQLValueInliner.inline(
            "WHERE name = '?' AND id = ?",
            params: [.integer(7)]
        )
        #expect(out == "WHERE name = '?' AND id = 7")
    }

    @Test func inlineSkipsPlaceholderInsideDoubleQuotedIdentifier() throws {
        // Double-quoted identifiers (column / table names with special chars)
        // are also a quoted region — `?` inside them is literal.
        let out = try SQLValueInliner.inline(
            "SELECT \"col?\" FROM t WHERE x = ?",
            params: [.integer(1)]
        )
        #expect(out == "SELECT \"col?\" FROM t WHERE x = 1")
    }

    @Test func inlineHandlesDoubledSingleQuoteEscapeInString() throws {
        // `'it''s ?'` is a single SQL string literal containing `it's ?`.
        // The doubled single-quote is the SQL escape for an embedded
        // apostrophe — the scanner must NOT toggle out of string state
        // at the doubled quote, and the trailing `?` is inside the string.
        // No params consumed.
        let out = try SQLValueInliner.inline(
            "WHERE x = 'it''s ?'",
            params: []
        )
        #expect(out == "WHERE x = 'it''s ?'")
    }

    @Test func inlineSelectShapeMatchesDataServicePattern() throws {
        // Sanity check: the SELECT shape `HermesDataService.fetchSessions`
        // generates inlines cleanly for the typical `[.integer(100)]`
        // limit param.
        let sql = "SELECT id, source FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT ?"
        let out = try SQLValueInliner.inline(sql, params: [.integer(100)])
        #expect(out == "SELECT id, source FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT 100")
    }

    @Test func inlineWithNoPlaceholdersReturnsInputUnchanged() throws {
        let sql = "SELECT COUNT(*) FROM messages"
        #expect(try SQLValueInliner.inline(sql, params: []) == sql)
    }

    @Test func inlinePreservesAllOtherCharacters() throws {
        // Make sure we're not mangling whitespace, semicolons, parens.
        let sql = "  SELECT  *\n  FROM   t  WHERE id = ?  ;  "
        let out = try SQLValueInliner.inline(sql, params: [.integer(5)])
        #expect(out == "  SELECT  *\n  FROM   t  WHERE id = 5  ;  ")
    }

    @Test func inlineSubstitutesNullPlaceholder() throws {
        let out = try SQLValueInliner.inline(
            "UPDATE t SET col = ? WHERE id = ?",
            params: [.null, .integer(1)]
        )
        #expect(out == "UPDATE t SET col = NULL WHERE id = 1")
    }

    @Test func inlineSubstitutesBlobPlaceholder() throws {
        let out = try SQLValueInliner.inline(
            "INSERT INTO t (data) VALUES (?)",
            params: [.blob(Data([0x01, 0x02, 0x03]))]
        )
        #expect(out == "INSERT INTO t (data) VALUES (X'010203')")
    }

    // MARK: - inline(_:params:) error path (t-aud08)

    @Test func inlineThrowsWhenMorePlaceholdersThanParams() {
        // Was a fatalError (whole-app crash); now a recoverable throw.
        #expect(throws: SQLValueInliner.InlineError.self) {
            _ = try SQLValueInliner.inline("WHERE a = ? AND b = ?", params: [.integer(1)])
        }
    }

    @Test func inlineThrowsWhenFewerPlaceholdersThanParams() {
        #expect(throws: SQLValueInliner.InlineError.self) {
            _ = try SQLValueInliner.inline("WHERE a = ?", params: [.integer(1), .integer(2)])
        }
    }
}

/// The heredoc-escape half of the encoder (F2 / t-e96cc0ad).
///
/// `RemoteSQLiteBackend` ships inlined SQL inside `<<'__SCARF_SQL__'`.
/// Quoting the delimiter stops expansion but not a value that CLOSES the
/// document — so a `.text` param carrying the delimiter on its own line
/// used to turn into remote shell commands. `HermesToolCall.callId`, which
/// comes from the provider's own tool-call JSON, reaches that path.
@Suite struct SQLValueInlinerNewlineTests {

    @Test("a newline never survives as a raw byte in the encoded literal")
    func newlinesAreEncodedNotEmitted() {
        let encoded = SQLValueInliner.encode(.text("a\nb"))
        #expect(!encoded.contains("\n"))
        #expect(encoded == "('a' || char(10) || 'b')")
    }

    @Test("carriage returns are encoded too — a lone CR ends a line for the shell")
    func carriageReturnsAreEncoded() {
        let encoded = SQLValueInliner.encode(.text("a\rb"))
        #expect(!encoded.contains("\r"))
        #expect(encoded == "('a' || char(13) || 'b')")
    }

    @Test("a callId carrying the heredoc delimiter cannot break out")
    func heredocDelimiterIsNeutralized() throws {
        let hostile = "call_1\n__SCARF_SQL__\nrm -rf ~\n"
        let sql = try SQLValueInliner.inline(
            "SELECT content FROM messages WHERE tool_call_id = ?",
            params: [.text(hostile)]
        )
        // The whole point: the delimiter can no longer sit alone on a line.
        #expect(!sql.contains("\n"))
        #expect(sql.contains("char(10)"))
        #expect(sql.contains("rm -rf ~"))  // still present, but as SQL text
    }

    @Test("single-quote escaping still applies inside each newline-split piece")
    func quotesEscapeWithinPieces() {
        #expect(SQLValueInliner.encode(.text("it's\nmine's")) == "('it''s' || char(10) || 'mine''s')")
    }

    @Test("a value with no newline keeps the plain bare literal form")
    func newlineFreeValuesAreUnchanged() {
        // Guards against the encoder wrapping every literal in parens — the
        // old form is what every existing call site and test expects.
        #expect(SQLValueInliner.encode(.text("hello")) == "'hello'")
        #expect(SQLValueInliner.encode(.text("")) == "''")
    }

    @Test("leading and trailing newlines produce empty edge pieces, not dropped ones")
    func edgeNewlinesKeepEmptyPieces() {
        #expect(SQLValueInliner.encode(.text("\nx")) == "('' || char(10) || 'x')")
        #expect(SQLValueInliner.encode(.text("x\n")) == "('x' || char(10) || '')")
    }

    // MARK: - CRLF (F9)

    /// The bug this pins: `"\r\n"` is ONE Swift `Character` (an extended
    /// grapheme cluster) equal to neither `"\n"` nor `"\r"`. The old
    /// `Character`-based loop — and its `String.contains("\n")` fast-path,
    /// which compares graphemes too — matched neither, so a CRLF value took
    /// the "no newline here" branch and was emitted with RAW newline bytes
    /// intact. That is precisely the heredoc-breakout the encoder exists to
    /// prevent, reachable through an attacker-influenced `callId`.
    @Test("CRLF is encoded as two separate char() calls, not passed through raw")
    func crlfIsEncoded() {
        let encoded = SQLValueInliner.encode(.text("a\r\nb"))
        // The empty piece between the two controls is the same convention the
        // edge-newline cases already use — SQLite concatenates it away, and
        // keeping it makes the emitter a single uniform loop.
        #expect(encoded == "('a' || char(13) || '' || char(10) || 'b')")
        #expect(!encoded.contains("\r"))
        #expect(!encoded.contains("\n"))
    }

    /// The fast-path guard specifically: a value whose ONLY line break is a
    /// CRLF must not be short-circuited into the bare-literal form.
    @Test("a CRLF-only value does not take the bare-literal fast path")
    func crlfOnlyValueDoesNotTakeFastPath() {
        let encoded = SQLValueInliner.encode(.text("\r\n"))
        #expect(encoded.hasPrefix("("))
        #expect(encoded == "('' || char(13) || '' || char(10) || '')")
    }

    @Test("a CR-only value is encoded")
    func crOnlyValueIsEncoded() {
        #expect(SQLValueInliner.encode(.text("\r")) == "('' || char(13) || '')")
    }

    @Test("mixed CRLF / LF / CR in one value are each encoded")
    func mixedLineEndingsAreEncoded() {
        let encoded = SQLValueInliner.encode(.text("a\r\nb\nc\rd"))
        #expect(encoded == "('a' || char(13) || '' || char(10) || 'b' || char(10) || 'c' || char(13) || 'd')")
        #expect(!encoded.contains("\r"))
        #expect(!encoded.contains("\n"))
    }

    /// End-to-end via `inline`: the heredoc delimiter preceded by CRLF — the
    /// form the Character-based encoder let through untouched.
    @Test("a CRLF-delimited heredoc breakout attempt cannot survive inline")
    func crlfHeredocBreakoutIsNeutralised() throws {
        let hostile = "x\r\n__SCARF_SQL__\r\nrm -rf ~"
        let sql = try SQLValueInliner.inline(
            "SELECT * FROM tool_calls WHERE call_id = ?",
            params: [.text(hostile)]
        )
        #expect(!sql.contains("\n"))
        #expect(!sql.contains("\r"))
        #expect(sql.contains("char(13)"))
        #expect(sql.contains("char(10)"))
    }

    /// NUL truncates a `sqlite3_prepare`d statement and would silently lop
    /// off the tail of a value; the other C0 controls have no business
    /// appearing raw in SQL shipped through a shell either. All ride the
    /// same `char(n)` mechanism, so nothing is rejected or lost.
    @Test("NUL and other C0 controls are encoded rather than passed through")
    func c0ControlsAreEncoded() {
        #expect(SQLValueInliner.encode(.text("a\u{0}b")) == "('a' || char(0) || 'b')")
        #expect(SQLValueInliner.encode(.text("a\tb")) == "('a' || char(9) || 'b')")
        #expect(SQLValueInliner.encode(.text("a\u{1B}b")) == "('a' || char(27) || 'b')")
        #expect(SQLValueInliner.encode(.text("a\u{7F}b")) == "('a' || char(127) || 'b')")
    }

    /// Non-ASCII text must still take the cheap bare-literal path — scalar
    /// iteration must not start splitting multi-scalar graphemes.
    @Test("emoji and combining marks stay in one bare literal")
    func nonASCIITextIsUnsplit() {
        #expect(SQLValueInliner.encode(.text("héllo 👨‍👩‍👧 🇯🇵")) == "'héllo 👨‍👩‍👧 🇯🇵'")
    }
}

/// Per-call, not per-message, degradation on an undecodable tool call (F9).
///
/// `HermesToolCall`'s call-id charset gate is a real guard — the id is
/// provider-written and reaches SQL. But decoding the whole `tool_calls`
/// array in one shot made the guard whole-message: one bad id silently took
/// every sibling call on that turn with it, leaving a reply that referenced
/// work with nothing under it and no explanation on screen.
@Suite struct ToolCallDecodeDegradationTests {

    private func payload(_ ids: [String]) -> String {
        let objects = ids.map { id in
            """
            {"id":"\(id)","type":"function","function":{"name":"terminal","arguments":"{}"}}
            """
        }
        return "[" + objects.joined(separator: ",") + "]"
    }

    @Test("a hostile call id drops only its own call, not the whole message")
    func hostileIdDropsOnlyItself() {
        // The middle id carries the newline + heredoc delimiter shape the
        // charset gate exists to refuse.
        let json = payload(["call_ok1", "bad\\nid", "call_ok2"])
        let calls = HermesDataService.parseToolCalls(json)
        #expect(calls.map(\.callId) == ["call_ok1", "call_ok2"])
    }

    @Test("an all-valid payload is unchanged and takes the fast path")
    func validPayloadIsUnchanged() {
        let calls = HermesDataService.parseToolCalls(payload(["toolu_01A", "call_b-2.x"]))
        #expect(calls.map(\.callId) == ["toolu_01A", "call_b-2.x"])
    }

    @Test("a structurally broken element drops only itself")
    func malformedElementDropsOnlyItself() {
        let json = """
        [{"id":"call_ok","type":"function","function":{"name":"terminal","arguments":"{}"}},
         {"id":"call_nofunc","type":"function"}]
        """
        #expect(HermesDataService.parseToolCalls(json).map(\.callId) == ["call_ok"])
    }

    @Test("a payload that isn't an array yields no calls")
    func nonArrayPayloadYieldsNothing() {
        #expect(HermesDataService.parseToolCalls("{\"id\":\"x\"}").isEmpty)
        #expect(HermesDataService.parseToolCalls("not json").isEmpty)
        #expect(HermesDataService.parseToolCalls(nil).isEmpty)
        #expect(HermesDataService.parseToolCalls("").isEmpty)
    }
}
