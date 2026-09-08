import Foundation
import ScarfCore
import os

/// Telegram platform setup. Credentials live in `.env` (`TELEGRAM_*`); mention /
/// reactions toggles live in `config.yaml` under `telegram.*`.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram
@Observable
@MainActor
final class TelegramSetupViewModel: OutcomeMessageHosting {
    let context: ServerContext
    init(context: ServerContext = .local) { self.context = context }

    // Required
    var botToken: String = ""
    var allowedUsers: String = ""
    // Optional
    var homeChannel: String = ""
    var webhookURL: String = ""
    var webhookPort: String = ""
    var webhookSecret: String = ""
    // Config.yaml toggles
    var requireMention: Bool = true
    var reactions: Bool = false
    /// Hermes v0.15 — top-level `telegram.disable_topic_auto_rename`.
    var disableTopicAutoRename: Bool = false
    /// Hermes v0.15 — `platforms.telegram.extra.ignore_root_dm`.
    var ignoreRootDM: Bool = false
    /// Hermes v0.17 — `platforms.telegram.extra.rich_messages` (Bot API 10.1; default on).
    var richMessages: Bool = true
    /// Hermes v0.17 — `platforms.telegram.extra.status_indicator` (opt-in presence label).
    var statusIndicator: Bool = false

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false

    func load() {
        let env = HermesEnvService(context: context).load()
        botToken = env["TELEGRAM_BOT_TOKEN"] ?? ""
        allowedUsers = env["TELEGRAM_ALLOWED_USERS"] ?? ""
        homeChannel = env["TELEGRAM_HOME_CHANNEL"] ?? ""
        webhookURL = env["TELEGRAM_WEBHOOK_URL"] ?? ""
        webhookPort = env["TELEGRAM_WEBHOOK_PORT"] ?? ""
        webhookSecret = env["TELEGRAM_WEBHOOK_SECRET"] ?? ""

        let cfg = HermesFileService(context: context).loadConfig()
        requireMention = cfg.telegram.requireMention
        reactions = cfg.telegram.reactions
        disableTopicAutoRename = cfg.telegram.disableTopicAutoRename
        ignoreRootDM = cfg.telegram.ignoreRootDM
        richMessages = cfg.telegram.richMessages
        statusIndicator = cfg.telegram.statusIndicator
    }

    func save() {
        let envPairs: [String: String] = [
            "TELEGRAM_BOT_TOKEN": botToken,
            "TELEGRAM_ALLOWED_USERS": allowedUsers,
            "TELEGRAM_HOME_CHANNEL": homeChannel,
            "TELEGRAM_WEBHOOK_URL": webhookURL,
            "TELEGRAM_WEBHOOK_PORT": webhookPort,
            "TELEGRAM_WEBHOOK_SECRET": webhookSecret
        ]
        let configKV: [String: String] = [
            "telegram.require_mention": PlatformSetupHelpers.envBool(requireMention),
            "telegram.reactions": PlatformSetupHelpers.envBool(reactions),
            "telegram.disable_topic_auto_rename": PlatformSetupHelpers.envBool(disableTopicAutoRename),
            "platforms.telegram.extra.ignore_root_dm": PlatformSetupHelpers.envBool(ignoreRootDM),
            "platforms.telegram.extra.rich_messages": PlatformSetupHelpers.envBool(richMessages),
            "platforms.telegram.extra.status_indicator": PlatformSetupHelpers.envBool(statusIndicator)
        ]
        applySaveOutcome(PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: configKV))
    }
}
