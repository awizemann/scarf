import Foundation
import Testing
@testable import ScarfCore

/// P57b finding 4: P57's dotted-key exclusion could not tell a dotted key
/// written INSIDE a real block from a flat one written at the top level, and
/// excluded both.
///
/// Every `load=` line below is `yaml.safe_load` on PyYAML 6.0.3, printed:
///
///   `slack:\n  a.b:\n    c: 1`  → `{'slack': {'a.b': {'c': 1}}}`
///   `slack:\n  a.b: 1`          → `{'slack': {'a.b': 1}}`
///   `slack.enabled: true`       → `{'slack.enabled': True}`
///
/// The first two ARE `slack` dicts, so `platform_section`
/// (`gateway/config_loader.py:171-180` @ `v2026.9.7`) takes the top-level
/// block and never reaches `platforms.slack`; the third is not. The
/// discriminator is the dot's DEPTH — whether it crosses the section's own
/// boundary — which is why `ParsedYAML` now records
/// `dottedLiteralParentDepths` beside the paths.
@Suite("P57b — a dotted key nested inside a real block is still a block")
struct HermesP57bNestedDottedKeyTests {

    /// Shape A: the dotted key opens a sub-block. `{'slack': {'a.b': {'c': 1}}}`.
    @Test func aDottedSubBlockInsideSlackKeepsSlackABlock() {
        let parsed = HermesYAML.parseNestedYAML("""
        slack:
          a.b:
            c: 1
        """)
        #expect(parsed.dottedLiteralPaths.contains("slack.a.b"))
        #expect(parsed.dottedLiteralParentDepths["slack.a.b"] == 1)
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: parsed)
                == "slack")
    }

    /// Shape B: the dotted key is a leaf scalar. `{'slack': {'a.b': 1}}`.
    @Test func aDottedLeafInsideSlackKeepsSlackABlock() {
        let parsed = HermesYAML.parseNestedYAML("""
        slack:
          a.b: 1
        """)
        #expect(parsed.dottedLiteralParentDepths["slack.a.b"] == 1)
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: parsed)
                == "slack")
    }

    /// The flat case P57 fixed, unchanged — depth 0, so the dot crosses
    /// `slack`'s boundary and the key is evidence AGAINST a block.
    @Test func aFlatDottedKeyStillFallsThrough() {
        let parsed = HermesYAML.parseNestedYAML("slack.enabled: true\n")
        #expect(parsed.dottedLiteralParentDepths["slack.enabled"] == 0)
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: parsed)
                == "platforms.slack")
    }

    /// A QUOTED flat dotted key is the same PyYAML mapping key —
    /// `yaml.safe_load("'slack.enabled': true")` is `{'slack.enabled': True}`,
    /// byte-for-byte the unquoted answer — so it must give the same verdict.
    @Test func aQuotedFlatDottedKeyIsTheSameKey() {
        let parsed = HermesYAML.parseNestedYAML("'slack.enabled': true\n")
        #expect(parsed.dottedLiteralPaths.contains("slack.enabled"))
        #expect(parsed.dottedLiteralParentDepths["slack.enabled"] == 0)
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: parsed)
                == "platforms.slack")
    }

    /// `slack_bot:` is a different key entirely and never touched the
    /// `slack.` prefix scan — pinned so a future widening of the prefix test
    /// cannot quietly capture it. `yaml.safe_load` gives `{'slack_bot': {…}}`,
    /// and `yaml_cfg.get("slack")` is `None`.
    @Test func slackBotIsNotSlack() {
        let parsed = HermesYAML.parseNestedYAML("""
        slack_bot:
          enabled: true
        """)
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: parsed)
                == "platforms.slack")
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack_bot", in: parsed)
                == "slack_bot")
    }

    /// The depth rule at the NESTED spelling, both ways.
    ///
    ///   `gateway:\n  platforms:\n    slack:\n      a.b: 1`
    ///     → `{'gateway': {'platforms': {'slack': {'a.b': 1}}}}` — a real
    ///       `gateway.platforms.slack` dict (top-level `slack` is still None).
    ///   `gateway:\n  platforms.slack:\n    enabled: true`
    ///     → `{'gateway': {'platforms.slack': {'enabled': True}}}` —
    ///       `gateway["platforms"]` is None, so this is NOT one.
    @Test func theDepthRuleHoldsAtTheGatewaySpelling() {
        let real = HermesYAML.parseNestedYAML("""
        gateway:
          platforms:
            slack:
              a.b: 1
        """)
        #expect(real.dottedLiteralParentDepths["gateway.platforms.slack.a.b"] == 3)
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: real)
                == "gateway.platforms.slack")

        let dotted = HermesYAML.parseNestedYAML("""
        gateway:
          platforms.slack:
            enabled: true
        """)
        #expect(dotted.dottedLiteralParentDepths["gateway.platforms.slack"] == 1)
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: dotted)
                == "platforms.slack")
    }

    /// A real block and a flat dotted key in the SAME file: PyYAML keeps both
    /// (`{'slack': {'enabled': True}, 'slack.require_mention': False}`), and
    /// the real block wins — the dotted key must not veto it.
    @Test func aRealBlockBesideAFlatDottedKeyStillWins() {
        let parsed = HermesYAML.parseNestedYAML("""
        slack:
          enabled: true
        slack.require_mention: false
        """)
        #expect(parsed.dottedLiteralParentDepths["slack.require_mention"] == 0)
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: parsed)
                == "slack")
    }
}
