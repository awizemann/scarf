import Testing
import Foundation
@testable import ScarfCore

/// Wave B4 of the Hermes v0.20 parity plan — five independent fixes:
/// platform-id corrections (`teams`, `google_chat`) + Buzz roster addition,
/// google_chat allowlist removal, global busy-ack key, dead skills `--yes`
/// flag removal, and the runtime-footer key rename.
@Suite("Hermes v0.20 parity — Wave B4")
struct HermesV020ParityWaveB4Tests {

    // MARK: - Platform roster

    @Test func rosterUsesRealHermesPlatformIds() {
        let names = Set(KnownPlatforms.all.map(\.name))
        #expect(names.contains("teams"))
        #expect(names.contains("google_chat"))
        #expect(names.contains("buzz"))
        // The hyphenated forms match nothing in Hermes and must be gone.
        #expect(!names.contains("microsoft-teams"))
        #expect(!names.contains("google-chat"))
        #expect(!names.contains("googlechat"))
    }

    @Test func buzzRosterEntry() {
        let buzz = KnownPlatforms.all.first { $0.name == "buzz" }
        #expect(buzz?.displayName == "Buzz")
        #expect(KnownPlatforms.icon(for: "buzz") == buzz?.icon)
    }

    @Test func iconLookupAcceptsLegacySpellings() {
        // Callers still holding pre-fix identifiers keep resolving icons.
        #expect(KnownPlatforms.icon(for: "teams") == KnownPlatforms.icon(for: "microsoft-teams"))
        #expect(KnownPlatforms.icon(for: "google_chat") == KnownPlatforms.icon(for: "google-chat"))
    }

    // MARK: - Runtime footer key (display.runtime_footer.enabled)

    @Test func runtimeFooterReadsRealKey() {
        let cfg = HermesConfig(yaml: """
        display:
          runtime_footer:
            enabled: true
        """)
        #expect(cfg.runtimeMetadataFooter == true)
    }

    @Test func runtimeFooterFallsBackToLegacyScarfKey() {
        // Older Scarf builds wrote the nonexistent agent.runtime_metadata_footer;
        // configs Scarf itself wrote must keep their setting on read.
        let cfg = HermesConfig(yaml: """
        agent:
          runtime_metadata_footer: true
        """)
        #expect(cfg.runtimeMetadataFooter == true)
    }

    @Test func runtimeFooterRealKeyWinsOverLegacy() {
        let cfg = HermesConfig(yaml: """
        agent:
          runtime_metadata_footer: true
        display:
          runtime_footer:
            enabled: false
        """)
        #expect(cfg.runtimeMetadataFooter == false)
    }

    @Test func runtimeFooterDefaultsOff() {
        #expect(HermesConfig(yaml: "").runtimeMetadataFooter == false)
    }

    // MARK: - Global busy ack (display.busy_ack_enabled)

    @Test func displayBusyAckParsesGlobalKey() {
        let cfg = HermesConfig(yaml: """
        display:
          busy_ack_enabled: false
        """)
        #expect(cfg.displayBusyAckEnabled == false)
        // Server default is true when the key is absent.
        #expect(HermesConfig(yaml: "").displayBusyAckEnabled == true)
    }

    // MARK: - agent.max_turns absent-key sentinel + capability-driven display

    /// The parser must NOT bake in either host generation's default —
    /// Hermes's server default changed at v0.20 (60 → 500), so an absent
    /// key parses to the 0 sentinel and display surfaces resolve it per
    /// capabilities via `displayMaxTurns(capabilities:)`.
    @Test func maxTurnsAbsentKeyParsesToSentinelAndDisplayFollowsCapabilities() {
        let absent = HermesConfig(yaml: "")
        #expect(absent.maxTurns == 0)
        #expect(absent.displayMaxTurns(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")) == 500)
        #expect(absent.displayMaxTurns(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.20)")) == 60)
        #expect(absent.displayMaxTurns(capabilities: .empty) == 60)
        let cfg = HermesConfig(yaml: """
        agent:
          max_turns: 42
        """)
        #expect(cfg.maxTurns == 42)
        // Explicit value wins regardless of host generation.
        #expect(cfg.displayMaxTurns(capabilities: .empty) == 42)
    }

    // MARK: - Skills CLI argv (no --yes; it never existed)

    @Test func skillsUninstallArgvHasNoYesFlag() {
        let args = SkillsViewModel.uninstallArgs("honcho")
        #expect(args == ["skills", "uninstall", "honcho"])
        #expect(!args.contains("--yes"))
        // Uninstall confirms via stdin prompt; EOF means "n", so a "y"
        // line must be fed for the non-interactive invocation to proceed.
        #expect(SkillsViewModel.uninstallStdin == "y\n")
    }

    @Test func skillsUpdateArgvHasNoYesFlagAndNoName() {
        // Omitting the optional name positional updates all outdated skills.
        #expect(SkillsViewModel.updateAllArgs == ["skills", "update"])
    }

    // MARK: - google_chat allowlist removal (YAML parse side)

    @Test func googleChatBlockDoesNotProduceAllowlistEntry() {
        // The adapter never reads allowed_channels; the parser no longer
        // materialises a gatewayPlatforms entry from a google-chat block.
        let cfg = HermesConfig(yaml: """
        google-chat:
          allowed_channels:
            - spaces/AAA
        """)
        #expect(cfg.gatewayPlatforms["google-chat"] == nil)
        #expect(cfg.gatewayPlatforms["google_chat"] == nil)
    }
}
