import Foundation

/// Slack setup. Requires two tokens (bot + app-level for Socket Mode).
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/slack
@Observable
@MainActor
final class SlackSetupViewModel {
    var botToken: String = ""           // xoxb-...
    var appToken: String = ""           // xapp-...
    var allowedUsers: String = ""
    var homeChannel: String = ""
    var homeChannelName: String = ""

    var replyToMode: String = "first"
    var requireMention: Bool = true
    var replyInThread: Bool = true
    var replyBroadcast: Bool = false

    var message: String?

    let replyToModeOptions = ["off", "first", "all"]

    func load() {
        let env = HermesEnvService().load()
        botToken = env["SLACK_BOT_TOKEN"] ?? ""
        appToken = env["SLACK_APP_TOKEN"] ?? ""
        allowedUsers = env["SLACK_ALLOWED_USERS"] ?? ""
        homeChannel = env["SLACK_HOME_CHANNEL"] ?? ""
        homeChannelName = env["SLACK_HOME_CHANNEL_NAME"] ?? ""

        let cfg = HermesFileService().loadConfig().slack
        replyToMode = cfg.replyToMode
        requireMention = cfg.requireMention
        replyInThread = cfg.replyInThread
        replyBroadcast = cfg.replyBroadcast
    }

    func save() {
        let envPairs: [String: String] = [
            "SLACK_BOT_TOKEN": botToken,
            "SLACK_APP_TOKEN": appToken,
            "SLACK_ALLOWED_USERS": allowedUsers,
            "SLACK_HOME_CHANNEL": homeChannel,
            "SLACK_HOME_CHANNEL_NAME": homeChannelName
        ]
        // Slack uses the modern `platforms.slack.*` schema.
        let configKV: [String: String] = [
            "platforms.slack.reply_to_mode": replyToMode,
            "platforms.slack.require_mention": PlatformSetupHelpers.envBool(requireMention),
            "platforms.slack.extra.reply_in_thread": PlatformSetupHelpers.envBool(replyInThread),
            "platforms.slack.extra.reply_broadcast": PlatformSetupHelpers.envBool(replyBroadcast)
        ]
        message = PlatformSetupHelpers.saveForm(envPairs: envPairs, configKV: configKV)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
