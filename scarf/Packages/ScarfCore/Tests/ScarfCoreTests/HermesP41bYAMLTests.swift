import Testing
import Foundation
@testable import ScarfCore

/// P41b — the round-4 review of P41's own four commits.
///
/// Three of the six findings land in ScarfCore: the double-quoted key scan
/// that dropped a row outright, the simple-key length limit that makes
/// PyYAML refuse the whole document, and the approval-mode trim that ran on
/// the wrong side of the quotes.
@Suite("P41b YAML review")
struct HermesP41bYAMLTests {

    private static let caps = HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")

    // MARK: - Finding 3: a double-quoted KEY with an embedded `\"`

    /// The reviewer's fixture. `HermesYAML.closingQuoteIndex` skipped the
    /// `''` escape for single quotes but not `\"` for double quotes, so the
    /// span closed at the escaped quote, the `hasPrefix(":")` guard failed,
    /// and `parseNestedYAML` dropped the whole row — leaving only `plain`.
    @Test func aDoubleQuotedKeyWithAnEscapedQuoteSurvivesTheParse() throws {
        let yaml = """
        agent:
          reasoning_overrides:
            "gpt\\x01\\"x": high
            plain: low
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        let map = try #require(parsed.maps["agent.reasoning_overrides"])
        #expect(map["plain"] == "low")
        #expect(map["gpt\u{1}\"x"] == "high", "the escaped-quote row was dropped: \(map)")
        #expect(map.count == 2)
    }

    /// An escaped BACKSLASH must not swallow the quote that follows it:
    /// `"a\\\\"` closes right after the doubled backslash.
    @Test func anEscapedBackslashDoesNotSwallowTheClosingQuote() throws {
        let yaml = """
        agent:
          reasoning_overrides:
            "a\\\\": high
            plain: low
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        let map = try #require(parsed.maps["agent.reasoning_overrides"])
        #expect(map["a\\"] == "high", "\(map)")
        #expect(map["plain"] == "low")
    }

    /// The half the finding cares about most: the row must not merely PARSE,
    /// it must survive a save. `setReasoningOverrides` rewrites the block
    /// from what the editor holds, so a row the parser drops is deleted from
    /// the file on the next save — silent data loss, not a display bug.
    @Test(arguments: [
        "gpt\u{1}\"x", "a\"b", "a\\\"b", "quote\"and\ttab",
    ])
    func aKeyWithAQuoteAndAControlRoundTripsThroughASave(_ pattern: String) throws {
        let written = try #require(PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n  max_turns: 10\n",
            pairs: [(key: pattern, value: "high"), (key: "plain", value: "low")],
            capabilities: Self.caps
        ))
        let first = HermesConfig(yaml: written).reasoningOverrides
        #expect(first[pattern] == "high", "not read back: \(first)")
        #expect(first["plain"] == "low")

        // Re-save exactly what was read back — the shape a user gets by
        // opening the pane and pressing Save without touching anything.
        let again = try #require(PowerSettingsWriter.setReasoningOverrides(
            in: written,
            pairs: first.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) },
            capabilities: Self.caps
        ))
        let second = HermesConfig(yaml: again).reasoningOverrides
        #expect(second[pattern] == "high", "the row was deleted by the re-save: \(second)")
        #expect(second.count == 2)
    }

    /// `blockKeySpan` is the one block-style key scanner; these are the
    /// shapes its two callers disagreed on before P41b.
    @Test(arguments: [
        ("'A: B': v", "'A: B'", "v"),
        ("\"A: B\": v", "\"A: B\"", "v"),
        ("\"a\\\"b\": v", "\"a\\\"b\"", "v"),
        ("llama3:8b: high", "llama3:8b", "high"),
        ("command: /usr/local/bin/tool", "command", "/usr/local/bin/tool"),
        ("url: https://mcp.example.com", "url", "https://mcp.example.com"),
        ("'quoted':", "'quoted'", ""),
        ("'quoted' : v", "'quoted'", "v"),   // spaces before the colon are fine
    ])
    func blockKeySpanSplitsTheseShapes(
        _ line: String, _ expectedKey: String, _ expectedValue: String
    ) throws {
        let span = try #require(HermesYAML.blockKeySpan(in: line), "no split for \(line)")
        #expect(String(span.key) == expectedKey)
        #expect(String(span.afterColon).trimmingCharacters(in: .whitespaces) == expectedValue)
    }

    /// And the shapes that are not a `key: value` row at all.
    /// `'a':b` is in this list because PyYAML's parser refuses it — after a
    /// non-plain key the value indicator needs a space or the end of the
    /// line (`ParserError`, PyYAML 6.0.3) — so it is not a row Hermes can
    /// load, and reading it as one meant Scarf showed a row that made Hermes
    /// discard the whole config.yaml layer.
    @Test(arguments: [
        "'unterminated: v", "\"trailing backslash\\", "novaluehere",
        "'a':b", "\"a\":b", "'A: B':v",
        // P42c: a TAB is not a space. PyYAML's SCANNER refuses a tab in
        // this position in every arm — quoted, double-quoted, plain, and
        // with nothing after it at all — so none of these is a row, and
        // reading one as a row shows the user a line that makes Hermes
        // discard the whole config.yaml layer. Pinned against the real
        // interpreter in `pyYAMLRefusesEveryTabSeparatedRow`.
        "'quoted':\tv", "\"quoted\":\tv", "plain:\tv", "'quoted':\t", "plain:\t",
        "'quoted'\t: v",
    ])
    func blockKeySpanRefusesANonRow(_ line: String) {
        #expect(HermesYAML.blockKeySpan(in: line) == nil)
    }

    /// The same rule at the PLAIN separator primitive, which
    /// `blockKeySpan`'s plain arm and `PlatformsViewModel` both go through.
    @Test(arguments: ["k:\tv", "k:\t", "llama3:8b:\thigh"])
    func plainKeySeparatorRefusesATabAfterTheColon(_ line: String) {
        #expect(HermesYAML.plainKeySeparatorIndex(in: line) == nil)
    }

    /// And the interpreter's own verdict on every one of those shapes, so
    /// the refusal is pinned to PyYAML rather than to a reading of it. Each
    /// must raise; `k: v` in the same lane proves the probe can succeed.
    @Test func pyYAMLRefusesEveryTabSeparatedRow() {
        typealias PyYAML = HermesP19YAMLHardeningTests.PyYAML
        // Absence is reported out loud by
        // `HermesP19YAMLHardeningTests.pyYAMLRoundTripLaneIsPresent`; here it
        // only decides whether there is anything to compare against. The
        // assertions below are UNGUARDED — the P41c rule: a guard belongs
        // around the thing that can be ABSENT, never around the thing that
        // can be WRONG.
        guard PyYAML.parses("probe: 1") else { return }

        for line in ["'quoted':\tv", "\"quoted\":\tv", "plain:\tv",
                     "'quoted':\t", "plain:\t", "'quoted'\t: v"] {
            #expect(PyYAML.parses(line) == false,
                    "PyYAML accepted \(line.debugDescription) — then the refusal is ours, not YAML's")
            #expect(HermesYAML.blockKeySpan(in: line) == nil,
                    "Scarf split a line PyYAML refuses: \(line.debugDescription)")
        }
        // The spellings that DO load, so the refusal is a rule and not a
        // blanket "anything with a tab in it".
        for line in ["plain: v", "'quoted': v", "'quoted' : v", "plain:", "'quoted':"] {
            #expect(PyYAML.parses(line), "PyYAML refuses \(line.debugDescription)")
            #expect(HermesYAML.blockKeySpan(in: line) != nil,
                    "Scarf refused a row PyYAML loads: \(line.debugDescription)")
        }
    }

    // MARK: - Finding 6: PyYAML's simple-key length limit

    /// `yaml/scanner.py:283-291` refuses a simple key whose token runs more
    /// than 1024 characters before the `:` (`self.index - key.index > 1024`;
    /// the comment at `:91`). Measured on the EMITTED token, so quoting
    /// spends two characters of the budget rather than buying headroom.
    /// Verified against PyYAML 6.0.3 locally: bare 1024 loads and 1025 does
    /// not; `'…'` with 1022 inside loads and 1023 inside does not.
    @Test func theSimpleKeyLimitIsMeasuredOnTheEmittedToken() {
        #expect(YAMLScalar.simpleKeyLimit == 1024)

        // Plain — `quoteIfNeeded` leaves an ordinary name unquoted.
        #expect(YAMLScalar.exceedsSimpleKeyLimit(String(repeating: "a", count: 1024)) == false)
        #expect(YAMLScalar.exceedsSimpleKeyLimit(String(repeating: "a", count: 1025)))

        // Quoted — a name carrying a colon is emitted `'…'`, so the two
        // quote characters count and the content budget is 1022.
        let colonKey = { (n: Int) in "A: " + String(repeating: "a", count: n - 3) }
        #expect(YAMLScalar.quoteIfNeeded(colonKey(1022)).unicodeScalars.count == 1024)
        #expect(YAMLScalar.exceedsSimpleKeyLimit(colonKey(1022)) == false)
        #expect(YAMLScalar.exceedsSimpleKeyLimit(colonKey(1023)))

        // P41c: PyYAML counts unicode CODE POINTS (Python characters), and
        // Swift's `String.count` counts grapheme CLUSTERS. `e` + U+0301 is
        // one Character and two scalars, so 600 of them are 600 by `.count`
        // and 1200 to PyYAML — under the old measure the guard passed and
        // PyYAML refused the whole document.
        let combining = String(repeating: "e\u{301}", count: 600)
        #expect(combining.count == 600, "600 grapheme clusters")
        #expect(combining.unicodeScalars.count == 1200)
        #expect(YAMLScalar.exceedsSimpleKeyLimit(combining))
        #expect(YAMLScalar.exceedsSimpleKeyLimit(String(repeating: "e\u{301}", count: 512)) == false,
                "1024 scalars exactly — refusing them is over-refusal")
        #expect(YAMLScalar.exceedsSimpleKeyLimit(String(repeating: "e\u{301}", count: 513)))

        // An emoji ZWJ sequence is one Character and SEVEN scalars.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        #expect(family.count == 1)
        #expect(family.unicodeScalars.count == 7)
        #expect(YAMLScalar.exceedsSimpleKeyLimit(String(repeating: family, count: 147)),
                "1029 scalars, and only 147 Characters")
        #expect(YAMLScalar.exceedsSimpleKeyLimit(String(repeating: family, count: 146)) == false,
                "1022 scalars")
    }

    /// The reasoning-override pattern is a map key too, and it is checked in
    /// the form `setReasoningOverrides` writes it — trimmed.
    @Test func theReasoningOverridePatternRefusesAnOversizedKey() {
        let long = String(repeating: "m", count: 1025)
        #expect(PowerSettingsWriter.oversizedKeyFieldLabel(pattern: long) == "Model pattern")
        #expect(PowerSettingsWriter.oversizedKeyFieldLabel(pattern: "  \(long)  ") == "Model pattern",
                "the writer trims, so the check must too")
        #expect(PowerSettingsWriter.oversizedKeyFieldLabel(pattern: "gpt-4o") == nil)
        #expect(
            PowerSettingsWriter.oversizedKeyFieldLabel(
                pattern: String(repeating: "m", count: 1024)
            ) == nil,
            "1024 bare characters load — refusing them is over-refusal"
        )
    }

    // MARK: - Finding 5: `HermesApprovalMode.normalize` trimmed too early

    /// Hermes's string arm is `mode.strip().lower()`
    /// (`tools/approval_context.py:207` @ `v2026.9.7`), and PyYAML hands it
    /// the scalar's CONTENT — so the whitespace INSIDE the quotes is what
    /// gets stripped. Trimming the raw scalar first only ever removed
    /// whitespace outside them, so `" off"` landed on `.manual`: a picker
    /// reading "Ask every time" on a host that asks for nothing.
    @Test(arguments: [
        // raw scalar as it stands in config.yaml, expected mode
        ("\" off\"", HermesApprovalMode.off),
        ("\"off \"", HermesApprovalMode.off),
        ("\"\toff\t\"", HermesApprovalMode.off),
        ("' off '", HermesApprovalMode.off),
        ("\" smart \"", HermesApprovalMode.smart),
        ("' manual '", HermesApprovalMode.manual),
        // Unchanged by the move: the bare arm was already trimmed.
        ("off", HermesApprovalMode.off),
        (" off ", HermesApprovalMode.off),
        ("\"off\"", HermesApprovalMode.off),
        ("\"on\"", HermesApprovalMode.manual),
        ("\"no\"", HermesApprovalMode.manual),
        ("\"false\"", HermesApprovalMode.manual),
        ("no", HermesApprovalMode.off),
        ("false", HermesApprovalMode.off),
        ("yes", HermesApprovalMode.manual),
        ("0", HermesApprovalMode.manual),
        ("1", HermesApprovalMode.manual),
        ("\" \"", HermesApprovalMode.manual),
        ("auto", HermesApprovalMode.manual),
        // A whitespace-padded quoted spelling that is NOT a valid mode still
        // warns and lands on manual, exactly as Hermes does.
        ("\" auto \"", HermesApprovalMode.manual),
    ])
    func theApprovalModeTableMatchesHermes(_ raw: String, _ expected: HermesApprovalMode) {
        #expect(HermesApprovalMode.normalize(raw) == expected, "raw \(raw)")
    }

    /// Through the model the UI actually reads, not just the free function.
    @Test func aPaddedQuotedApprovalModeReadsAsOffFromTheConfig() {
        let config = HermesConfig(yaml: "approvals:\n  mode: \" off \"\n")
        #expect(HermesApprovalMode.normalize(config.approvalModeRawScalar) == .off)
    }
}
