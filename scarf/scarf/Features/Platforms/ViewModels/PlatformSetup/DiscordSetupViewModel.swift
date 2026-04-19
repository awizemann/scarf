import Foundation
import os

/// Discord setup. Bot token + user IDs in `.env`, behavior knobs in `discord.*`.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord
@Observable
@MainActor
final class DiscordSetupViewModel {
    let context: ServerContext
    init(context: ServerContext = .local) { self.context = context }

    var botToken: String = ""
    var allowedUsers: String = ""
    var homeChannel: String = ""
    var homeChannelName: String = ""
    var allowBots: String = "none"        // "none" | "mentions" | "all"
    var replyToMode: String = "first"     // "off" | "first" | "all"

    // config.yaml — these mirror the existing `HermesConfig.discord` block so we
    // stay consistent with whatever the Settings UI shows.
    var requireMention: Bool = true
    var freeResponseChannels: String = ""
    var autoThread: Bool = true
    var reactions: Bool = true

    var message: String?

    let allowBotsOptions = ["none", "mentions", "all"]
    let replyToModeOptions = ["off", "first", "all"]

    func load() {
        let env = HermesEnvService(context: context).load()
        botToken = env["DISCORD_BOT_TOKEN"] ?? ""
        allowedUsers = env["DISCORD_ALLOWED_USERS"] ?? ""
        homeChannel = env["DISCORD_HOME_CHANNEL"] ?? ""
        homeChannelName = env["DISCORD_HOME_CHANNEL_NAME"] ?? ""
        allowBots = env["DISCORD_ALLOW_BOTS"] ?? "none"
        replyToMode = env["DISCORD_REPLY_TO_MODE"] ?? "first"

        let cfg = HermesFileService(context: context).loadConfig().discord
        requireMention = cfg.requireMention
        freeResponseChannels = cfg.freeResponseChannels
        autoThread = cfg.autoThread
        reactions = cfg.reactions
    }

    func save() {
        let envPairs: [String: String] = [
            "DISCORD_BOT_TOKEN": botToken,
            "DISCORD_ALLOWED_USERS": allowedUsers,
            "DISCORD_HOME_CHANNEL": homeChannel,
            "DISCORD_HOME_CHANNEL_NAME": homeChannelName,
            "DISCORD_ALLOW_BOTS": allowBots == "none" ? "" : allowBots, // default is "none", don't persist
            "DISCORD_REPLY_TO_MODE": replyToMode == "first" ? "" : replyToMode
        ]
        let configKV: [String: String] = [
            "discord.require_mention": PlatformSetupHelpers.envBool(requireMention),
            "discord.free_response_channels": freeResponseChannels,
            "discord.auto_thread": PlatformSetupHelpers.envBool(autoThread),
            "discord.reactions": PlatformSetupHelpers.envBool(reactions)
        ]
        message = PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: configKV)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
