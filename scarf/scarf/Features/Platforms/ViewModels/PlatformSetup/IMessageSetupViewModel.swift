import Foundation
import ScarfCore

/// iMessage via BlueBubbles. Requires a BlueBubbles Server running on a Mac
/// that's always on, with an Apple ID signed into Messages.app.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/bluebubbles
@Observable
@MainActor
final class IMessageSetupViewModel: PlatformSetupForm {
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
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot(includeConfig: false) { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
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
        commitSave(envPairs: envPairs, configKV: [:])
    }
}
