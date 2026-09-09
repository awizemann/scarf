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

    /// `agent.runtime_metadata_footer` exists in NO supported Hermes version —
    /// only some long-obsolete Scarf build ever wrote it. The fallback read
    /// was removed, so the key is now inert: it must not turn the footer on,
    /// and it must not override the real key.
    @Test func runtimeFooterIgnoresDeadLegacyScarfKey() {
        let legacyOnly = HermesConfig(yaml: """
        agent:
          runtime_metadata_footer: true
        """)
        #expect(legacyOnly.runtimeMetadataFooter == false)

        let realKeyWins = HermesConfig(yaml: """
        agent:
          runtime_metadata_footer: true
        display:
          runtime_footer:
            enabled: false
        """)
        #expect(realKeyWins.runtimeMetadataFooter == false)

        // And the dead key can't suppress a real `true` either.
        let realKeyOn = HermesConfig(yaml: """
        agent:
          runtime_metadata_footer: false
        display:
          runtime_footer:
            enabled: true
        """)
        #expect(realKeyOn.runtimeMetadataFooter == true)
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

    /// v0.20.5 flipped the server default again — 500 → unlimited
    /// (`config_defaults.py`, `TURN_LIMIT_UNLIMITED`, which accepts
    /// `none/unlimited/inf/0/-1`). The absent key must therefore resolve to
    /// the unlimited sentinel on v0.20.5+, 500 on v0.20.0–v0.20.4 and 60 on
    /// older hosts.
    @Test func maxTurnsAbsentKeyResolvesUnlimitedOnV0205Hosts() {
        let absent = HermesConfig(yaml: "")
        let v0205 = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
        let v0204 = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.12)")
        let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        let v0192 = HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.20)")

        #expect(absent.displayMaxTurns(capabilities: v0205) == HermesConfig.maxTurnsUnlimited)
        #expect(absent.displayMaxTurns(capabilities: v0204) == 500)
        #expect(absent.displayMaxTurns(capabilities: v0200) == 500)
        #expect(absent.displayMaxTurns(capabilities: v0192) == 60)
        // A later patch/minor keeps the unlimited default.
        #expect(absent.displayMaxTurns(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.9.1)")) == HermesConfig.maxTurnsUnlimited)

        // Text form: "Unlimited" only where the resolved value is the
        // sentinel; every other tier renders the plain number.
        #expect(absent.displayMaxTurnsText(capabilities: v0205) == "Unlimited")
        #expect(absent.displayMaxTurnsText(capabilities: v0204) == "500")
        #expect(absent.displayMaxTurnsText(capabilities: v0192) == "60")
    }

    /// An explicit `agent.max_turns: 0` is Hermes v0.20.5's own "unlimited"
    /// spelling; it parses to the same sentinel as an absent key and displays
    /// as Unlimited there.
    @Test func maxTurnsExplicitZeroIsUnlimited() {
        let cfg = HermesConfig(yaml: """
        agent:
          max_turns: 0
        """)
        #expect(cfg.maxTurns == HermesConfig.maxTurnsUnlimited)
        let v0205 = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
        #expect(cfg.displayMaxTurnsText(capabilities: v0205) == "Unlimited")
        // A positive explicit value is never "Unlimited", on any host.
        let pinned = HermesConfig(yaml: "agent:\n  max_turns: 250\n")
        #expect(pinned.displayMaxTurnsText(capabilities: v0205) == "250")
    }

    // MARK: - Skills CLI argv (--yes exists from v0.20.5, not before)

    /// L6 — `skills uninstall --yes` was added at v2026.8.19 (0.20.5) and is
    /// consumed as `skip_confirm` (`hermes_cli/skills_hub.py:1324`). Below
    /// that floor argparse exits 2 on the flag and the verb only confirms
    /// through `input()`, so those hosts keep the piped "y" line.
    @Test func skillsUninstallSendsYesOnlyFromItsFloor() {
        let v0204 = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)")
        let v0205 = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
        let v0211 = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

        for old in [HermesCapabilities.empty, v0204] {
            let args = SkillsViewModel.uninstallArgs("honcho", capabilities: old)
            #expect(args == ["skills", "uninstall", "--", "honcho"])
            #expect(!args.contains("--yes"))
            // EOF reads as "n", so the confirmation must be piped.
            #expect(SkillsViewModel.uninstallStdin(capabilities: old) == "y\n")
        }
        for new in [v0205, v0211] {
            #expect(SkillsViewModel.uninstallArgs("honcho", capabilities: new)
                    == ["skills", "uninstall", "--yes", "--", "honcho"])
            // No prompt to answer — a stray "y" would be left on stdin.
            #expect(SkillsViewModel.uninstallStdin(capabilities: new) == nil)
        }
    }

    /// t-ec6d2e6d: the positional is the BARE name (`skill.name`), never the
    /// `<category>/<name>` id, and the verdict is the output, not the exit.
    @Test func skillsUninstallVerdictComesFromOutputNotExitCode() {
        #expect(SkillsViewModel.uninstallArgs("openhue") == ["skills", "uninstall", "--", "openhue"])
        // v0.21.0, verbatim: rejection exits 0.
        let rejected = "Error: 'smart-home/openhue' is not a hub-installed skill (may be a builtin)\n"
        #expect(!SkillsViewModel.uninstallSucceeded(exitCode: 0, output: rejected))
        #expect(SkillsViewModel.uninstallFailureReason(output: rejected)?.hasPrefix("Error:") == true)
        let removed = "Uninstalled 'openhue' from smart-home/openhue\n"
        #expect(SkillsViewModel.uninstallSucceeded(exitCode: 0, output: removed))
        #expect(SkillsViewModel.uninstallFailureReason(output: removed) == nil)
        #expect(!SkillsViewModel.uninstallSucceeded(exitCode: 1, output: removed))
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
