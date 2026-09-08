import Foundation
import ScarfCore
import os

/// Discord setup. Bot token + user IDs in `.env`, behavior knobs in `discord.*`.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord
@Observable
@MainActor
final class DiscordSetupViewModel: OutcomeMessageHosting {
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
    /// Hermes v0.14 — when joining a thread or channel for the first
    /// time, read recent history so the agent knows what's been said.
    /// Default is `true` to match Hermes's v0.14 server-side default.
    /// Capability-gated by the host UI on `hasDiscordHistoryBackfill`.
    var historyBackfill: Bool = true
    /// Hermes v0.15 — `platforms.discord.extra.allow_any_attachment`.
    /// When true, forward any attachment type (not just images) to the agent.
    var allowAnyAttachment: Bool = false

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false

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
        historyBackfill = cfg.historyBackfill
        allowAnyAttachment = cfg.allowAnyAttachment
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
            "discord.reactions": PlatformSetupHelpers.envBool(reactions),
            "discord.history_backfill": PlatformSetupHelpers.envBool(historyBackfill),
            "platforms.discord.extra.allow_any_attachment": PlatformSetupHelpers.envBool(allowAnyAttachment)
        ]
        applySaveOutcome(PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: configKV))
    }
}
