import Testing
import Foundation
@testable import ScarfCore

/// P38 item 8 — `parseNestedYAML`'s last-wins purge.
///
/// PyYAML replaces a duplicated mapping outright. P19 made the LISTS
/// last-wins, P32 extended the purge to descendant `values` / `maps`, and P37
/// scoped it to a path that had actually been written before. What was still
/// wrong:
///
/// * the purge dropped the earlier block's DESCENDANTS but not the block's own
///   `values[path]` / `maps[path]`, so `sharedPlatformScalar`'s
///   `maps[section]?[key]` fallback still read the FIRST `slack:` block on a
///   config with two of them;
/// * the descendant sweep ate a flat dotted SIBLING on the re-open, though
///   PyYAML keeps `gateway.enabled: true` as an independent top-level key.
///
/// Both expectations were probed against python3 + PyYAML:
/// `{"gateway": {"port": 2}, "gateway.enabled": true}` and
/// `{"slack": {"bot_name": "x"}}`.
@Suite struct HermesP38YAMLPurgeTests {

    // MARK: - maps[path] itself is purged

    private static let twoSlackBlocks = """
        slack:
          require_mention: true
          bot_token: first
        slack:
          bot_name: second
        """

    @Test("the second block's map replaces the first's, key by key")
    func theEarlierBlocksOwnMapIsPurged() {
        let parsed = HermesYAML.parseNestedYAML(Self.twoSlackBlocks)
        // PyYAML: {"slack": {"bot_name": "second"}} — nothing else survives.
        #expect(parsed.maps["slack"]?["bot_name"] == "second")
        #expect(parsed.maps["slack"]?["require_mention"] == nil)
        #expect(parsed.maps["slack"]?["bot_token"] == nil)
        #expect(parsed.values["slack.require_mention"] == nil)
        #expect(parsed.values["slack.bot_token"] == nil)
    }

    /// The consumer that made this a real defect: `sharedPlatformScalar`
    /// falls back to `maps[section]?[key]`, so the stale first-block entry
    /// was rendered as the host's `require_mention`.
    @Test("sharedPlatformScalar no longer reads the first block's value")
    func sharedPlatformScalarReadsTheSurvivingBlock() {
        // `sharedPlatformScalar("slack", "require_mention")` is the read.
        // Its `maps[section]?[key]` fallback used to hand back the FIRST
        // block's `true`; the surviving block has no such key, so the
        // schema default (`true`) applies for a different reason — assert on
        // the parse the reader consumes, which is where the defect lived.
        let parsed = HermesYAML.parseNestedYAML(Self.twoSlackBlocks)
        #expect(parsed.maps["slack"]?["require_mention"] == nil)
        // And with the surviving block saying `false`, the reader must see it.
        let flipped = HermesYAML.parseNestedYAML("""
            slack:
              require_mention: true
            slack:
              require_mention: false
            """)
        #expect(flipped.maps["slack"]?["require_mention"] == "false")
        #expect(HermesConfig(yaml: """
            slack:
              require_mention: true
            slack:
              require_mention: false
            """).slack.requireMention == false)
    }

    /// The flow form of the first block is the same defect through
    /// `values[path]` rather than `maps[path]`.
    @Test("a flow first block is replaced by a block second one")
    func aFlowFirstBlockIsAlsoPurged() {
        let parsed = HermesYAML.parseNestedYAML("""
            slack: {require_mention: true}
            slack:
              bot_name: second
            """)
        #expect(parsed.maps["slack"]?["require_mention"] == nil)
        #expect(parsed.maps["slack"]?["bot_name"] == "second")
    }

    // MARK: - a flat dotted sibling survives the re-open

    @Test("a flat dotted key between two blocks is an independent key")
    func aFlatDottedSiblingSurvivesTheReopen() {
        let parsed = HermesYAML.parseNestedYAML("""
            gateway:
              enabled: false
              port: 1
            gateway.enabled: true
            gateway:
              port: 2
            """)
        // PyYAML: {"gateway": {"port": 2}, "gateway.enabled": true}
        #expect(parsed.values["gateway.enabled"] == "true",
                "the flat dotted key is not a descendant of the `gateway:` mapping")
        #expect(parsed.maps["gateway"]?["port"] == "2")
        #expect(parsed.maps["gateway"]?["enabled"] == nil)
    }

    /// P37's case — the same sibling on a FIRST open — must still hold.
    @Test("a flat dotted key before a first block still survives")
    func aFlatDottedSiblingSurvivesTheFirstOpen() {
        let parsed = HermesYAML.parseNestedYAML("""
            gateway.enabled: true
            gateway:
              port: 2
            """)
        #expect(parsed.values["gateway.enabled"] == "true")
        #expect(parsed.maps["gateway"]?["port"] == "2")
    }

    /// And the genuinely nested descendant is still purged — the sweep must
    /// not have been disarmed wholesale.
    @Test("a genuinely nested descendant is still purged")
    func nestedDescendantsAreStillPurged() {
        let parsed = HermesYAML.parseNestedYAML("""
            gateway:
              platforms:
                slack:
                  enabled: true
            gateway:
              port: 2
            """)
        #expect(parsed.values["gateway.platforms.slack.enabled"] == nil)
        #expect(parsed.maps["gateway.platforms.slack"] == nil)
        #expect(parsed.values["gateway.port"] == "2")
    }
}
