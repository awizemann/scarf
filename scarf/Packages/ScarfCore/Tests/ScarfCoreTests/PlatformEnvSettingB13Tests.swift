import Testing
@testable import ScarfCore

/// B13: platform settings a `.env` line can override. Expected values in the
/// `v2026.9.24` cases were produced by Hermes's own loader and adapter
/// methods (`load_hermes_dotenv` + `load_gateway_config` +
/// `DiscordAdapter`/`TelegramAdapter` getters from
/// `~/.hermes/hermes-agent-v0215/.venv`) against a scratch HERMES_HOME.
@Suite struct PlatformEnvSettingB13Tests {
    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    @Test func flagFloorIsV0213() {
        #expect(Self.v0213.hasEnvFirstPlatformSettings)
        #expect(Self.v0215.hasEnvFirstPlatformSettings)
        #expect(!Self.v0212.hasEnvFirstPlatformSettings)
        #expect(!HermesCapabilities.empty.hasEnvFirstPlatformSettings)
    }

    /// Hermes case A: env + config both set, env wins on v0.21.5.
    @Test func envBeatsConfigOnCurrentHost() {
        let r = PlatformEnvSetting.discordRequireMention.resolve(
            envValue: "false", configValue: true, capabilities: Self.v0215)
        #expect(r.value == false && r.fromEnv)
        let a = PlatformEnvAllowlist.discordAllowedChannels.resolve(
            envValue: "111,222", configItems: ["999"], capabilities: Self.v0215)
        #expect(a.items == ["111", "222"] && a.fromEnv)
        let t = PlatformEnvAllowlist.telegramAllowedChats.resolve(
            envValue: "-100", configItems: ["-200"], capabilities: Self.v0215)
        #expect(t.items == ["-100"] && t.fromEnv)
        let tr = PlatformEnvSetting.telegramReactions.resolve(
            envValue: "true", configValue: false, capabilities: Self.v0215)
        #expect(tr.value && tr.fromEnv)
        let tm = PlatformEnvSetting.telegramRequireMention.resolve(
            envValue: nil, configValue: true, capabilities: Self.v0215)
        #expect(tm.value && !tm.fromEnv)
    }

    /// Before v0.21.3 config.yaml won for require_mention / allowed_chats,
    /// while reactions / auto_thread / allowed_channels were env-first on
    /// every version.
    @Test func olderHostBands() {
        let rm = PlatformEnvSetting.discordRequireMention.resolve(
            envValue: "false", configValue: true, capabilities: Self.v0212)
        #expect(rm.value && !rm.fromEnv)
        let tm = PlatformEnvSetting.telegramRequireMention.resolve(
            envValue: "true", configValue: false, capabilities: Self.v0212)
        #expect(!tm.value && !tm.fromEnv)
        let chats = PlatformEnvAllowlist.telegramAllowedChats.resolve(
            envValue: "-100", configItems: ["-200"], capabilities: Self.v0212)
        #expect(chats.items == ["-200"] && !chats.fromEnv)
        let re = PlatformEnvSetting.discordReactions.resolve(
            envValue: "no", configValue: true, capabilities: Self.v0212)
        #expect(!re.value && re.fromEnv)
        let at = PlatformEnvSetting.discordAutoThread.resolve(
            envValue: "false", configValue: true, capabilities: Self.v0212)
        #expect(!at.value && at.fromEnv)
        let ch = PlatformEnvAllowlist.discordAllowedChannels.resolve(
            envValue: "1", configItems: ["2"], capabilities: Self.v0212)
        #expect(ch.items == ["1"] && ch.fromEnv)
        // Absent config key: env decides on every version.
        let absent = PlatformEnvSetting.discordRequireMention.resolve(
            envValue: "off", configValue: nil, capabilities: Self.v0212)
        #expect(!absent.value && absent.fromEnv)
        let absentList = PlatformEnvAllowlist.telegramAllowedChats.resolve(
            envValue: "-100", configItems: nil, capabilities: Self.v0212)
        #expect(absentList.items == ["-100"] && absentList.fromEnv)
    }

    /// Hermes case C: env only, each adapter's own word set.
    @Test func parseMatchesAdapterWordSets() {
        let caps = Self.v0215
        #expect(!PlatformEnvSetting.discordRequireMention.resolve(envValue: "no", configValue: nil, capabilities: caps).value)
        #expect(!PlatformEnvSetting.discordReactions.resolve(envValue: "off", configValue: nil, capabilities: caps).value)
        #expect(!PlatformEnvSetting.discordAutoThread.resolve(envValue: "0", configValue: nil, capabilities: caps).value)
        #expect(!PlatformEnvSetting.discordHistoryBackfill.resolve(envValue: "false", configValue: nil, capabilities: caps).value)
        #expect(PlatformEnvSetting.telegramRequireMention.resolve(envValue: "yes", configValue: nil, capabilities: caps).value)
        #expect(PlatformEnvSetting.telegramReactions.resolve(envValue: "1", configValue: nil, capabilities: caps).value)
        // Truthy-only sets: an unknown word is OFF; deny-list sets: ON.
        #expect(!PlatformEnvSetting.discordAutoThread.parsed("maybe"))
        #expect(PlatformEnvSetting.discordRequireMention.parsed("maybe"))
    }

    /// Hermes case D: a blank env value is unset — config (or the default) decides.
    @Test func blankEnvIsUnset() {
        let r = PlatformEnvSetting.discordRequireMention.resolve(
            envValue: "  ", configValue: false, capabilities: Self.v0215)
        #expect(!r.value && !r.fromEnv)
        let a = PlatformEnvAllowlist.discordAllowedChannels.resolve(
            envValue: "", configItems: ["5"], capabilities: Self.v0215)
        #expect(a.items == ["5"] && !a.fromEnv)
        let d = PlatformEnvSetting.telegramReactions.resolve(
            envValue: "", configValue: nil, capabilities: Self.v0215)
        #expect(!d.value && !d.fromEnv)
    }

    @Test func envTextParse() {
        let text = """
        # DISCORD_REQUIRE_MENTION=true
        DISCORD_REQUIRE_MENTION="false"
        export TELEGRAM_REACTIONS=true
        DISCORD_BOT_TOKEN=secret
        DISCORD_ALLOWED_CHANNELS='1,2'
        """
        let v = PlatformEnvSetting.envValues(fromEnvText: text, keys: PlatformEnvSetting.envKeys)
        #expect(v == ["DISCORD_REQUIRE_MENTION": "false", "TELEGRAM_REACTIONS": "true",
                      "DISCORD_ALLOWED_CHANNELS": "1,2"])
    }

    /// Presence is what lets the form fall back to `.env` for an absent key.
    @Test func presentKeysParse() {
        let cfg = HermesConfig(yaml: "discord:\n  reactions: false\ntelegram:\n  require_mention: true\n")
        #expect(cfg.discord.presentKeys == ["reactions"])
        #expect(cfg.telegram.presentKeys == ["require_mention"])
        #expect(HermesConfig(yaml: "model:\n  default: x\n").discord.presentKeys.isEmpty)
    }

    @Test func envListAcceptsJSONLiteral() {
        #expect(PlatformEnvAllowlist.items(fromEnv: #"["-100", "-200"]"#) == ["-100", "-200"])
        #expect(PlatformEnvAllowlist.items(fromEnv: "1, 2,,") == ["1", "2"])
    }

    /// B13b. Expected values from Hermes's loader (v0.21.5): env + config
    /// both set → env wins for every key below.
    @Test func matrixNtfySlackMattermostCurrentHost() {
        let c = Self.v0215
        #expect(PlatformEnvSetting.matrixRequireMention.resolve(envValue: "false", configValue: true, capabilities: c) == (false, true))
        #expect(PlatformEnvSetting.matrixAutoThread.resolve(envValue: "false", configValue: true, capabilities: c) == (false, true))
        #expect(PlatformEnvSetting.matrixDMMentionThreads.resolve(envValue: "yes", configValue: nil, capabilities: c) == (true, true))
        #expect(PlatformEnvAllowlist.matrixAllowedRooms.resolve(envValue: "!a:x,!b:x", configItems: ["!z:x"], capabilities: c).items == ["!a:x", "!b:x"])
        #expect(PlatformEnvAllowlist.slackAllowedChannels.resolve(envValue: "C1", configItems: ["C9"], capabilities: c).items == ["C1"])
        #expect(PlatformEnvAllowlist.mattermostAllowedChannels.resolve(envValue: "m1", configItems: ["m9"], capabilities: c).items == ["m1"])
        #expect(PlatformEnvString.resolve(envValue: "envtopic", configValue: "cfgtopic", capabilities: c) == ("envtopic", true))
    }

    /// Before v0.21.3: config wins for require_mention, the three lists and
    /// publish_topic; Matrix auto_thread / dm_mention_threads were env-only.
    @Test func matrixNtfySlackMattermostOlderHost() {
        let c = Self.v0212
        #expect(PlatformEnvSetting.matrixRequireMention.resolve(envValue: "false", configValue: true, capabilities: c) == (true, false))
        #expect(PlatformEnvSetting.matrixAutoThread.resolve(envValue: "false", configValue: true, capabilities: c) == (false, true))
        // `_env_truthy` has no "on" in its word set.
        #expect(!PlatformEnvSetting.matrixAutoThread.parsed("on"))
        #expect(PlatformEnvAllowlist.slackAllowedChannels.resolve(envValue: "C1", configItems: ["C9"], capabilities: c).items == ["C9"])
        #expect(PlatformEnvAllowlist.mattermostAllowedChannels.resolve(envValue: "m1", configItems: nil, capabilities: c).items == ["m1"])
        #expect(PlatformEnvString.resolve(envValue: "e", configValue: "c", capabilities: c) == ("c", false))
        #expect(PlatformEnvString.resolve(envValue: "e", configValue: "", capabilities: c) == ("e", true))
        #expect(PlatformEnvString.resolve(envValue: " ", configValue: "", capabilities: c) == ("", false))
    }
}
