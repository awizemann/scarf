import Foundation
import Testing
@testable import ScarfCore

// MARK: - P51b finding 1: mattermost's `require_mention` read and write move together

/// `require_mention` is a `_SHARED_KEYS` member for every platform
/// (`gateway/config_loader.py:197-213` @ `v2026.9.7`), so Hermes bridges it
/// into `extra` from whichever section `platform_section` picks (`:171-180`)
/// — a top-level `mattermost:` block if there is one, otherwise the nested
/// `platforms.mattermost` / `gateway.platforms.mattermost` block.
///
/// P51 made `MattermostSetupViewModel` a config WRITER of this key and left
/// it on the bare top-level spelling, with a reader (`HermesConfig+YAML`) that
/// matched. The pair was internally consistent and externally wrong: on a
/// nested-only host the bare write CREATES the top-level block, which
/// `platform_section` then takes as the bridge source, so every
/// `platforms.mattermost.<shared key>` beside it stops reaching `extra` —
/// P46b's "leaving a write on its bare spelling is not neutral just because
/// its reader is", and the same remedy (option (b)): move the READER onto
/// `sharedPlatformScalar` and let the write onto `bridgeResolvedKeys`, so the
/// value lands wherever the bridge source already is and creates nothing.
@Suite("P51b · mattermost require_mention resolves the bridge")
struct MattermostRequireMentionBridgeP51bTests {

    private func settings(_ yaml: String) -> MattermostSettings {
        HermesConfig(yaml: yaml).mattermost
    }

    private static let nestedOnly = """
    platforms:
      mattermost:
        require_mention: false
        reply_to_mode: first
    """

    /// The read half. Without the fix this is `nil` / `true`: the flat
    /// `values["mattermost.require_mention"]` lookup cannot see a nested key.
    @Test("a nested-only config's value is read")
    func nestedValueIsRead() {
        let s = settings(Self.nestedOnly + "\n")
        #expect(s.requireMentionIsSet == false)
        #expect(s.requireMention == false)
    }

    /// The write half. Without the pair on `bridgeResolvedKeys`,
    /// `split(key:)` returns `nil` and the key stays bare — creating the
    /// top-level block.
    @Test("the write lands on the bridge source, not a fresh top-level block")
    func writeMovesOntoTheBridgeSource() {
        let key = "mattermost.require_mention"
        #expect(HermesPlatformSharedKeys.split(key: key) != nil)
        let resolved = HermesPlatformSharedKeys.resolved(
            [key: "false"],
            configText: Self.nestedOnly + "\n"
        )
        #expect(resolved["platforms.mattermost.require_mention"] == "false",
                "the toggle still creates a top-level mattermost block: \(resolved)")
        #expect(resolved[key] == nil)
    }

    /// A top-level block already present stays the target — the bridge source
    /// is whatever Hermes would pick, not a preference for nesting.
    @Test("a top-level block keeps the bare spelling")
    func topLevelBlockKeepsTheBareSpelling() {
        let resolved = HermesPlatformSharedKeys.resolved(
            ["platforms.mattermost.require_mention": "false"],
            configText: "mattermost:\n  reply_mode: off\n"
        )
        #expect(resolved["mattermost.require_mention"] == "false")
        #expect(resolved["platforms.mattermost.require_mention"] == nil)
    }

    /// The whole point, end to end — and the damage the bare write does.
    /// The host is nested-only and carries a SIBLING shared key
    /// (`reply_in_thread`). Applying the resolved batch must leave both
    /// readable. Without the fix the toggle lands at bare
    /// `mattermost.require_mention`, which creates the top-level block
    /// `platform_section` then bridges from — and the sibling, still nested,
    /// stops reaching `extra` (`gateway/config_loader.py:171-180`,
    /// `:249-283` @ `v2026.9.7`).
    @Test("the write does not un-bridge the nested sibling beside it")
    func theSiblingSurvivesTheWrite() throws {
        let before = """
        platforms:
          mattermost:
            reply_in_thread: true
            reply_to_mode: first
        """
        let resolved = HermesPlatformSharedKeys.resolved(
            ["mattermost.require_mention": "false"],
            configText: before + "\n"
        )
        #expect(resolved.count == 1)
        let target = try #require(resolved.keys.first)
        // What `hermes config set <target> false` leaves on disk.
        let after = target.hasPrefix("platforms.")
            ? before + "\n    require_mention: false\n"
            : before + "\nmattermost:\n  require_mention: false\n"
        #expect(settings(after).requireMentionIsSet == false,
                "the value written at \(target) does not read back")
        // Hermes's own bridge source after the write.
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
                    platform: "mattermost", configText: after) == "platforms.mattermost",
                "the write created a top-level block and un-bridged platforms.mattermost.*")
    }
}

// MARK: - P51b finding 3: decision 16's rule is a function, not a grep

/// P51's `ReasoningOverridesSection.addNew` kept the replace-on-add rule
/// inline and the test beside it re-implemented the rule privately under a
/// comment calling itself "the function the view now uses". A
/// re-implementation cannot fail when the view drifts, so decision 16's only
/// real signal was a `caseInsensitiveCompare` source grep — a pin on one
/// spelling of the bug rather than on the rule. The rule is
/// `HermesReasoningEffort.overridesAfterAdding` now, and the view calls it.
@Suite("P51b · the override dedupe rule is exercised, not re-implemented")
struct ReasoningOverrideRuleIsExtractedP51bTests {

    private func keys(_ pattern: String, _ existing: [String]) -> [String] {
        HermesReasoningEffort.overridesAfterAdding(
            pattern: pattern,
            effort: "low",
            to: existing.map { (key: $0, value: "high") }
        ).map(\.key)
    }

    @Test("a different casing does not evict the existing row")
    func differentCasingCoexists() {
        #expect(keys("Claude-Opus", ["claude-opus"]) == ["claude-opus", "Claude-Opus"])
    }

    @Test("an exact match is replaced, not duplicated")
    func exactMatchReplaces() {
        #expect(keys("claude-opus", ["claude-opus"]) == ["claude-opus"])
        // …and the new EFFORT wins, which is what replace-on-add means.
        #expect(HermesReasoningEffort.overridesAfterAdding(
            pattern: "claude-opus", effort: "low", to: [(key: "claude-opus", value: "high")]
        ).map(\.value) == ["low"])
    }

    @Test("unrelated rows keep their order")
    func unrelatedRowsAreUntouched() {
        #expect(keys("c", ["a", "b"]) == ["a", "b", "c"])
    }

    /// The source pin stays as the belt: the view must not reintroduce the
    /// case-insensitive comparison, and it must not grow a second inline copy
    /// of the rule.
    @Test("AgentTab calls the rule rather than restating it")
    func theViewCallsTheExtractedRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("scarf/scarf/Features/Settings/Views/Tabs/AgentTab.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("caseInsensitiveCompare"))
        #expect(source.contains("HermesReasoningEffort.overridesAfterAdding("))
        #expect(!source.contains("pairs.append((key: pattern, value: newEffort))"),
                "AgentTab grew a second inline copy of decision 16's rule")
    }
}

// MARK: - P51b finding 7 (disagreed with): the override-pattern trim stays WIDE

/// The review asked for `setReasoningOverrides`'s `.whitespaces` trim to be
/// narrowed to decision 14's space+tab set "for consistency". It is not the
/// same question. Decision 14 narrowed a PARSER, because PyYAML keeps a `Zs`
/// character as scalar content and Scarf was reading Hermes's own values
/// short. This is a writer-side cleanup of a field the USER typed, and
/// Hermes compares an override key EXACTLY — `variant in overrides`
/// (`hermes_constants.py:929-941` @ `v2026.9.7`) over
/// `_canonical_model_variants` (`:892-926`), which recovers dots↔dashes and
/// provider prefixes but never strips. So an untrimmed trailing U+00A0 is
/// written quoted and matches no model for the life of the entry: narrowing
/// the trim would CREATE dead overrides. "Exact" in decision 16 is about
/// case, not whitespace.
@Suite("P51b · the override pattern's writer-side trim stays wide")
struct OverridePatternTrimStaysWideP51bTests {

    private static let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

    private func written(_ pattern: String) -> String? {
        PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n  model: gpt\n",
            pairs: [(key: pattern, value: "high")],
            capabilities: Self.caps
        )
    }

    @Test("a pasted U+00A0 is trimmed off the pattern, not quoted into the file")
    func nbspIsTrimmed() throws {
        let yaml = try #require(written("claude-opus\u{00A0}"))
        #expect(yaml.contains("claude-opus"))
        #expect(!yaml.contains("\u{00A0}"),
                "the pattern kept a U+00A0 Hermes will never match: \(yaml)")
    }

    @Test("an ordinary trailing space is trimmed too")
    func spaceIsTrimmed() throws {
        let yaml = try #require(written("claude-opus "))
        #expect(!yaml.contains("\"claude-opus \""))
    }

    /// The clamp on the other side: case is still preserved exactly.
    @Test("case is preserved")
    func caseIsPreserved() throws {
        let yaml = try #require(written("Claude-Opus"))
        #expect(yaml.contains("Claude-Opus"))
    }
}
