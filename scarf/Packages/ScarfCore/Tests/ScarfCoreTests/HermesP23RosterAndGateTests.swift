import Testing
@testable import ScarfCore

/// P23 of the round-2 whole-surface audit: the platform roster's gating was
/// inconsistent at the SAME floor — `photon` carried `photonPlatformFloor`
/// (0.17) while `whatsapp_cloud`, the same v0.17 adapter, was ungated, and
/// every other `-- v0.1x additions` group was ungated the same way.
///
/// Alan's round-2 decision 6 (2026-09-10): gate `whatsapp_cloud` at its v0.17
/// floor and audit the rest of the roster for the same inconsistency; the
/// standing "a pre-existing row with no parity-cycle floor attribution stays
/// ungated" exception (`bluebubbles`) holds.
///
/// Every floor below was walked across ALL 32 `v2026.*` tags with
/// `git ls-tree -r --name-only <tag>` over `gateway/platforms/<name>.py`,
/// `gateway/platforms/<name>/` and `plugins/platforms/<name>/`, with the
/// release read from `pyproject.toml` AT the tag.
@Suite struct HermesP23RosterAndGateTests {

    private func row(_ name: String) -> HermesToolPlatform {
        KnownPlatforms.all.first { $0.name == name }!
    }

    private func caps(_ line: String) -> HermesCapabilities {
        HermesCapabilities.parseLine(line)
    }

    /// The floors, and the tag each was found at.
    @Test func parityCycleRowsCarryTheirVerifiedFloors() {
        let expected: [String: HermesCapabilities.SemVer] = [
            // v2026.4.30 = 0.12.0
            "yuanbao": .init(major: 0, minor: 12, patch: 0),
            "teams": .init(major: 0, minor: 12, patch: 0),
            // v2026.5.7 = 0.13.0
            "google_chat": .init(major: 0, minor: 13, patch: 0),
            // v2026.5.16 = 0.14.0
            "line": .init(major: 0, minor: 14, patch: 0),
            "simplex": .init(major: 0, minor: 14, patch: 0),
            // v2026.5.28 = 0.15.0
            "ntfy": .init(major: 0, minor: 15, patch: 0),
            // v2026.6.19 = 0.17.0 — the floor `photon` already had
            "whatsapp_cloud": .init(major: 0, minor: 17, patch: 0),
            // v2026.7.30 = 0.19.1, NOT 0.20 as the roster comment claimed
            "buzz": .init(major: 0, minor: 19, patch: 1),
            // P29: the four rows that carried INLINE literals rather than a
            // shared floor constant, which is the rule this suite records.
            // Walked the same way: `gateway/platforms/weixin.py` first at
            // v2026.4.13 (0.9.0), absent v2026.4.8 (0.8.0);
            // `gateway/platforms/qqbot.py` first at v2026.4.16 (0.10.0),
            // absent v2026.4.13; `plugins/platforms/irc/` first at
            // v2026.4.30 (0.12.0), absent v2026.4.23 (0.11.0);
            // `gateway/platforms/msgraph_webhook.py` first at v2026.5.16
            // (0.14.0), absent v2026.5.7 (0.13.0).
            "weixin": .init(major: 0, minor: 9, patch: 0),
            "qqbot": .init(major: 0, minor: 10, patch: 0),
            "irc": .init(major: 0, minor: 12, patch: 0),
            "msgraph_webhook": .init(major: 0, minor: 14, patch: 0)
        ]
        for (name, floor) in expected {
            #expect(row(name).minimumVersion == floor, "\(name)")
        }
    }

    /// The roster row and its capability flag must read the SAME constant, so
    /// a future re-floor cannot move one without the other.
    @Test func rowFloorsAreSharedWithTheirCapabilityFlags() {
        #expect(row("whatsapp_cloud").minimumVersion == HermesCapabilities.whatsAppCloudPlatformFloor)
        #expect(row("photon").minimumVersion == HermesCapabilities.photonPlatformFloor)
        #expect(row("teams").minimumVersion == HermesCapabilities.teamsPlatformFloor)
        #expect(row("yuanbao").minimumVersion == HermesCapabilities.yuanbaoPlatformFloor)
        #expect(row("google_chat").minimumVersion == HermesCapabilities.googleChatPlatformFloor)
        #expect(row("line").minimumVersion == HermesCapabilities.linePlatformFloor)
        #expect(row("simplex").minimumVersion == HermesCapabilities.simplexPlatformFloor)
        #expect(row("ntfy").minimumVersion == HermesCapabilities.ntfyPlatformFloor)
        #expect(row("buzz").minimumVersion == HermesCapabilities.buzzPlatformFloor)
        // P29: these four used to be inline `.init(major:…)` literals on the
        // row, so there was nothing for a re-floor to keep in step with.
        #expect(row("irc").minimumVersion == HermesCapabilities.ircPlatformFloor)
        #expect(row("weixin").minimumVersion == HermesCapabilities.weixinPlatformFloor)
        #expect(row("qqbot").minimumVersion == HermesCapabilities.qqbotPlatformFloor)
        #expect(row("msgraph_webhook").minimumVersion == HermesCapabilities.msgraphWebhookPlatformFloor)

        // And each flag agrees with its row at the boundary.
        let below = caps("Hermes Agent v0.16.0 (2026.6.5)")
        let at = caps("Hermes Agent v0.17.0 (2026.6.19)")
        #expect(!below.hasWhatsAppCloudPlatform)
        #expect(at.hasWhatsAppCloudPlatform)
        #expect(!row("whatsapp_cloud").isAvailable(on: below))
        #expect(row("whatsapp_cloud").isAvailable(on: at))
    }

    /// Each of the four newly-shared floors, at its own boundary and one
    /// release below it.
    @Test func theFourFormerlyInlineFloorsGateAtTheirOwnBoundary() {
        let cases: [(String, String, String)] = [
            ("weixin", "Hermes Agent v0.8.0 (2026.4.8)", "Hermes Agent v0.9.0 (2026.4.13)"),
            ("qqbot", "Hermes Agent v0.9.0 (2026.4.13)", "Hermes Agent v0.10.0 (2026.4.16)"),
            ("irc", "Hermes Agent v0.11.0 (2026.4.23)", "Hermes Agent v0.12.0 (2026.4.30)"),
            ("msgraph_webhook", "Hermes Agent v0.13.0 (2026.5.7)", "Hermes Agent v0.14.0 (2026.5.16)")
        ]
        for (name, belowLine, atLine) in cases {
            #expect(!row(name).isAvailable(on: caps(belowLine)), "\(name) below its floor")
            #expect(row(name).isAvailable(on: caps(atLine)), "\(name) at its floor")
            // At the target everything is on; on an undetected host a gated row
            // is hidden (C1: a host we cannot version behaves as the oldest).
            #expect(row(name).isAvailable(on: caps("Hermes Agent v0.21.1 (2026.9.7)")))
            #expect(!row(name).isAvailable(on: .empty), "\(name) on an undetected host")
        }
    }

    /// The inconsistency the phase exists to fix: at a v0.13 host the two
    /// v0.17 rows must behave identically.
    @Test func whatsAppCloudAndPhotonAgreeOnEveryHost() {
        for line in [
            "Hermes Agent v0.13.0 (2026.5.7)",
            "Hermes Agent v0.16.0 (2026.6.5)",
            "Hermes Agent v0.17.0 (2026.6.19)",
            "Hermes Agent v0.21.1 (2026.9.7)"
        ] {
            let c = caps(line)
            #expect(row("whatsapp_cloud").isAvailable(on: c) == row("photon").isAvailable(on: c), "\(line)")
        }
        #expect(!row("whatsapp_cloud").isAvailable(on: .empty))
    }

    /// The ungated set, and why. Changing any of these is a product decision,
    /// not a floor correction.
    @Test func preExistingRowsStayUngated() {
        // `bluebubbles` really lands at 0.9.0, but the ROW shipped in Scarf
        // as `imessage` from long before this cycle; enforcing its floor
        // would remove a row users already see whenever the probe has not
        // answered. Decision 6's standing exception.
        #expect(row("bluebubbles").minimumVersion == nil)
        #expect(row("bluebubbles").isAvailable(on: .empty))
        // The original core roster: every one of these adapters predates
        // v0.6.0, Scarf's supported minimum, so a floor would be ceremony.
        for name in ["cli", "telegram", "discord", "slack", "whatsapp", "signal",
                     "email", "homeassistant", "webhook", "matrix", "feishu",
                     "mattermost"] {
            #expect(row(name).minimumVersion == nil, "\(name)")
            #expect(row(name).isAvailable(on: .empty), "\(name)")
        }
    }

    /// A v0.12 host sees exactly the rows a v0.12 Hermes can listen on.
    @Test func aV012HostIsOfferedOnlyWhatItHas() {
        let v012 = caps("Hermes Agent v0.12.0 (2026.4.30)")
        let visible = Set(KnownPlatforms.all.filter { $0.isAvailable(on: v012) }.map(\.name))
        // Present at 0.12.
        #expect(visible.contains("yuanbao"))
        #expect(visible.contains("teams"))
        #expect(visible.contains("irc"))
        // Not yet shipped at 0.12 — previously offered anyway.
        for name in ["google_chat", "line", "simplex", "ntfy", "whatsapp_cloud",
                     "buzz", "photon", "msgraph_webhook"] {
            #expect(!visible.contains(name), "\(name)")
        }
    }

    /// Every row in the roster is visible at the target tag — a floor typo
    /// that hid a row from a current host would fail here.
    @Test func everyRowIsVisibleAtTheTargetTag() {
        let target = caps("Hermes Agent v0.21.1 (2026.9.7)")
        for platform in KnownPlatforms.all {
            #expect(platform.isAvailable(on: target), "\(platform.name)")
        }
    }

    /// Gating a row that users already see is the one real risk in decision
    /// 6, so `isVisible` carries the widen-for-current hatch: a CONFIGURED
    /// platform stays listed even when the probe failed, and an
    /// UNCONFIGURED one below the floor stays hidden.
    @Test func aConfiguredRowSurvivesAFailedProbe() {
        let ntfy = row("ntfy")
        #expect(!ntfy.isVisible(on: .empty, isConfigured: false))
        #expect(ntfy.isVisible(on: .empty, isConfigured: true))
        // And below a real floor, not just on an undetected host.
        let v014 = caps("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(!ntfy.isVisible(on: v014, isConfigured: false))
        #expect(ntfy.isVisible(on: v014, isConfigured: true))
        // At or above the floor, configured-ness is irrelevant.
        let v015 = caps("Hermes Agent v0.15.0 (2026.5.28)")
        #expect(ntfy.isVisible(on: v015, isConfigured: false))
        // A floorless row is visible either way.
        #expect(row("telegram").isVisible(on: .empty, isConfigured: false))
    }

    // MARK: - WebTools widen-for-current

    /// `hasWebToolsBackendSplit == false` used to render the combined
    /// `web.backend` row with no escape hatch, so an UNDETECTED host
    /// (`.empty` — the probe failed, which is not the same as "old host")
    /// whose config already sets `web.search_backend` showed "Automatic" and
    /// any pick wrote a key the override shadows. Mirrors
    /// `HermesServiceTier.editorStyle`.
    @Test func undetectedHostWithAnOverrideSetGetsTheSplitEditor() {
        #expect(WebToolsBackendRoster.editorStyle(.empty) == .combined)
        #expect(WebToolsBackendRoster.editorStyle(.empty, searchBackend: "exa") == .split)
        #expect(WebToolsBackendRoster.editorStyle(.empty, extractBackend: "firecrawl") == .split)
        #expect(WebToolsBackendRoster.editorStyle(
            .empty, searchBackend: "ddgs", extractBackend: "exa") == .split)
    }

    /// C1: a genuine pre-v0.13 host still gets the single row it always had.
    /// The combined editor never writes the override keys, so no config Scarf
    /// could have produced on such a host reaches the widening branch.
    @Test func aGenuinePreV013HostKeepsTheCombinedEditor() {
        let v012 = caps("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(!v012.hasWebToolsBackendSplit)
        #expect(WebToolsBackendRoster.editorStyle(v012) == .combined)
        // A hand-edited override on a v0.12 host is the one case that flips
        // it, and showing the user the key they actually set beats hiding it.
        #expect(WebToolsBackendRoster.editorStyle(v012, searchBackend: "exa") == .split)
    }

    /// A detected v0.13+ host is always split, override keys or not.
    @Test func aDetectedSplitHostIsAlwaysSplit() {
        let v013 = caps("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(WebToolsBackendRoster.editorStyle(v013) == .split)
        #expect(WebToolsBackendRoster.editorStyle(v013, searchBackend: "exa") == .split)
    }
}
