import Testing
import Foundation
@testable import ScarfCore

/// B05 sweep of S07-F4: settings Scarf writes to config.yaml that Hermes
/// reads `.env`-first. Bands and readers are cited on each `Setting`.
@Suite struct EnvFirstSettingsB05Tests {

    static let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")

    @Test func everySpellingFindsTheSetting() {
        #expect(HermesEnvFirstSettings.setting(forConfigKey: "discord.require_mention")?.envVar == "DISCORD_REQUIRE_MENTION")
        #expect(HermesEnvFirstSettings.setting(forConfigKey: "platforms.discord.require_mention")?.envVar == "DISCORD_REQUIRE_MENTION")
        #expect(HermesEnvFirstSettings.setting(forConfigKey: "platforms.ntfy.extra.publish_topic")?.envVar == "NTFY_PUBLISH_TOPIC")
        #expect(HermesEnvFirstSettings.setting(forConfigKey: "matrix.allowed_rooms")?.envVar == "MATRIX_ALLOWED_ROOMS")
        // Config-first readers are not managed.
        #expect(HermesEnvFirstSettings.setting(forConfigKey: "platforms.slack.require_mention") == nil)
        #expect(HermesEnvFirstSettings.setting(forConfigKey: "discord.free_response_channels") == nil)
        #expect(HermesEnvFirstSettings.setting(forConfigKey: "platforms.signal.extra.require_mention") == nil)
    }

    /// v0.21.3 flip (`extra_or_secret`, `_shared.py:106-128`): config.yaml
    /// wins below it, a non-blank env value wins from it.
    @Test func theV0213BandFollowsTheHost() {
        let env = ["DISCORD_REQUIRE_MENTION": "false"]
        #expect(HermesEnvFirstSettings.winningEnvValue(configKey: "discord.require_mention", env: env, capabilities: Self.v0212) == nil)
        #expect(HermesEnvFirstSettings.winningEnvValue(configKey: "discord.require_mention", env: env, capabilities: Self.v0213) == "false")
        #expect(HermesEnvFirstSettings.winningEnvValue(
            configKey: "discord.require_mention", env: ["DISCORD_REQUIRE_MENTION": " "], capabilities: Self.v0213) == nil,
            "a blank value is unset")
    }

    /// Env-only readers behind a fill-if-unset bridge: `.env` has always won.
    @Test func theAllHostsBandWinsEverywhere() {
        for key in ["discord.reactions", "discord.auto_thread", "telegram.reactions",
                    "matrix.auto_thread", "matrix.dm_mention_threads", "discord.allowed_channels"] {
            let s = HermesEnvFirstSettings.setting(forConfigKey: key)!
            #expect(HermesEnvFirstSettings.winningEnvValue(
                configKey: key, env: [s.envVar: "true"], capabilities: .empty) == "true", "\(key)")
        }
    }

    @Test func saveRemovesEveryManagedLineWhateverItsValue() {
        let env = ["DISCORD_REACTIONS": "", "DISCORD_REQUIRE_MENTION": "true", "DISCORD_BOT_TOKEN": "x"]
        #expect(HermesEnvFirstSettings.envLinesToRemove(
            configKeys: ["discord.require_mention", "discord.reactions", "discord.free_response_channels"], env: env)
            == ["DISCORD_REACTIONS", "DISCORD_REQUIRE_MENTION"])
    }

    @Test func parsersMatchHermes() {
        #expect(HermesEnvFirstSettings.denyFalse("OFF") == false)
        #expect(HermesEnvFirstSettings.denyFalse("maybe"))
        #expect(HermesEnvFirstSettings.truthy("on"))
        #expect(!HermesEnvFirstSettings.truthy("maybe"))
        #expect(HermesEnvFirstSettings.csv(" a, ,b ") == ["a", "b"])
    }

    @Test func minimalEnvParse() {
        let env = HermesEnvFirstSettings.parseEnv("""
        # comment
        export DISCORD_REACTIONS=false
        TELEGRAM_REQUIRE_MENTION="yes"
        MATRIX_ALLOWED_ROOMS=!a:x,!b:y # rooms
        EMPTY=
        """)
        #expect(env["DISCORD_REACTIONS"] == "false")
        #expect(env["TELEGRAM_REQUIRE_MENTION"] == "yes")
        #expect(env["MATRIX_ALLOWED_ROOMS"] == "!a:x,!b:y")
        #expect(env["EMPTY"] == "")
    }
}
