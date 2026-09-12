import Foundation
import Testing
@testable import ScarfCore

// MARK: - Round-5 decision 14: the reader trims what PyYAML trims

/// Scarf's config.yaml reader trimmed with Foundation's `.whitespaces`, which
/// is Unicode `Zs` PLUS tab. PyYAML's scanner trims neither U+00A0 nor any of
/// the other `Zs` characters — they are ordinary CONTENT to it, part of the
/// plain scalar, the key or the flow entry. And `yaml.safe_dump` emits such a
/// value BARE, so a value Hermes itself wrote rendered SHORT in Scarf and the
/// next save persisted the trimmed form over the one the agent was using.
///
/// Every expectation below was taken from the real interpreter first (PyYAML
/// 6.0.3); the oracle is re-run in ``PyYAMLWhitespaceOracleP51Tests`` so a
/// future PyYAML that disagrees fails here rather than drifting silently.
@Suite("P51 · the YAML reader's trim is space and tab")
struct YAMLWhitespaceTrimP51Tests {

    private static let nbsp = "\u{00A0}"
    private static let ideographic = "\u{3000}"
    private static let thin = "\u{2009}"
    private static let ogham = "\u{1680}"

    /// The finding, in the shape the user meets it: Hermes wrote a value
    /// ending in a non-breaking space and Scarf showed it without one.
    @Test("a trailing U+00A0 survives the read")
    func trailingNonBreakingSpaceSurvives() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  model: gpt\(Self.nbsp)\n")
        #expect(parsed.values["agent.model"] == "gpt\(Self.nbsp)")
    }

    @Test("a leading U+00A0 survives the read")
    func leadingNonBreakingSpaceSurvives() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  model: \(Self.nbsp)gpt\n")
        #expect(parsed.values["agent.model"] == "\(Self.nbsp)gpt")
    }

    /// The other `Zs` characters in the same set, each confirmed against
    /// PyYAML: an ideographic space, a thin space and an ogham space mark.
    @Test("the rest of the Zs block survives too", arguments: [
        "\u{3000}", "\u{2009}", "\u{1680}", "\u{202F}", "\u{205F}", "\u{2003}"
    ])
    func otherUnicodeSpacesSurvive(space: String) {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  model: gpt\(space)\n")
        #expect(parsed.values["agent.model"] == "gpt\(space)")
    }

    /// The clamp: a PLAIN space is still trimmed, because PyYAML trims it.
    /// Narrowing the set must not turn into "trim nothing".
    @Test("plain spaces are still trimmed on both sides")
    func plainSpacesStillTrimmed() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  model:   gpt   \n")
        #expect(parsed.values["agent.model"] == "gpt")
    }

    /// The KEY half. PyYAML keeps a U+00A0 inside or around a plain key, so
    /// two keys that differ only by one are two different keys.
    @Test("a U+00A0 inside a key survives")
    func keyKeepsItsNonBreakingSpace() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  mo\(Self.nbsp)del: x\n")
        #expect(parsed.values["agent.mo\(Self.nbsp)del"] == "x")
        #expect(parsed.values["agent.model"] == nil)
    }

    /// The LIST arm — `parseNestedYAML`'s bullet branch had its own trim.
    @Test("a list item keeps its U+00A0")
    func listItemKeepsIt() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  xs:\n    - a\(Self.nbsp)\n    - \(Self.nbsp)b\n")
        #expect(parsed.lists["agent.xs"] == ["a\(Self.nbsp)", "\(Self.nbsp)b"])
    }

    /// The FLOW arms — `parseFlatFlowList` and `splitFlowEntry` each trimmed
    /// separately, and PyYAML keeps the character in both shapes.
    @Test("a flow list entry keeps its U+00A0")
    func flowListEntryKeepsIt() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  xs: [a\(Self.nbsp), \(Self.nbsp)b]\n")
        #expect(parsed.lists["agent.xs"] == ["a\(Self.nbsp)", "\(Self.nbsp)b"])
    }

    @Test("a flow map value keeps its U+00A0")
    func flowMapValueKeepsIt() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  m: {k: v\(Self.ideographic)}\n")
        #expect(parsed.maps["agent.m"]?["k"] == "v\(Self.ideographic)")
    }

    /// The block-form map VALUE, which is the path `agent.reasoning_overrides`
    /// actually reads through.
    @Test("a block map value keeps its U+00A0")
    func blockMapValueKeepsIt() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  m:\n    k: v\(Self.thin)\n")
        #expect(parsed.maps["agent.m"]?["k"] == "v\(Self.thin)")
    }

    /// The round trip the finding is really about: read a value Hermes wrote,
    /// and the value Scarf would write back is byte-identical.
    @Test("the value read back is the value on disk")
    func readIsLossless() {
        let onDisk = "gpt-5\(Self.ogham)"
        let parsed = HermesYAML.parseNestedYAML("agent:\n  model: \(onDisk)\n")
        #expect(parsed.values["agent.model"] == onDisk)
    }
}

/// The narrowed set is a PARSER rule. The value NORMALISERS beside it model a
/// Python `.strip()` — `_bool_token`'s `str(value).strip().lower()`
/// (`gateway/config.py:31` @ `v2026.9.7`), `_normalize_approval_mode`'s
/// `mode.strip().lower()` (`tools/approval_context.py:207`) and
/// `parse_reasoning_effort`'s `str(effort).strip().lower()`
/// (`hermes_constants.py:884`) — and Python's `str.strip()` DOES remove
/// U+00A0. Narrowing those too would have made Scarf claim the host ignores
/// a value it honours, so these tests pin the asymmetry on purpose.
@Suite("P51 · the value normalisers keep the wide trim")
struct NormaliserKeepsWideTrimP51Tests {

    private static let nbsp = "\u{00A0}"
    private static let target = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

    /// `str(value).strip().lower()` sees `true`, so Hermes reads the key as
    /// true and so must Scarf.
    @Test("a boolish scalar padded with U+00A0 is still boolish")
    func boolishStripsLikePython() {
        #expect(HermesYAML.boolishValue("true\(Self.nbsp)") == true)
        #expect(HermesYAML.boolishValue("\(Self.nbsp)false") == false)
    }

    /// `mode.strip().lower()` sees `off`, which IS in `_VALID_MODES`.
    @Test("an approval mode padded with U+00A0 still resolves")
    func approvalModeStripsLikePython() {
        #expect(HermesApprovalMode.normalize("\(Self.nbsp)off\(Self.nbsp)") == .off)
    }

    /// `str(effort).strip().lower()` sees `high`, so the host honours it and
    /// the "isn't supported" notice must stay silent.
    @Test("an effort padded with U+00A0 draws no unsupported notice")
    func effortStripsLikePython() {
        #expect(HermesReasoningEffort.unsupportedLevelNotice(
            for: "high\(Self.nbsp)",
            capabilities: Self.target
        ) == nil)
    }

    /// And the two rules genuinely disagree on the same input — which is the
    /// whole point, and what stops a later refactor unifying them.
    @Test("parser keeps what the normaliser strips")
    func theTwoRulesDisagree() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  reasoning_effort: high\(Self.nbsp)\n")
        #expect(parsed.values["agent.reasoning_effort"] == "high\(Self.nbsp)")
        #expect(HermesYAML.normalizedScalar("high\(Self.nbsp)") == "high")
    }
}

/// The oracle, run for real. PyYAML 6.0.3 was the source of every expectation
/// in ``YAMLWhitespaceTrimP51Tests``; this re-derives them from the installed
/// interpreter so a disagreement is a FAILURE rather than a silent drift.
///
/// P41c's rule on the shape: the `withKnownIssue` guard wraps only the thing
/// that can be ABSENT (the interpreter), never the thing that can be WRONG —
/// so the availability probe is its own named test and the assertions below
/// run unguarded, returning early only when python is genuinely missing.
@Suite("P51 · PyYAML agrees about Unicode spaces")
struct PyYAMLWhitespaceOracleP51Tests {

    /// Reports rather than passes vacuously when the interpreter is absent.
    @Test("the PyYAML lane is present")
    func laneIsPresent() {
        withKnownIssue("python3 with PyYAML is not installed here", isIntermittent: true) {
            #expect(BotModeFixupTests.pyYAMLLoad("a: 1\n") != nil)
        }
    }

    /// Every `Zs` character this parser used to eat, loaded for real and
    /// asserted to come back INTACT.
    @Test("PyYAML keeps every Zs character Scarf used to trim", arguments: [
        "\u{00A0}", "\u{3000}", "\u{2009}", "\u{1680}", "\u{202F}", "\u{205F}", "\u{2003}"
    ])
    func pyYAMLKeepsUnicodeSpaces(space: String) throws {
        let yaml = "agent:\n  model: gpt\(space)\n"
        guard let loaded = BotModeFixupTests.pyYAMLLoad(yaml) else { return }
        #expect(!loaded.hasPrefix("ERROR:"), "PyYAML refused the document: \(loaded)")
        // `json.dumps` escapes non-ASCII, so the character comes back as its
        // `\uXXXX` form — which is still PROOF the loaded scalar carries it,
        // and is what has to be matched rather than the literal.
        let scalar = try #require(space.unicodeScalars.first)
        let escaped = String(format: "gpt\\u%04x", scalar.value)
        #expect(loaded == "{\"agent\": {\"model\": \"\(escaped)\"}}",
                "PyYAML did not keep U+\(String(format: "%04X", scalar.value)): \(loaded)")
        // And Scarf's own reader agrees with it, character for character.
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(try #require(parsed.values["agent.model"]) == "gpt\(space)")
    }

    /// The clamp, through the interpreter: PyYAML DOES drop a plain trailing
    /// space, so the narrowed set must not stop trimming that one.
    @Test("PyYAML drops a plain trailing space and so does Scarf")
    func pyYAMLDropsPlainSpace() throws {
        let yaml = "agent:\n  model: gpt   \n"
        guard let loaded = BotModeFixupTests.pyYAMLLoad(yaml) else { return }
        #expect(loaded == #"{"agent": {"model": "gpt"}}"#)
        #expect(HermesYAML.parseNestedYAML(yaml).values["agent.model"] == "gpt")
    }

    /// The reason TAB stays in the narrowed set although PyYAML does not
    /// trim one: a tab in either position is a `ScannerError`, i.e. a
    /// document Hermes discards WHOLE (`gateway/config.py:775-791` @
    /// `v2026.9.7`), so trimming it decides nothing.
    @Test("a tab around the value indicator is a PyYAML error, not a trim")
    func tabIsAnErrorNotATrim() {
        for yaml in ["agent:\n  model: gpt\t\n", "agent:\n  model:\tgpt\n"] {
            guard let loaded = BotModeFixupTests.pyYAMLLoad(yaml) else { return }
            #expect(loaded.hasPrefix("ERROR:"), "expected a ScannerError, got \(loaded)")
        }
    }
}

// MARK: - Discord `allow_any_attachment` is a WINDOW, not a floor

/// `discord.allow_any_attachment` was live from v2026.5.28 (0.15.0) and went
/// dead at v2026.7.1 (0.18.0), when the Discord adapter stopped CALLING its
/// own `_discord_allow_any_attachment` getter — the getter itself lingered to
/// v2026.8.31 and is gone at v2026.9.7, where the key survives only as a
/// schema default (`hermes_cli/config_defaults.py:1448`) and the tag's docs
/// call it a no-op (`website/docs/user-guide/messaging/discord.md:703`).
///
/// Counted by CALL SITE: grepping the symbol would have put the window's end
/// three releases late.
@Suite("P51 · the Discord attachment flag is a version window")
struct DiscordAllowAnyAttachmentWindowP51Tests {

    private func caps(_ line: String) -> HermesCapabilities {
        HermesCapabilities.parseLine(line)
    }

    @Test("off below the arrival floor")
    func offBeforeArrival() {
        #expect(caps("Hermes Agent v0.14.0").hasDiscordAllowAnyAttachment == false)
    }

    @Test("on across the window", arguments: ["v0.15.0", "v0.16.0", "v0.17.0", "v0.17.9"])
    func onInsideWindow(version: String) {
        #expect(caps("Hermes Agent \(version)").hasDiscordAllowAnyAttachment == true)
    }

    /// The half a plain `atLeastSemver` would have got wrong.
    @Test("off from v0.18.0 onward", arguments: ["v0.18.0", "v0.20.6", "v0.21.1"])
    func offAfterWindow(version: String) {
        #expect(caps("Hermes Agent \(version)").hasDiscordAllowAnyAttachment == false)
    }

    /// An unanswered version probe renders as the pre-flag host, per C1.
    @Test("an empty capability set leaves the row hidden")
    func emptyIsOff() {
        #expect(HermesCapabilities.empty.hasDiscordAllowAnyAttachment == false)
    }
}

// MARK: - Mattermost `require_mention`: config wins, `.env` is the fallback

/// The adapter reads `_extra_or_env("require_mention",
/// "MATTERMOST_REQUIRE_MENTION", "true")`
/// (`plugins/platforms/mattermost/adapter.py:504`, helper `:491-494` @
/// `v2026.9.7`): config.yaml's value WINS and `.env` answers only for an
/// ABSENT config key. `MattermostSettings.requireMention` collapses absence
/// into the resolved `true`, which is right for a display and wrong for
/// deciding whether to fall back — hence the raw-beside-normalised field.
@Suite("P51 · Mattermost require_mention presence")
struct MattermostRequireMentionPresenceP51Tests {

    private func settings(_ yaml: String) -> MattermostSettings {
        HermesConfig(yaml: yaml).mattermost
    }

    @Test("an absent key is nil, not false")
    func absentIsNil() {
        let s = settings("mattermost:\n  reply_mode: off\n")
        #expect(s.requireMentionIsSet == nil)
        // The resolved view is unchanged — this must not move.
        #expect(s.requireMention == true)
    }

    @Test("an explicit false is false, not absent")
    func explicitFalseIsSet() {
        let s = settings("mattermost:\n  require_mention: false\n")
        #expect(s.requireMentionIsSet == false)
        #expect(s.requireMention == false)
    }

    @Test("an explicit true is set too")
    func explicitTrueIsSet() {
        let s = settings("mattermost:\n  require_mention: true\n")
        #expect(s.requireMentionIsSet == true)
        #expect(s.requireMention == true)
    }

    /// The distinction the fallback rests on: `false` and absent resolve the
    /// same way through `requireMention` and differently through the new
    /// field. Without this they would be one state and the `.env` half would
    /// be unreachable for a user who had explicitly turned mentions off.
    @Test("explicit false and absent are distinguishable")
    func falseAndAbsentDiffer() {
        #expect(settings("mattermost:\n  require_mention: false\n").requireMentionIsSet
                != settings("mattermost: {}\n").requireMentionIsSet)
    }
}
