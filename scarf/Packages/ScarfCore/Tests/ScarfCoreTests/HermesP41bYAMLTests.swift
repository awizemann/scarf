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
        ("'quoted':v", "'quoted'", "v"),
    ])
    func blockKeySpanSplitsTheseShapes(
        _ line: String, _ expectedKey: String, _ expectedValue: String
    ) throws {
        let span = try #require(HermesYAML.blockKeySpan(in: line), "no split for \(line)")
        #expect(String(span.key) == expectedKey)
        #expect(String(span.afterColon).trimmingCharacters(in: .whitespaces) == expectedValue)
    }

    /// And the shapes that are not a `key: value` row at all.
    @Test(arguments: ["'unterminated: v", "\"trailing backslash\\", "novaluehere"])
    func blockKeySpanRefusesANonRow(_ line: String) {
        #expect(HermesYAML.blockKeySpan(in: line) == nil)
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
        #expect(YAMLScalar.quoteIfNeeded(colonKey(1022)).count == 1024)
        #expect(YAMLScalar.exceedsSimpleKeyLimit(colonKey(1022)) == false)
        #expect(YAMLScalar.exceedsSimpleKeyLimit(colonKey(1023)))
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
