import XCTest
@testable import ScarfCore

/// `gateway.profile_routes` (Hermes v0.19+) — reader, writer, and the
/// matching/ranking assumptions the UI is built on.
///
/// Every expectation here is pinned to hermes-agent tag v2026.8.3:
/// `gateway/profile_routing.py`, `gateway/config.py`, `docs/profile-routing.md`.
final class ProfileRoutesTests: XCTestCase {

    private func caps(_ major: Int, _ minor: Int, _ patch: Int = 0) -> HermesCapabilities {
        HermesCapabilities(
            versionLine: "hermes \(major).\(minor).\(patch)",
            semver: HermesCapabilities.SemVer(major: major, minor: minor, patch: patch),
            dateVersion: nil
        )
    }
    /// Unknown host version — every semver floor must read false.
    private var capsUnknown: HermesCapabilities {
        HermesCapabilities(versionLine: "", semver: nil, dateVersion: nil)
    }

    private var v019: HermesCapabilities { caps(0, 19) }
    private var v018: HermesCapabilities { caps(0, 18, 2) }

    // MARK: - Reading

    func testReadsNestedGatewayForm() {
        let yaml = """
        gateway:
          multiplex_profiles: true
          profile_routes:
            - name: server-default
              platform: discord
              guild_id: '1234567890'
              profile: server-profile
            - name: support
              platform: discord
              guild_id: '1234567890'
              chat_id: '9876543210'
              profile: support-profile
        """
        let parsed = ProfileRoutesYAML.parse(yaml)
        XCTAssertEqual(parsed.location, .gateway)
        XCTAssertTrue(parsed.multiplexProfiles)
        XCTAssertEqual(parsed.routes.count, 2)
        XCTAssertEqual(parsed.routes[0].name, "server-default")
        XCTAssertEqual(parsed.routes[0].guildID, "1234567890")
        XCTAssertEqual(parsed.routes[0].chatID, "")
        XCTAssertEqual(parsed.routes[1].chatID, "9876543210")
        XCTAssertEqual(parsed.routes[1].profile, "support-profile")
        // `enabled` absent → Hermes default true, and NOT explicit.
        XCTAssertTrue(parsed.routes[0].enabled)
        XCTAssertFalse(parsed.routes[0].enabledIsExplicit)
    }

    func testTopLevelFormWinsOverNested() {
        // gateway/config.py:1356-1360 — top-level is read first; the nested
        // form is only consulted when the top-level key is absent.
        let yaml = """
        profile_routes:
          - name: top
            platform: telegram
            chat_id: '-100'
            profile: tg

        gateway:
          profile_routes:
            - name: nested
              platform: discord
              profile: other
        """
        let parsed = ProfileRoutesYAML.parse(yaml)
        XCTAssertEqual(parsed.location, .topLevel)
        XCTAssertEqual(parsed.routes.map(\.name), ["top"])
    }

    func testEmptyTopLevelHeaderFallsThroughToNested() {
        // A bare `profile_routes:` is `None` to PyYAML, not a list, so
        // `isinstance(_pr, list)` fails and Hermes reads the nested form.
        let yaml = """
        profile_routes:

        gateway:
          profile_routes:
            - name: nested
              platform: discord
              profile: other
        """
        let parsed = ProfileRoutesYAML.parse(yaml)
        XCTAssertEqual(parsed.location, .gateway)
        XCTAssertEqual(parsed.routes.map(\.name), ["nested"])
    }

    func testInlineEmptyFlowListIsAPresentEmptyList() {
        let yaml = """
        profile_routes: []

        gateway:
          profile_routes:
            - name: nested
              platform: discord
              profile: other
        """
        let parsed = ProfileRoutesYAML.parse(yaml)
        XCTAssertEqual(parsed.location, .topLevel)
        XCTAssertTrue(parsed.routes.isEmpty)
    }

    func testMultiplexTopLevelWinsAndDefaultsFalse() {
        XCTAssertFalse(ProfileRoutesYAML.parse("gateway:\n  foo: 1\n").multiplexProfiles)
        XCTAssertTrue(ProfileRoutesYAML.parse("multiplex_profiles: true\n").multiplexProfiles)
        let both = "multiplex_profiles: false\ngateway:\n  multiplex_profiles: true\n"
        XCTAssertFalse(ProfileRoutesYAML.parse(both).multiplexProfiles)
    }

    func testEnabledFalseIsRead() {
        let yaml = """
        gateway:
          profile_routes:
            - name: paused
              platform: slack
              profile: p
              enabled: false
        """
        let route = ProfileRoutesYAML.parse(yaml).routes[0]
        XCTAssertFalse(route.enabled)
        XCTAssertTrue(route.enabledIsExplicit)
    }

    func testConfigParseExposesRoutes() {
        let config = HermesConfig(yaml: """
        model:
          default: gpt-5
        gateway:
          profile_routes:
            - name: r
              platform: discord
              guild_id: '1'
              profile: p
        """)
        XCTAssertEqual(config.profileRoutes.routes.count, 1)
        XCTAssertEqual(config.profileRoutes.location, .gateway)
    }

    // MARK: - Semantics pinned

    func testSpecificityWeightsMirrorHermes() {
        // profile_routing.py:62-72 — guild 2, chat 4, thread 8, additive.
        XCTAssertEqual(HermesProfileRoute(platform: "discord", profile: "p").specificity, 0)
        XCTAssertEqual(HermesProfileRoute(platform: "d", profile: "p", guildID: "g").specificity, 2)
        XCTAssertEqual(HermesProfileRoute(platform: "d", profile: "p", chatID: "c").specificity, 4)
        XCTAssertEqual(HermesProfileRoute(platform: "d", profile: "p", threadID: "t").specificity, 8)
        XCTAssertEqual(
            HermesProfileRoute(platform: "d", profile: "p", guildID: "g", chatID: "c", threadID: "t").specificity,
            14
        )
    }

    func testEffectiveOrderIsSpecificityRankedAndStable() {
        // Ranked most-specific-first; equal specificity keeps FILE order
        // (Python's list.sort is stable — profile_routing.py:149). File
        // order alone must NOT determine priority.
        let routes = [
            HermesProfileRoute(name: "guild", platform: "d", profile: "a", guildID: "g"),
            HermesProfileRoute(name: "thread", platform: "d", profile: "b", threadID: "t"),
            HermesProfileRoute(name: "chatA", platform: "d", profile: "c", chatID: "c1"),
            HermesProfileRoute(name: "chatB", platform: "d", profile: "d", chatID: "c2"),
        ]
        let block = HermesProfileRoutes(routes: routes, location: .gateway)
        XCTAssertEqual(block.effectiveOrder.map(\.name), ["thread", "chatA", "chatB", "guild"])
    }

    func testEffectiveOrderExcludesRulesHermesDrops() {
        let routes = [
            HermesProfileRoute(name: "ok", platform: "d", profile: "good", threadID: "t"),
            HermesProfileRoute(name: "noPlatform", platform: "", profile: "good", chatID: "c"),
            HermesProfileRoute(name: "badProfile", platform: "d", profile: "Bad Name!", chatID: "c"),
        ]
        let block = HermesProfileRoutes(routes: routes, location: .gateway)
        XCTAssertEqual(block.effectiveOrder.map(\.name), ["ok"])
    }

    func testProfileNameValidationMirrorsHermes() {
        XCTAssertTrue(HermesProfileName.isValid("default"))
        XCTAssertTrue(HermesProfileName.isValid("Default"))     // normalized
        XCTAssertTrue(HermesProfileName.isValid("work-bot_2"))
        XCTAssertFalse(HermesProfileName.isValid(""))
        XCTAssertFalse(HermesProfileName.isValid("-leading"))
        XCTAssertFalse(HermesProfileName.isValid("has space"))
        XCTAssertFalse(HermesProfileName.isValid("../escape"))
        XCTAssertFalse(HermesProfileName.isValid("hermes"))     // reserved
        XCTAssertFalse(HermesProfileName.isValid("root"))
        XCTAssertFalse(HermesProfileName.isValid(String(repeating: "a", count: 65)))
    }

    // MARK: - Writing

    func testWriterCreatesNestedBlockWhenAbsent() {
        let yaml = "model:\n  default: gpt-5\n"
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: yaml,
            routes: [HermesProfileRoute(name: "r", platform: "discord", profile: "p", guildID: "123")],
            location: .absent,
            capabilities: v019
        )
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("gateway:"))
        XCTAssertTrue(out!.contains("  profile_routes:"))
        XCTAssertTrue(out!.contains("    - name: r"))
        XCTAssertTrue(out!.contains("      platform: discord"))
        // Numeric ids MUST stay strings.
        XCTAssertTrue(out!.contains("      guild_id: '123'"))
        XCTAssertTrue(out!.contains("      profile: p"))
        XCTAssertFalse(out!.contains("enabled:"))   // default not materialized
        XCTAssertTrue(out!.hasPrefix("model:\n  default: gpt-5\n"))
    }

    func testWriterSplicesIntoExistingGatewaySection() {
        let yaml = """
        gateway:
          multiplex_profiles: true

        model:
          default: gpt-5
        """
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: yaml,
            routes: [HermesProfileRoute(platform: "slack", profile: "p")],
            location: .absent,
            capabilities: v019
        )!
        XCTAssertTrue(out.contains("  multiplex_profiles: true"))
        XCTAssertTrue(out.contains("model:\n  default: gpt-5"))
        let parsed = ProfileRoutesYAML.parse(out)
        XCTAssertEqual(parsed.location, .gateway)
        XCTAssertEqual(parsed.routes.count, 1)
        XCTAssertTrue(parsed.multiplexProfiles)
    }

    func testWriterEditsTopLevelFormWhenThatIsWhatHermesReads() {
        let yaml = """
        profile_routes:
          - name: old
            platform: discord
            profile: p

        gateway:
          multiplex_profiles: true
        """
        let block = ProfileRoutesYAML.parse(yaml)
        var route = block.routes[0]
        route.name = "renamed"
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: yaml,
            routes: [route],
            location: block.location,
            capabilities: v019
        )!
        let reparsed = ProfileRoutesYAML.parse(out)
        XCTAssertEqual(reparsed.location, .topLevel)
        XCTAssertEqual(reparsed.routes.map(\.name), ["renamed"])
        XCTAssertTrue(out.contains("gateway:\n  multiplex_profiles: true"))
        // Top-level block stays at indent 0.
        XCTAssertTrue(out.contains("profile_routes:\n  - name: renamed"))
    }

    func testClearingRemovesBothForms() {
        let yaml = """
        profile_routes:
          - name: top
            platform: discord
            profile: p

        gateway:
          multiplex_profiles: true
          profile_routes:
            - name: nested
              platform: discord
              profile: q
        """
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: yaml,
            routes: [],
            location: .topLevel,
            capabilities: v019
        )!
        XCTAssertFalse(out.contains("profile_routes"))
        XCTAssertTrue(out.contains("  multiplex_profiles: true"))
    }

    func testUnknownKeysSurviveRoundTrip() {
        let yaml = """
        gateway:
          profile_routes:
            - name: r
              platform: discord
              guild_id: '1'
              profile: p
              future_key: keep-me
              future_block:
                nested: 1
                deeper:
                  - a
        """
        let block = ProfileRoutesYAML.parse(yaml)
        XCTAssertEqual(block.routes.count, 1)
        var route = block.routes[0]
        XCTAssertEqual(route.extraLines, [
            "future_key: keep-me",
            "future_block:",
            "  nested: 1",
            "  deeper:",
            "    - a",
        ])
        route.chatID = "42"
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: yaml,
            routes: [route],
            location: block.location,
            capabilities: v019
        )!
        XCTAssertTrue(out.contains("future_key: keep-me"))
        XCTAssertTrue(out.contains("      future_block:"))
        XCTAssertTrue(out.contains("        nested: 1"))
        XCTAssertTrue(out.contains("          - a"))
        let reparsed = ProfileRoutesYAML.parse(out)
        XCTAssertEqual(reparsed.routes[0].extraLines, route.extraLines)
        XCTAssertEqual(reparsed.routes[0].chatID, "42")
    }

    func testFullRoundTripIsIdempotent() {
        let yaml = """
        gateway:
          profile_routes:
            - name: thread-route
              platform: discord
              guild_id: '1'
              chat_id: '2'
              thread_id: '3'
              profile: standup
              enabled: false
        """
        let block = ProfileRoutesYAML.parse(yaml)
        let once = ProfileRoutesWriter.setProfileRoutes(
            in: yaml, routes: block.routes, location: block.location, capabilities: v019
        )!
        let twice = ProfileRoutesWriter.setProfileRoutes(
            in: once,
            routes: ProfileRoutesYAML.parse(once).routes,
            location: ProfileRoutesYAML.parse(once).location,
            capabilities: v019
        )!
        XCTAssertEqual(once, twice)
        let reparsed = ProfileRoutesYAML.parse(twice).routes[0]
        XCTAssertEqual(reparsed.name, "thread-route")
        XCTAssertEqual(reparsed.threadID, "3")
        XCTAssertFalse(reparsed.enabled)
        XCTAssertEqual(reparsed.specificity, 14)
    }

    func testUnsetFieldsAreOmittedNotWrittenEmpty() {
        // Python treats "" as falsy in the `if self.chat_id` guards, so an
        // empty string is harmless — but the file should still say what it
        // means, and an empty `chat_id: ''` would confuse a human reader.
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: "",
            routes: [HermesProfileRoute(platform: "telegram", profile: "tg", chatID: "-100")],
            location: .absent,
            capabilities: v019
        )!
        XCTAssertTrue(out.contains("chat_id: '-100'"))
        XCTAssertFalse(out.contains("guild_id"))
        XCTAssertFalse(out.contains("thread_id"))
        XCTAssertFalse(out.contains("name:"))
    }

    func testWriterPreservesCRLF() {
        let yaml = "model:\r\n  default: gpt-5\r\n"
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: yaml,
            routes: [HermesProfileRoute(platform: "discord", profile: "p")],
            location: .absent,
            capabilities: v019
        )!
        XCTAssertFalse(out.contains("\n\n"))       // no bare LF pairs
        XCTAssertTrue(out.contains("\r\n"))
        XCTAssertTrue(ProfileRoutesYAML.parse(out).routes.count == 1)
    }

    func testWriterPreservesSurroundingKeysAndComments() {
        let yaml = """
        # top comment
        gateway:
          # keep me
          multiplex_profiles: true
          profile_routes:
            - name: old
              platform: discord
              profile: p
          other_key: 7

        model:
          default: gpt-5
        """
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: yaml,
            routes: [HermesProfileRoute(name: "new", platform: "slack", profile: "q")],
            location: .gateway,
            capabilities: v019
        )!
        XCTAssertTrue(out.contains("# top comment"))
        XCTAssertTrue(out.contains("  # keep me"))
        XCTAssertTrue(out.contains("  other_key: 7"))
        XCTAssertTrue(out.contains("model:\n  default: gpt-5"))
        XCTAssertEqual(ProfileRoutesYAML.parse(out).routes.map(\.name), ["new"])
    }

    func testPopulatedFlowListIsReportedUnsupportedAndRefused() {
        // A flow list is live for Hermes (PyYAML sees a real list) but is
        // outside the scanner's grammar. Editing the block form instead
        // would produce a file Hermes ignores — so: read-only.
        let yaml = "profile_routes: [{name: a, platform: discord, profile: p}]\n"
        let parsed = ProfileRoutesYAML.parse(yaml)
        XCTAssertEqual(parsed.location, .unsupported)
        XCTAssertNil(ProfileRoutesWriter.setProfileRoutes(
            in: yaml,
            routes: [HermesProfileRoute(platform: "discord", profile: "p")],
            location: parsed.location,
            capabilities: v019
        ))

        // Nested form, same treatment — but only when the top-level form
        // isn't a block list we can own.
        let nested = "gateway:\n  profile_routes: [{name: a, platform: discord, profile: p}]\n"
        XCTAssertEqual(ProfileRoutesYAML.parse(nested).location, .unsupported)

        let topWins = """
        profile_routes:
          - name: top
            platform: discord
            profile: p

        gateway:
          profile_routes: [{name: a}]
        """
        XCTAssertEqual(ProfileRoutesYAML.parse(topWins).location, .topLevel)
    }

    func testCommentsInsideARuleSurviveRewrite() {
        let yaml = """
        gateway:
          profile_routes:
            # block-level note
            - name: r
              # why this route exists
              platform: discord
              profile: p
        """
        let block = ProfileRoutesYAML.parse(yaml)
        var route = block.routes[0]
        route.chatID = "9"
        let out = ProfileRoutesWriter.setProfileRoutes(
            in: yaml, routes: [route], location: block.location, capabilities: v019
        )!
        XCTAssertTrue(out.contains("# why this route exists"))
        // Header comments move into the first rule rather than being eaten.
        XCTAssertTrue(out.contains("# block-level note"))
        XCTAssertEqual(ProfileRoutesYAML.parse(out).routes[0].chatID, "9")
    }

    // MARK: - Capability boundary

    func testWriterRefusesOnPreV019Host() {
        XCTAssertNil(ProfileRoutesWriter.setProfileRoutes(
            in: "",
            routes: [HermesProfileRoute(platform: "discord", profile: "p")],
            location: .absent,
            capabilities: v018
        ))
        XCTAssertNil(ProfileRoutesWriter.setProfileRoutes(
            in: "",
            routes: [],
            location: .absent,
            capabilities: capsUnknown
        ))
    }

    func testCapabilityFloorIsV019() {
        XCTAssertFalse(caps(0, 18, 2).hasGatewayProfileRoutes)
        XCTAssertTrue(caps(0, 19).hasGatewayProfileRoutes)
        XCTAssertTrue(caps(0, 20).hasGatewayProfileRoutes)
        XCTAssertFalse(caps(0, 18, 9).isV019OrLater)
        XCTAssertTrue(caps(0, 19, 1).isV019OrLater)
    }

    func testWriterRefusesRatherThanDuplicateAnInlineGatewaySection() {
        // Appending a second top-level `gateway:` would let PyYAML's
        // last-wins duplicate-key rule delete the inline mapping.
        XCTAssertNil(ProfileRoutesWriter.setProfileRoutes(
            in: "gateway: {multiplex_profiles: true}\n",
            routes: [HermesProfileRoute(platform: "discord", profile: "p")],
            location: .absent,
            capabilities: v019
        ))
    }

    func testWriterRefusesStructurallyIncompleteRule() {
        XCTAssertNil(ProfileRoutesWriter.setProfileRoutes(
            in: "", routes: [HermesProfileRoute(platform: "", profile: "p")],
            location: .absent, capabilities: v019
        ))
        XCTAssertNil(ProfileRoutesWriter.setProfileRoutes(
            in: "", routes: [HermesProfileRoute(platform: "discord", profile: "")],
            location: .absent, capabilities: v019
        ))
    }
}
