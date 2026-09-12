import Foundation
import Testing
@testable import ScarfCore

// MARK: - P51b finding 1: mattermost's `require_mention` read and write move together

/// `require_mention` is a `_SHARED_KEYS` member for every platform
/// (`gateway/config_loader.py:197-213` @ `v2026.9.7`), so Hermes bridges it
/// into `extra` from whichever section `platform_section` picks (`:171-180`)
/// — a top-level `mattermost:` block if there is one, otherwise the nested
/// `platforms.mattermost` / `gateway.platforms.mattermost` block.
///
/// P51 made `MattermostSetupViewModel` a config WRITER of this key and left
/// it on the bare top-level spelling, with a reader (`HermesConfig+YAML`) that
/// matched. The pair was internally consistent and externally wrong: on a
/// nested-only host the bare write CREATES the top-level block, which
/// `platform_section` then takes as the bridge source, so every
/// `platforms.mattermost.<shared key>` beside it stops reaching `extra` —
/// P46b's "leaving a write on its bare spelling is not neutral just because
/// its reader is", and the same remedy (option (b)): move the READER onto
/// `sharedPlatformScalar` and let the write onto `bridgeResolvedKeys`, so the
/// value lands wherever the bridge source already is and creates nothing.
@Suite("P51b · mattermost require_mention resolves the bridge")
struct MattermostRequireMentionBridgeP51bTests {

    private func settings(_ yaml: String) -> MattermostSettings {
        HermesConfig(yaml: yaml).mattermost
    }

    private static let nestedOnly = """
    platforms:
      mattermost:
        require_mention: false
        reply_to_mode: first
    """

    /// The read half. Without the fix this is `nil` / `true`: the flat
    /// `values["mattermost.require_mention"]` lookup cannot see a nested key.
    @Test("a nested-only config's value is read")
    func nestedValueIsRead() {
        let s = settings(Self.nestedOnly + "\n")
        #expect(s.requireMentionIsSet == false)
        #expect(s.requireMention == false)
    }

    /// The write half. Without the pair on `bridgeResolvedKeys`,
    /// `split(key:)` returns `nil` and the key stays bare — creating the
    /// top-level block.
    @Test("the write lands on the bridge source, not a fresh top-level block")
    func writeMovesOntoTheBridgeSource() {
        let key = "mattermost.require_mention"
        #expect(HermesPlatformSharedKeys.split(key: key) != nil)
        let resolved = HermesPlatformSharedKeys.resolved(
            [key: "false"],
            configText: Self.nestedOnly + "\n"
        )
        #expect(resolved["platforms.mattermost.require_mention"] == "false",
                "the toggle still creates a top-level mattermost block: \(resolved)")
        #expect(resolved[key] == nil)
    }

    /// A top-level block already present stays the target — the bridge source
    /// is whatever Hermes would pick, not a preference for nesting.
    @Test("a top-level block keeps the bare spelling")
    func topLevelBlockKeepsTheBareSpelling() {
        let resolved = HermesPlatformSharedKeys.resolved(
            ["platforms.mattermost.require_mention": "false"],
            configText: "mattermost:\n  reply_mode: off\n"
        )
        #expect(resolved["mattermost.require_mention"] == "false")
        #expect(resolved["platforms.mattermost.require_mention"] == nil)
    }

    /// The whole point, end to end — and the damage the bare write does.
    /// The host is nested-only and carries a SIBLING shared key
    /// (`reply_in_thread`). Applying the resolved batch must leave both
    /// readable. Without the fix the toggle lands at bare
    /// `mattermost.require_mention`, which creates the top-level block
    /// `platform_section` then bridges from — and the sibling, still nested,
    /// stops reaching `extra` (`gateway/config_loader.py:171-180`,
    /// `:249-283` @ `v2026.9.7`).
    @Test("the write does not un-bridge the nested sibling beside it")
    func theSiblingSurvivesTheWrite() throws {
        let before = """
        platforms:
          mattermost:
            reply_in_thread: true
            reply_to_mode: first
        """
        let resolved = HermesPlatformSharedKeys.resolved(
            ["mattermost.require_mention": "false"],
            configText: before + "\n"
        )
        #expect(resolved.count == 1)
        let target = try #require(resolved.keys.first)
        // What `hermes config set <target> false` leaves on disk.
        let after = target.hasPrefix("platforms.")
            ? before + "\n    require_mention: false\n"
            : before + "\nmattermost:\n  require_mention: false\n"
        #expect(settings(after).requireMentionIsSet == false,
                "the value written at \(target) does not read back")
        // Hermes's own bridge source after the write.
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
                    platform: "mattermost", configText: after) == "platforms.mattermost",
                "the write created a top-level block and un-bridged platforms.mattermost.*")
    }
}

