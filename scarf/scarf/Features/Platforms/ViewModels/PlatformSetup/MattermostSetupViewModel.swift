import Foundation

/// Mattermost setup. Server URL + personal access token (or bot token).
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/mattermost
@Observable
@MainActor
final class MattermostSetupViewModel {
    var serverURL: String = ""
    var token: String = ""
    var allowedUsers: String = ""
    var homeChannel: String = ""
    var freeResponseChannels: String = ""

    var replyMode: String = "off"
    var requireMention: Bool = true

    var message: String?
    let replyModeOptions = ["off", "thread"]

    func load() {
        let env = HermesEnvService().load()
        serverURL = env["MATTERMOST_URL"] ?? ""
        token = env["MATTERMOST_TOKEN"] ?? ""
        allowedUsers = env["MATTERMOST_ALLOWED_USERS"] ?? ""
        homeChannel = env["MATTERMOST_HOME_CHANNEL"] ?? ""
        freeResponseChannels = env["MATTERMOST_FREE_RESPONSE_CHANNELS"] ?? ""
        replyMode = env["MATTERMOST_REPLY_MODE"] ?? "off"

        let cfg = HermesFileService().loadConfig().mattermost
        requireMention = cfg.requireMention
    }

    func save() {
        let envPairs: [String: String] = [
            "MATTERMOST_URL": serverURL,
            "MATTERMOST_TOKEN": token,
            "MATTERMOST_ALLOWED_USERS": allowedUsers,
            "MATTERMOST_HOME_CHANNEL": homeChannel,
            "MATTERMOST_FREE_RESPONSE_CHANNELS": freeResponseChannels,
            "MATTERMOST_REPLY_MODE": replyMode == "off" ? "" : replyMode,
            "MATTERMOST_REQUIRE_MENTION": PlatformSetupHelpers.envBool(requireMention)
        ]
        message = PlatformSetupHelpers.saveForm(envPairs: envPairs, configKV: [:])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
