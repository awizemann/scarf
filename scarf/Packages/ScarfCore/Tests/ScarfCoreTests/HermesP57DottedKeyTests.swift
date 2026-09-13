import Foundation
import Testing
@testable import ScarfCore

@Suite("P57 — a flat dotted key is not a platform block")
struct HermesP57DottedBlockTests {

    /// `platform_section` (`gateway/config_loader.py:171-180` @ `v2026.9.7`)
    /// is `yaml_cfg.get(name)` + `isinstance(section, dict)`. A hand-edited
    /// flat `slack.enabled: true` is the mapping key `"slack.enabled"`, so
    /// `yaml_cfg.get("slack")` is `None` and the bridge source falls through
    /// to `platforms.slack`. Scarf's prefix scan matched `slack.` and
    /// answered `slack` — reading from, and then WRITING to, a section Hermes
    /// does not bridge.
    @Test func aFlatDottedKeyDoesNotMakeAPlatformBlock() {
        let parsed = HermesYAML.parseNestedYAML("""
        slack.enabled: true
        platforms:
          slack:
            require_mention: false
        """)
        #expect(parsed.dottedLiteralPaths.contains("slack.enabled"))
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", in: parsed)
                == "platforms.slack")
    }

    /// With nothing else in the file at all, the fall-through is the same
    /// `platforms.slack` a fresh host gives.
    @Test func aFlatDottedKeyAloneStillFallsThrough() {
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack",
            configText: "slack.enabled: true\n") == "platforms.slack")
    }

    /// A dotted key opened as a BLOCK header is `{"slack.enabled": {…}}` to
    /// PyYAML — still not a `slack` dict, so its children are no better
    /// evidence than the key itself.
    @Test func aDottedBlockHeadersChildrenAreNotEvidenceEither() {
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack",
            configText: "slack.enabled:\n  nested: 1\n") == "platforms.slack")
    }

    /// The clamp: a REAL top-level block still wins, with or without members,
    /// and a `gateway.platforms` block still out-ranks the bare default.
    @Test func realBlocksAreUnaffected() {
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack", configText: "slack:\n  require_mention: false\n") == "slack")
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack", configText: "slack: {}\n") == "slack")
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack",
            configText: "gateway:\n  platforms:\n    slack:\n      require_mention: false\n")
            == "gateway.platforms.slack")
        // A bare `slack:` header with no children is `None`, not a dict.
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack", configText: "slack:\n") == "platforms.slack")
    }

    /// What PyYAML actually loads for the fixture above, straight from the
    /// interpreter — the citation this suite rests on, executed.
    @Test func theRealPyYAMLKeepsTheDottedKeyIndependent() {
        // `topLevelKeys` answers on the OUTERMOST mapping only, which is the
        // thing `yaml_cfg.get("slack")` looks at.
        let keys = P57PyYAML.topLevelKeys("slack.enabled: true\nplatforms:\n  slack:\n    require_mention: false\n")
        guard let keys, keys != "__NO_PYYAML__" else { return }
        #expect(keys == "platforms,slack.enabled", "top-level keys were \(keys)")
    }
}
