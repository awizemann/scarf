import Foundation
import ScarfCore

/// Slack setup. Requires two tokens (bot + app-level for Socket Mode).
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/slack
@Observable
@MainActor
final class SlackSetupViewModel: PlatformSetupForm {
    let context: ServerContext
    /// C10 test seam — nil in production. See ``PlatformSetupForm``.
    let cliRunner: HermesCLIRunner?
    /// Load/save in-flight flags owned by ``PlatformSetupForm``.
    var isLoading = false
    var isSaving = false
    /// Latched load refusal owned by ``PlatformSetupForm`` — set when a
    /// `.env` / config.yaml read could not be proved, and what makes
    /// `commitSave` refuse rather than publish blanks (P33).
    var loadRefusal: String?
    init(context: ServerContext = .local, cliRunner: HermesCLIRunner? = nil) {
        self.context = context
        self.cliRunner = cliRunner
    }

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
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    let replyToModeOptions = ["off", "first", "all"]

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            botToken = env["SLACK_BOT_TOKEN"] ?? ""
            appToken = env["SLACK_APP_TOKEN"] ?? ""
            allowedUsers = env["SLACK_ALLOWED_USERS"] ?? ""
            homeChannel = env["SLACK_HOME_CHANNEL"] ?? ""
            homeChannelName = env["SLACK_HOME_CHANNEL_NAME"] ?? ""

            guard let cfg = snapshot.config?.slack else { return }
            replyToMode = cfg.replyToMode
            requireMention = cfg.requireMention
            replyInThread = cfg.replyInThread
            replyBroadcast = cfg.replyBroadcast
        }
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
        commitSave(envPairs: envPairs, configKV: configKV)
    }
}
