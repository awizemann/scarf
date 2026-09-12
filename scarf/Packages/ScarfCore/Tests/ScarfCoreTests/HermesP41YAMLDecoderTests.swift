import Testing
import Foundation
@testable import ScarfCore

/// P41 — round-4 decision 10 (the per-key opt-in that makes `YAMLScalar`'s
/// "one decoder" claim true) and the MED (a QUOTED `approvals.mode`).
@Suite("P41 YAML decoders")
struct HermesP41YAMLDecoderTests {

    // MARK: - Decision 10: the blocks Scarf writes decode through `unquote`

    private static let caps = HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")

    /// The round trip the finding says was broken: a reasoning-override
    /// pattern carrying a backslash is emitted through
    /// `YAMLScalar.quoteIfNeeded` (which escapes `\\`) and was read back
    /// through `HermesYAML.stripYAMLQuotes`, which hands a double-quoted
    /// BODY back verbatim — so it grew one `\` per save.
    @Test(arguments: [
        "a\\b", "a\u{1B}b", "a\tb", "a\u{2029}b", "quote\"inside",
    ])
    func aReasoningOverridePatternRoundTripsThroughTheWriterAndTheParser(
        _ pattern: String
    ) throws {
        let written = try #require(PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n  max_turns: 10\n",
            pairs: [(key: pattern, value: "high")],
            capabilities: Self.caps
        ))
        let parsed = HermesYAML.parseNestedYAML(written)
        let map = try #require(parsed.maps["agent.reasoning_overrides"])
        #expect(map[pattern] == "high", "the KEY did not survive: \(map)")

        // And through the model the UI actually reads.
        #expect(HermesConfig(yaml: written).reasoningOverrides[pattern] == "high")

        // Idempotence: a second save of what was read back must not grow a
        // `\` — the exact defect P32 found in `ProfileRoutesWriter`.
        let again = try #require(PowerSettingsWriter.setReasoningOverrides(
            in: written,
            pairs: [(key: pattern, value: "high")],
            capabilities: Self.caps
        ))
        #expect(HermesConfig(yaml: again).reasoningOverrides[pattern] == "high")
    }

    /// The VALUE half of the same block. Hermes validates the effort against
    /// its own vocabulary, so a hand-edited alias is the realistic carrier —
    /// this pins the decode, not the vocabulary.
    @Test func aReasoningOverrideValueIsDecodedThroughUnquote() throws {
        let yaml = """
        agent:
          reasoning_overrides:
            "claude-opus-4.5": "a\\\\b"
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.maps["agent.reasoning_overrides"]?["claude-opus-4.5"] == "a\\b")
    }

    /// `model_catalog.excluded_providers` is the list half.
    @Test(arguments: ["a\\b", "a\u{1B}b", "a\tb"])
    func anExcludedProviderRoundTrips(_ provider: String) throws {
        let written = try #require(PowerSettingsWriter.setExcludedProviders(
            in: "model_catalog:\n  refresh_hours: 24\n",
            providers: [provider],
            capabilities: Self.caps
        ))
        #expect(HermesConfig(yaml: written).excludedProviders == [provider])
    }

    /// **The clamp that makes the opt-in a per-KEY change and not a
    /// widening.** `HermesYAML.stripYAMLQuotes` reads arbitrary
    /// HERMES-written values, where `\n` inside double quotes is two
    /// characters the file means literally. An un-opted key must read
    /// exactly as it did before P41.
    @Test func aHermesWrittenQuotedScalarInAnUnOptedKeyIsUnchanged() {
        let yaml = """
        agent:
          system_prompt: "a\\nb"
        gateway:
          multiplex_profile_allowlist:
            - "a\\nb"
        terminal:
          docker_env:
            "K": "a\\nb"
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        let verbatim = "a\\nb"  // backslash, n, b — NOT a newline
        #expect(parsed.values["agent.system_prompt"] == "\"a\\nb\"",
                "`values` is the verbatim parse and must not decode at all")
        #expect(parsed.maps["agent"]?["system_prompt"] == verbatim)
        #expect(parsed.lists["gateway.multiplex_profile_allowlist"] == [verbatim],
                "the multiplex allowlist is Hermes-written and is NOT opted in")
        #expect(parsed.maps["terminal.docker_env"]?["K"] == verbatim)

        // Same shape under an OPTED key decodes the escape — which is the
        // difference the opt-in exists to make.
        let opted = HermesYAML.parseNestedYAML("""
        agent:
          reasoning_overrides:
            "K": "a\\nb"
        """)
        #expect(opted.maps["agent.reasoning_overrides"]?["K"] == "a\nb")
    }

    /// The opt-in sets themselves, so a future edit that adds a path has to
    /// say so here — and so the multiplex exclusion is a decision on the
    /// record rather than an omission.
    @Test func theOptInIsExactlyTheTwoBlocksScarfWrites() {
        #expect(HermesYAML.scarfWrittenMapPaths == ["agent.reasoning_overrides"])
        #expect(HermesYAML.scarfWrittenListPaths == ["model_catalog.excluded_providers"])
    }

    // MARK: - MED: a QUOTED `approvals.mode` is a string to Hermes

    /// `_normalize_approval_mode` (`tools/approval_context.py:198-214` @
    /// `v2026.9.7`, `_VALID_MODES` at `:195`), re-derived per spelling.
    ///
    /// BARE: PyYAML's YAML 1.1 resolver makes `yes`/`true`/`on` the bool
    /// `True` → `"manual"`, and `no`/`false`/`off` the bool `False` →
    /// `"off"`; `0`/`1` are ints, which match neither `isinstance` arm →
    /// `"manual"`.
    ///
    /// QUOTED: every one of the eight is a `str`. Only `"off"` is in
    /// `_VALID_MODES`, so it is the one quoted spelling that is not
    /// `"manual"` — the other seven warn and fall through to `:214`.
    @Test(arguments: [
        // (scalar, bare answer, quoted answer)
        ("yes", HermesApprovalMode.manual, HermesApprovalMode.manual),
        ("no", .off, .manual),
        ("true", .manual, .manual),
        ("false", .off, .manual),
        ("on", .manual, .manual),
        ("off", .off, .off),
        ("0", .manual, .manual),
        ("1", .manual, .manual),
    ])
    func theApprovalModeTableMatchesHermes(
        _ row: (scalar: String, bare: HermesApprovalMode, quoted: HermesApprovalMode)
    ) {
        #expect(HermesApprovalMode.normalize(row.scalar) == row.bare,
                "bare `\(row.scalar)`")
        #expect(HermesApprovalMode.normalize("\"\(row.scalar)\"") == row.quoted,
                "double-quoted `\(row.scalar)`")
        #expect(HermesApprovalMode.normalize("'\(row.scalar)'") == row.quoted,
                "single-quoted `\(row.scalar)`")
    }

    /// End to end through the parse, which is where the defect was visible:
    /// the picker rendered "Never ask" on a host enforcing `manual`.
    @Test func aQuotedFalsyApprovalModeReadsAsManualThroughTheConfig() {
        #expect(HermesConfig(yaml: "approvals:\n  mode: \"no\"\n").storedApprovalMode == .manual)
        #expect(HermesConfig(yaml: "approvals:\n  mode: \"false\"\n").storedApprovalMode == .manual)
        #expect(HermesConfig(yaml: "approvals:\n  mode: 'no'\n").storedApprovalMode == .manual)
        // The bare spellings still read as `off` — the fix must not have
        // simply deleted the bool arm.
        #expect(HermesConfig(yaml: "approvals:\n  mode: no\n").storedApprovalMode == .off)
        #expect(HermesConfig(yaml: "approvals:\n  mode: false\n").storedApprovalMode == .off)
        // And a quoted `"off"` is still the mode, because it is the one
        // falsy spelling that is also a `_VALID_MODES` member.
        #expect(HermesConfig(yaml: "approvals:\n  mode: \"off\"\n").storedApprovalMode == .off)
    }

    /// Absence, the inline comment, and the ordinary members are unchanged.
    @Test func theUnchangedApprovalModeCasesStayUnchanged() {
        #expect(HermesConfig(yaml: "agent:\n  max_turns: 10\n").storedApprovalMode == nil)
        #expect(HermesConfig(yaml: "approvals:\n  mode: \"\"\n").storedApprovalMode == nil)
        #expect(HermesConfig(yaml: "approvals:\n  mode: smart  # guardian\n")
                .storedApprovalMode == .smart)
        #expect(HermesConfig(yaml: "approvals:\n  mode: \" Manual \"\n")
                .storedApprovalMode == .manual)
        #expect(HermesConfig(yaml: "approvals:\n  mode: auto\n").storedApprovalMode == .manual)
    }
}
