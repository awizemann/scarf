import Foundation
import os

/// Telegram platform setup. Credentials live in `.env` (`TELEGRAM_*`); mention /
/// reactions toggles live in `config.yaml` under `telegram.*`.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram
@Observable
@MainActor
final class TelegramSetupViewModel {
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

    var message: String?

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
            "telegram.reactions": PlatformSetupHelpers.envBool(reactions)
        ]
        message = PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: configKV)
        clearMessageAfterDelay()
    }

    private func clearMessageAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
