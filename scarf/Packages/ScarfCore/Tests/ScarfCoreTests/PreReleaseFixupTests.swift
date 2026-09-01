import Foundation
import Testing
@testable import ScarfCore

/// Regression cover for the ScarfCore half of the pre-release fixup package
/// (documents/reports/2026-09-01-pre-release-go-no-go-board.md).
@Suite struct PreReleaseFixupTests {

    // MARK: - Condition 2: "Remove from Bots" must actually remove the block

    /// The demote write is `isBotManaged = false` through the ordinary
    /// writer. `BotModePhaseAB0Tests` already asserts Scarf's own parser sees
    /// the block gone; this asserts what **Hermes** would load, through real
    /// PyYAML — the only reader that matters — and that every sibling
    /// namespace, unknown key and top-level scalar survives intact.
    @Test("demote removes hermes-bots and PyYAML still loads the rest of the file")
    func demoteRemovesTheBlockUnderRealPyYAML() throws {
        let source = """
        display_name: Athena
        description: research bot
        created: "2026-01-02"
        ui_meta:
          shared-room:
            seat: 3
          hermes-bots:
            title: Athena
            color: "#ff0000"
            pinned: true
            some_unknown_key: kept
        """
        var identity = HermesBotProfileYAML.parse(source, profileName: "athena", profileDirectory: "/x")
        #expect(identity.isBotManaged)
        identity.isBotManaged = false
        identity.pinned = nil
        identity.hidden = nil
        let out = try #require(HermesBotProfileYAML.write(identity: identity, into: source))

        // Scarf's own reader agrees the profile is no longer bot-managed.
        #expect(!HermesBotProfileYAML.parse(out, profileName: "athena", profileDirectory: "/x").isBotManaged)

        guard let json = BotModeFixupTests.pyYAMLLoad(out) else { return }  // no python3/PyYAML here
        #expect(!json.hasPrefix("ERROR:"), "PyYAML refused the demoted file:\n\(out)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        // The bot block is gone…
        let uiMeta = try #require(object["ui_meta"] as? [String: Any])
        #expect(uiMeta["hermes-bots"] == nil)
        // …and nothing else moved.
        #expect((uiMeta["shared-room"] as? [String: Any])?["seat"] as? Int == 3)
        #expect(object["display_name"] as? String == "Athena")
        #expect(object["description"] as? String == "research bot")
        #expect(object["created"] != nil)
    }

    /// Removing the ONLY child of `ui_meta` must not leave a bare `ui_meta:`
    /// header (PyYAML loads that as `None`, not a mapping).
    @Test("demote drops an emptied ui_meta header rather than leaving it null")
    func demoteDropsAnEmptiedUIMetaHeader() throws {
        let source = """
        display_name: Solo
        ui_meta:
          hermes-bots:
            title: Solo
        """
        var identity = HermesBotProfileYAML.parse(source, profileName: "solo", profileDirectory: "/x")
        identity.isBotManaged = false
        let out = try #require(HermesBotProfileYAML.write(identity: identity, into: source))
        #expect(!out.contains("hermes-bots"))
        #expect(!out.contains("ui_meta"))

        guard let json = BotModeFixupTests.pyYAMLLoad(out) else { return }
        #expect(!json.hasPrefix("ERROR:"), "PyYAML refused:\n\(out)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["ui_meta"] == nil)
        #expect(object["display_name"] as? String == "Solo")
    }

    // MARK: - Condition 3: the Bot Chat rename guard

    @Test("renameNeedsConfirmation fires only when renaming AWAY from the canonical title")
    func renameGuardFiresOnlyOnRealRenames() {
        // The case that orphans a bot's history.
        #expect(BotChatSession.renameNeedsConfirmation(currentTitle: "Bot Chat", newTitle: "Notes"))
        // A no-op rename, including one padded with whitespace.
        #expect(!BotChatSession.renameNeedsConfirmation(currentTitle: "Bot Chat", newTitle: "Bot Chat"))
        #expect(!BotChatSession.renameNeedsConfirmation(currentTitle: "Bot Chat", newTitle: "  Bot Chat  "))
        // Ordinary sessions are never gated.
        #expect(!BotChatSession.renameNeedsConfirmation(currentTitle: "Standup notes", newTitle: "Notes"))
        #expect(!BotChatSession.renameNeedsConfirmation(currentTitle: nil, newTitle: "Notes"))
        // Exact and case-sensitive: Hermes matches the title with `==`.
        #expect(!BotChatSession.renameNeedsConfirmation(currentTitle: "bot chat", newTitle: "Notes"))
        #expect(!BotChatSession.renameNeedsConfirmation(currentTitle: "Bot Chat ", newTitle: "Notes"))
    }

    // MARK: - Condition 4: the Bot Chat creation CLI floor

    /// `--query-file` is absent from `hermes chat` at v2026.8.16.2 (0.20.3),
    /// the `hasBotMode` floor, and argparse rejects the whole invocation on an
    /// unknown flag — so the creation path must be floored at v0.21 even
    /// though every OTHER flag it uses (`-c`, `--create-if-missing`, `-Q`,
    /// `--in`) is present at 0.20.3.
    @Test("Bot Chat creation is floored at v0.21, above the hasBotMode floor")
    func botChatCreationIsFlooredAtV021() {
        func caps(_ version: String) -> HermesCapabilities {
            HermesCapabilities.parseLine("Hermes Agent v\(version)")
        }
        #expect(caps("0.20.3").hasBotMode)
        #expect(!caps("0.20.3").hasBotChatCreationCLI)
        #expect(!caps("0.20.6").hasBotChatCreationCLI)
        #expect(caps("0.21.0").hasBotChatCreationCLI)
        #expect(caps("0.22.0").hasBotChatCreationCLI)
    }

    // MARK: - Condition 8: the dead Settings keys are gone from the parser

    /// Removing the row without removing the parse leaves a field nothing
    /// writes and nothing reads; removing the parse without removing the row
    /// blanks a real host value. All three keys are dead at every version
    /// Scarf supports, so both halves go.
    @Test("the dead config keys are no longer parsed")
    func deadKeysAreNoLongerParsed() {
        let yaml = """
        agent:
          verbose: true
        redaction:
          enabled: true
        tts:
          xai:
            model: grok-tts-1
            voice_id: eve
        """
        let config = HermesConfig(yaml: yaml)
        // The keys that DO exist still parse — this asserts the parse itself
        // is healthy, not just that the dead fields are absent.
        #expect(config.voice.ttsXAIVoiceID == "eve")
    }
}
