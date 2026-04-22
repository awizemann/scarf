import Foundation
import ScarfCore

/// iMessage via BlueBubbles. Requires a BlueBubbles Server running on a Mac
/// that's always on, with an Apple ID signed into Messages.app.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/bluebubbles
@Observable
@MainActor
final class IMessageSetupViewModel {
    let context: ServerContext
    init(context: ServerContext = .local) { self.context = context }

    var serverURL: String = ""
    var password: String = ""
    var webhookHost: String = "127.0.0.1"
    var webhookPort: String = "8645"
    var webhookPath: String = ""
    var allowedUsers: String = ""
    var homeChannel: String = ""
    var allowAllUsers: Bool = false
    var sendReadReceipts: Bool = false

    var message: String?

    func load() {
        let env = HermesEnvService(context: context).load()
        serverURL = env["BLUEBUBBLES_SERVER_URL"] ?? ""
        password = env["BLUEBUBBLES_PASSWORD"] ?? ""
        webhookHost = env["BLUEBUBBLES_WEBHOOK_HOST"] ?? "127.0.0.1"
        webhookPort = env["BLUEBUBBLES_WEBHOOK_PORT"] ?? "8645"
        webhookPath = env["BLUEBUBBLES_WEBHOOK_PATH"] ?? ""
        allowedUsers = env["BLUEBUBBLES_ALLOWED_USERS"] ?? ""
        homeChannel = env["BLUEBUBBLES_HOME_CHANNEL"] ?? ""
        allowAllUsers = PlatformSetupHelpers.parseEnvBool(env["BLUEBUBBLES_ALLOW_ALL_USERS"])
        sendReadReceipts = PlatformSetupHelpers.parseEnvBool(env["BLUEBUBBLES_SEND_READ_RECEIPTS"])
    }

    func save() {
        let envPairs: [String: String] = [
            "BLUEBUBBLES_SERVER_URL": serverURL,
            "BLUEBUBBLES_PASSWORD": password,
            "BLUEBUBBLES_WEBHOOK_HOST": webhookHost,
            "BLUEBUBBLES_WEBHOOK_PORT": webhookPort,
            "BLUEBUBBLES_WEBHOOK_PATH": webhookPath,
            "BLUEBUBBLES_ALLOWED_USERS": allowAllUsers ? "" : allowedUsers,
            "BLUEBUBBLES_HOME_CHANNEL": homeChannel,
            "BLUEBUBBLES_ALLOW_ALL_USERS": allowAllUsers ? "true" : "",
            "BLUEBUBBLES_SEND_READ_RECEIPTS": sendReadReceipts ? "true" : ""
        ]
        message = PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: [:])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
