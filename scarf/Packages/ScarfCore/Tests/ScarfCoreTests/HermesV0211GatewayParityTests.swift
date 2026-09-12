import Testing
import Foundation
@testable import ScarfCore

/// Phase 2 of the Hermes v0.21.1 (tag `v2026.9.7`) parity sweep: the
/// Messaging Gateway surfaces — the multiplexer branches of `gateway status`
/// / `gateway list` (finding A6), the platform roster (B4) and the dead /
/// mis-defaulted `GatewayPlatformSettings` fields (B5).
///
/// Every fixture in here is reproduced from the tagged Hermes source, not
/// from a release note (charter C2). The `gateway list` line shape comes
/// from `_gateway_list` (`hermes_cli/gateway.py:1512-1525`), which builds
/// `f"  {marker} {label:<24s}"` and joins the trailing clause with `" — "`
/// (em dash, U+2014).
@Suite struct HermesV0211GatewayParityTests {

    // MARK: - A6: `gateway list` — "served by the default multiplexer"

    /// Drift alarm. A running profile with no pid of its own, whose inbound
    /// traffic the default profile's multiplexer carries, prints the clause
    /// where a self-hosted profile prints `PID <n>`
    /// (`hermes_cli/gateway.py:1520-1522` at tag `v2026.9.7`).
    @Test func parsesMultiplexedProfileFromTaggedOutputShape() throws {
        let text = """
        Gateways:
          ✓ default (current)        — PID 44417
          ✓ work                     — served by the default multiplexer
          ✗ scarfbox-smoke           — not running
        """
        let snap = HermesGatewayListService.parse(text)
        try #require(snap?.profiles.count == 3)

        // Self-hosted: unchanged by the new branch.
        #expect(snap?.profiles[0].profile == "default")
        #expect(snap?.profiles[0].isRunning == true)
        #expect(snap?.profiles[0].pid == 44417)
        #expect(snap?.profiles[0].servedByMultiplexer == false)

        // Multiplexed: running, no pid, and the state is EXPLICIT rather
        // than inferred from "running but pid didn't parse".
        #expect(snap?.profiles[1].profile == "work")
        #expect(snap?.profiles[1].isRunning == true)
        #expect(snap?.profiles[1].pid == nil)
        #expect(snap?.profiles[1].servedByMultiplexer == true)

        #expect(snap?.profiles[2].profile == "scarfbox-smoke")
        #expect(snap?.profiles[2].isRunning == false)
        #expect(snap?.profiles[2].servedByMultiplexer == false)
    }

    /// A pre-v0.21.1 host never emits the clause, so every entry it parses
    /// must keep `servedByMultiplexer == false` — the byte-identical
    /// pre-target rendering the charter requires.
    @Test func preTargetOutputNeverSetsTheMultiplexerFlag() {
        let text = """
        Gateways:
          ✓ default (current)        — PID 44417
          ✗ scarfbox-smoke           — not running
        """
        let snap = HermesGatewayListService.parse(text)
        #expect(snap?.profiles.allSatisfy { !$0.servedByMultiplexer } == true)
    }

    @Test func digestNamesTheMultiplexerForASingleServedProfile() {
        let served = GatewayListSnapshot(profiles: [
            .init(profile: "work", isRunning: true, pid: nil, servedByMultiplexer: true)
        ])
        #expect(served.headerDigest == "work profile · served by the default multiplexer")

        // Unchanged for every pre-v0.21.1 shape.
        let plain = GatewayListSnapshot(profiles: [
            .init(profile: "default", isRunning: true, pid: 1)
        ])
        #expect(plain.headerDigest == "default profile · running")
    }

    // MARK: - B4: the platform roster vs the tagged Hermes universe

    /// `Platform` enum members, verbatim from `gateway/config.py:201-224` at
    /// tag `v2026.9.7` (identical at v2026.8.31).
    static let taggedPlatformEnum: Set<String> = [
        "local", "telegram", "discord", "whatsapp", "whatsapp_cloud", "slack",
        "signal", "mattermost", "matrix", "homeassistant", "email", "sms",
        "dingtalk", "api_server", "webhook", "msgraph_webhook", "feishu",
        "wecom", "wecom_callback", "weixin", "bluebubbles", "qqbot",
        "yuanbao", "relay",
    ]

    /// Bundled plugin adapter directories, verbatim from
    /// `git ls-tree v2026.9.7 plugins/platforms/`. These become dynamic
    /// `Platform` members via `Platform._missing_`.
    static let taggedPluginPlatforms: Set<String> = [
        "a2a", "buzz", "dingtalk", "discord", "email", "feishu",
        "google_chat", "homeassistant", "irc", "line", "matrix", "mattermost",
        "ntfy", "photon", "raft", "simplex", "slack", "sms", "teams",
        "telegram", "wecom", "whatsapp",
    ]

    /// Hermes platform ids Scarf deliberately does NOT surface, with the
    /// reason each one is internal rather than a user messaging account.
    /// Changing this set is a product decision, not a refactor.
    static let deliberateExclusions: Set<String> = [
        "local",           // the in-process CLI/TUI channel, not configurable
        "relay",           // marked EXPERIMENTAL in the enum comment
        "wecom_callback",  // callback leg of `wecom`, no account of its own
        "a2a",             // agent-to-agent infrastructure; requires_env: []
        "raft",            // experimental bridge; one env var, no account
    ]

    /// Scarf-only rows with no Hermes platform id behind them.
    static let scarfOnlyRows: Set<String> = [
        "cli",             // Scarf's own local-terminal pseudo-platform
    ]

    /// The roster gate. Scanning the enum and the plugin directories at the
    /// tag is the only way to notice a platform Hermes added — the finding
    /// that started this (B4) was thirteen ids old.
    @Test func rosterMatchesTheTaggedHermesUniverse() {
        let scarf = Set(KnownPlatforms.all.map(\.name))
        let hermes = Self.taggedPlatformEnum.union(Self.taggedPluginPlatforms)

        let missing = hermes.subtracting(Self.deliberateExclusions).subtracting(scarf)
        #expect(missing.isEmpty, """
            Hermes platform ids absent from `KnownPlatforms.all`: \
            \(missing.sorted().joined(separator: ", ")). Either surface them \
            or add them to `deliberateExclusions` with the reason.
            """)

        let extra = scarf.subtracting(hermes).subtracting(Self.scarfOnlyRows)
        #expect(extra.isEmpty, """
            `KnownPlatforms.all` rows that are not Hermes platform ids at \
            v2026.9.7: \(extra.sorted().joined(separator: ", ")). A row whose \
            name isn't the Hermes id can never match its `<platform>:` config \
            block (the `imessage` → `bluebubbles` bug).
            """)
    }

    /// The ten ids the B4 sweep brought in (nine new rows plus the
    /// `imessage` → `bluebubbles` rename), pinned by name so a later
    /// refactor can't quietly drop one.
    @Test func b4AdditionsAreAllPresentWithIcons() {
        let scarf = Set(KnownPlatforms.all.map(\.name))
        for name in ["dingtalk", "sms", "irc", "wecom", "weixin",
                     "bluebubbles", "qqbot", "msgraph_webhook", "api_server",
                     "photon"] {
            #expect(scarf.contains(name), "\(name) missing from KnownPlatforms.all")
            // Never the `bubble.left` fallback — each has a real symbol.
            #expect(KnownPlatforms.icon(for: name) != "bubble.left" || name == "bluebubbles")
        }
        // The retired spelling still resolves for any legacy caller.
        #expect(KnownPlatforms.icon(for: "imessage") == "message.fill")
        #expect(KnownPlatforms.icon(for: "bluebubbles") == "message.fill")
        #expect(!scarf.contains("imessage"))
    }

    @Test func rosterIdsAreUnique() {
        let names = KnownPlatforms.all.map(\.name)
        #expect(Set(names).count == names.count, "duplicate platform id in KnownPlatforms.all")
    }

    // MARK: - B5: gateway_restart_notification default + the dead field

    /// Hermes: `PlatformConfig.gateway_restart_notification: bool = True`
    /// (`gateway/config.py:393`, identical at both tags). An absent key must
    /// therefore read TRUE — reading `false` rendered the toggle off on a
    /// host that was pinging, and one save wrote that `false` back.
    @Test func absentRestartNotificationKeyReadsTrue() {
        let cfg = HermesConfig(yaml: """
        slack:
          allowed_channels:
            - C01
        """)
        #expect(cfg.gatewayPlatforms["slack"]?.gatewayRestartNotification == true)
    }

    /// Only a real falsy spelling turns it off — the same `boolTrueDefault`
    /// falsy set Phase 1 introduced for the other true-by-default keys.
    @Test func onlyFalsySpellingsTurnRestartNotificationOff() {
        for spelling in ["false", "False", "0", "no", "off"] {
            let cfg = HermesConfig(yaml: "slack:\n  gateway_restart_notification: \(spelling)\n")
            #expect(cfg.gatewayPlatforms["slack"]?.gatewayRestartNotification == false,
                    "\(spelling) should read as off")
        }
        for spelling in ["true", "True", "yes", "on", "1"] {
            let cfg = HermesConfig(yaml: "slack:\n  gateway_restart_notification: \(spelling)\n")
            #expect(cfg.gatewayPlatforms["slack"]?.gatewayRestartNotification == true,
                    "\(spelling) should read as on")
        }
    }

    /// A file with no gateway keys at all still produces no block, so the
    /// new default can't manufacture entries the user never configured.
    @Test func noGatewayKeysStillYieldsNoBlock() {
        #expect(HermesConfig(yaml: "model: gpt-4o\n").gatewayPlatforms.isEmpty)
        // …and a platform with only an unrelated key is still absent.
        #expect(HermesConfig(yaml: "slack:\n  reply_to_mode: all\n").gatewayPlatforms["slack"] == nil)
    }

    /// B4 follow-through: Discord's allowlist is now mapped, so the parser
    /// must READ `discord.allowed_channels` too — otherwise the editor saves
    /// a list that reads back empty on the next load.
    @Test func discordAllowlistRoundTripsThroughTheParser() {
        let cfg = HermesConfig(yaml: """
        discord:
          allowed_channels:
            - '123456789'
            - general
        """)
        #expect(cfg.gatewayPlatforms["discord"]?.allowedChannels == ["123456789", "general"])
        #expect(GatewayAllowlistKind.kind(for: "discord")?.yamlKey == "allowed_channels")
    }

    // MARK: - M8 — platform rows carry their own floor

    /// Each id added in the B4 roster sweep exists from a different Hermes
    /// version. Offering all ten on every host puts channels in the list
    /// that the host has no adapter for; each row's floor was walked across
    /// EVERY tag over both `gateway/platforms/` and `plugins/platforms/`.
    @Test func addedPlatformRowsCarryTheirVerifiedFloors() {
        func floor(_ name: String) -> HermesCapabilities.SemVer? {
            KnownPlatforms.all.first { $0.name == name }?.minimumVersion
        }
        // At or below Scarf's oldest supported host — no gate at all.
        for name in ["dingtalk", "sms", "api_server", "wecom"] {
            #expect(floor(name) == nil, "\(name) predates the gate")
        }
        // `bluebubbles` really lands at 0.9.0, but the ROW predates the
        // sweep (it shipped as `imessage`), so gating it would remove a row
        // users already see on an undetected host — C1 cuts the other way.
        #expect(floor("bluebubbles") == nil)
        #expect(floor("weixin") == .init(major: 0, minor: 9, patch: 0))
        #expect(floor("qqbot") == .init(major: 0, minor: 10, patch: 0))
        #expect(floor("irc") == .init(major: 0, minor: 12, patch: 0))
        #expect(floor("msgraph_webhook") == .init(major: 0, minor: 14, patch: 0))
        #expect(floor("photon") == .init(major: 0, minor: 17, patch: 0))
    }

    @Test func aRowIsHiddenBelowItsFloorAndOnAnUndetectedHost() {
        let photon = KnownPlatforms.all.first { $0.name == "photon" }!
        let dingtalk = KnownPlatforms.all.first { $0.name == "dingtalk" }!
        #expect(!photon.isAvailable(on: .empty))
        #expect(!photon.isAvailable(on: HermesCapabilities.parseLine("Hermes Agent v0.16.0 (2026.6.5)")))
        #expect(photon.isAvailable(on: HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)")))
        #expect(photon.isAvailable(on: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")))
        // A floorless row is visible everywhere, undetected hosts included.
        #expect(dingtalk.isAvailable(on: .empty))
    }
}
