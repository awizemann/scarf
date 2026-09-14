import Testing
import Foundation
@testable import ScarfCore

/// Release blocker 1 — `GatewayConfigWriter` corrupted config.yaml whenever
/// the key it was asked to rewrite carried a BLOCK SCALAR value.
///
/// `keyLineKind` classified `allowed_channels: |` as `.inlineValue`, so
/// `locateBlock` returned the one-line range `i...i` and `setListChecked` /
/// `setMapChecked` replaced the HEADER ONLY. The scalar's body lines stayed
/// behind, now more-indented than a plain `key:` row and following a bullet
/// sequence — which PyYAML rejects, and `load_config`
/// (`gateway/config.py:775-791` @ `v2026.9.7`) answers by discarding the
/// WHOLE config.yaml layer: every unrelated setting in the file silently
/// reverts to the `.env` defaults.
///
/// The oracle is real PyYAML 6.0.3 (`BotModeFixupTests.pyYAMLLoad`), not
/// Scarf's own reader — the failure mode is precisely "Scarf's reader is
/// happy and PyYAML is not". When python3/PyYAML is unavailable these skip
/// rather than pass vacuously; the byte-exact assertions still run.
@Suite struct HermesReleaseBlockerYAMLTests {

    private static let v021 = HermesCapabilities(
        versionLine: "hermes 0.21.1",
        semver: HermesCapabilities.SemVer(major: 0, minor: 21, patch: 1),
        dateVersion: nil
    )

    /// The reviewer's input, verbatim.
    private static let reviewerInput = """
    slack:
      allowed_channels: |
        old
      reply_to_mode: first

    """

    /// Assert PyYAML loads `yaml` and the decoded document equals `expected`
    /// (compared as `json.dumps(..., sort_keys=True)`). Skips when python is
    /// absent; FAILS — never skips — when PyYAML refuses the document.
    private func expectPyYAML(
        _ yaml: String,
        loadsAs expected: String,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let loaded = BotModeFixupTests.pyYAMLLoad(yaml) else { return }
        if loaded.hasPrefix("ERROR:") {
            Issue.record(
                "\(label): PyYAML refused the file Scarf wrote: \(loaded)\n---\n\(yaml)",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(loaded == expected, "\(label)\n---\n\(yaml)", sourceLocation: sourceLocation)
    }

    // MARK: - setListChecked over a block scalar

    /// Byte-exact output for the reviewer's input. Derived from the oracle:
    /// `yaml.safe_load` of the expected text returns
    /// `{"slack": {"allowed_channels": ["c1", "c2"], "reply_to_mode": "first"}}`
    /// under PyYAML 6.0.3, while `yaml.safe_load` of the PRE-FIX output
    /// (`slack:\n  allowed_channels:\n  - c1\n  - c2\n    old\n  reply_to_mode: first\n`)
    /// raises
    /// `yaml.parser.ParserError: while parsing a block collection … expected <block end>, but found '<scalar>'`.
    @Test("setListChecked replaces a `|` block scalar body along with its header")
    func listOverLiteralBlockScalar() throws {
        let out = GatewayConfigWriter.setListChecked(
            in: Self.reviewerInput,
            platform: "slack",
            key: "allowed_channels",
            items: ["c1", "c2"]
        ).appliedText(orUnchanged: Self.reviewerInput)

        let text = try #require(out)
        #expect(text == """
        slack:
          allowed_channels:
            - c1
            - c2
          reply_to_mode: first

        """)
        // The body line is GONE, not orphaned below the bullets.
        #expect(!text.contains("old"))
        expectPyYAML(
            text,
            loadsAs: #"{"slack": {"allowed_channels": ["c1", "c2"], "reply_to_mode": "first"}}"#,
            "literal block scalar"
        )
    }

    /// Every block-scalar header spelling `HermesYAML.blockScalarHeader`
    /// recognises: folded, both chomping indicators, an explicit indentation
    /// indicator, and a trailing comment.
    @Test(
        "every block-scalar header spelling is replaced with its body",
        arguments: ["|", ">", "|-", "|+", ">-", ">+", "|2", "| # keep"]
    )
    func everyBlockScalarHeaderSpelling(header: String) throws {
        let input = """
        slack:
          allowed_channels: \(header)
            old one
            old two
          reply_to_mode: first

        """
        let out = GatewayConfigWriter.setListChecked(
            in: input,
            platform: "slack",
            key: "allowed_channels",
            items: ["c1"]
        ).appliedText(orUnchanged: input)
        let text = try #require(out)
        #expect(!text.contains("old one"), "header \(header) orphaned its body:\n\(text)")
        #expect(!text.contains("old two"), "header \(header) orphaned its body:\n\(text)")
        expectPyYAML(
            text,
            loadsAs: #"{"slack": {"allowed_channels": ["c1"], "reply_to_mode": "first"}}"#,
            "header \(header)"
        )
    }

    /// A body line that LOOKS like a comment is block-scalar TEXT, not a
    /// comment — preserving it as one used to leave a stray deep-indented
    /// line behind the replacement. Blank interior lines belong to the body
    /// too, so the walk must not stop at them.
    @Test("a `#`-looking or blank body line inside the scalar is not preserved")
    func hashLookingBodyLineIsNotAComment() throws {
        let input = """
        slack:
          allowed_channels: |
            # not a comment

            still body
          reply_to_mode: first

        """
        let out = GatewayConfigWriter.setListChecked(
            in: input,
            platform: "slack",
            key: "allowed_channels",
            items: ["c1"]
        ).appliedText(orUnchanged: input)
        let text = try #require(out)
        #expect(!text.contains("not a comment"))
        #expect(!text.contains("still body"))
        expectPyYAML(
            text,
            loadsAs: #"{"slack": {"allowed_channels": ["c1"], "reply_to_mode": "first"}}"#,
            "hash-looking body"
        )
    }

    /// Emptying the list DELETES a block-scalar key outright — the header and
    /// the body, not the header alone.
    @Test("clearing the list removes the block scalar's body too")
    func clearingRemovesTheBody() throws {
        let out = GatewayConfigWriter.setListChecked(
            in: Self.reviewerInput,
            platform: "slack",
            key: "allowed_channels",
            items: []
        ).appliedText(orUnchanged: Self.reviewerInput)
        let text = try #require(out)
        #expect(!text.contains("allowed_channels"))
        #expect(!text.contains("old"))
        expectPyYAML(text, loadsAs: #"{"slack": {"reply_to_mode": "first"}}"#, "cleared")
    }

    // MARK: - setMapChecked over a block scalar

    @Test("setMapChecked replaces a block scalar body along with its header")
    func mapOverBlockScalar() throws {
        let input = """
        agent:
          reasoning_overrides: |
            old body
          model: gpt-5

        """
        let out = GatewayConfigWriter.setMapChecked(
            in: input,
            section: "agent",
            key: "reasoning_overrides",
            pairs: [(key: "claude-*", value: "high")]
        ).appliedText(orUnchanged: input)
        let text = try #require(out)
        #expect(!text.contains("old body"))
        expectPyYAML(
            text,
            loadsAs: #"{"agent": {"model": "gpt-5", "reasoning_overrides": {"claude-*": "high"}}}"#,
            "setMapChecked"
        )
    }

    // MARK: - An ordinary inline scalar is still a one-line block

    /// The regression guard for the fix itself: `key: value` and `key: [a]`
    /// must keep the `.inlineValue` single-line behaviour, and `key:` the
    /// plain block-header behaviour with its comments preserved.
    @Test("a plain inline value is untouched by the new classification")
    func plainInlineValueUnchanged() {
        let input = """
        slack:
          allowed_channels: [a, b]
          reply_to_mode: first

        """
        let out = GatewayConfigWriter.setListChecked(
            in: input,
            platform: "slack",
            key: "allowed_channels",
            items: ["c1"]
        ).appliedText(orUnchanged: input)
        #expect(out == """
        slack:
          allowed_channels:
            - c1
          reply_to_mode: first

        """)
    }

    @Test("a plain block header still preserves its interior comments")
    func blockHeaderCommentsPreserved() throws {
        let input = """
        slack:
          allowed_channels:
            # keep me
            - old
          reply_to_mode: first

        """
        let out = GatewayConfigWriter.setListChecked(
            in: input,
            platform: "slack",
            key: "allowed_channels",
            items: ["c1"]
        ).appliedText(orUnchanged: input)
        let text = try #require(out)
        #expect(text.contains("# keep me"))
    }

    // MARK: - Sibling writers (one test each)

    /// `PowerSettingsWriter` delegates to `GatewayConfigWriter`, so it CARRIED
    /// the same defect and is fixed by the same change.
    @Test("PowerSettingsWriter.setExcludedProviders survives a block scalar")
    func powerSettingsWriterBlockScalar() throws {
        let input = """
        model_catalog:
          excluded_providers: |
            old
          other: keep

        """
        let out = PowerSettingsWriter.setExcludedProviders(
            in: input,
            providers: ["xai"],
            capabilities: Self.v021
        )
        let text = try #require(out)
        #expect(!text.contains("old"))
        expectPyYAML(
            text,
            loadsAs: #"{"model_catalog": {"excluded_providers": ["xai"], "other": "keep"}}"#,
            "PowerSettingsWriter"
        )
    }

    /// `ProfileRoutesWriter` does NOT carry the defect: `ProfileRoutesYAML.locate`
    /// returns nil for any non-`[` scalar after the colon (`:190-193`), so the
    /// block-scalar header is never located and its body is never orphaned.
    /// It falls through to the key-missing path, which appends — a DUPLICATE
    /// key PyYAML resolves last-wins, i.e. a no-op save, not a corrupt file.
    /// That duplicate-section behaviour is a separate (MED) finding on
    /// t-d1d324ff; this test pins only that the file still LOADS.
    @Test("ProfileRoutesWriter leaves a block-scalar profile_routes loadable")
    func profileRoutesWriterBlockScalar() {
        let input = """
        profile_routes: |
          old body
        gateway:
          multiplex_profiles: true

        """
        let route = HermesProfileRoute(name: "r", platform: "slack", profile: "p")
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: input,
            routes: [route],
            location: .topLevel,
            capabilities: Self.v021
        )
        guard let text = out else { return }
        guard let loaded = BotModeFixupTests.pyYAMLLoad(text) else { return }
        #expect(!loaded.hasPrefix("ERROR:"), "PyYAML refused:\n\(text)")
    }
}
