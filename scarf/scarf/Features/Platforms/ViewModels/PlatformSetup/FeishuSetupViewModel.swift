import Foundation
import ScarfCore

/// Feishu/Lark setup. Choose domain (feishu = China, lark = international).
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/feishu
@Observable
@MainActor
final class FeishuSetupViewModel: OutcomeMessageHosting {
    let context: ServerContext
    init(context: ServerContext = .local) { self.context = context }

    var appID: String = ""
    var appSecret: String = ""
    var domain: String = "lark"
    var encryptKey: String = ""
    var verificationToken: String = ""
    var allowedUsers: String = ""
    var connectionMode: String = "websocket"  // "websocket" | "webhook"

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false

    let domainOptions = ["feishu", "lark"]
    let connectionOptions = ["websocket", "webhook"]

    func load() {
        let env = HermesEnvService(context: context).load()
        appID = env["FEISHU_APP_ID"] ?? ""
        appSecret = env["FEISHU_APP_SECRET"] ?? ""
        domain = env["FEISHU_DOMAIN"] ?? "lark"
        encryptKey = env["FEISHU_ENCRYPT_KEY"] ?? ""
        verificationToken = env["FEISHU_VERIFICATION_TOKEN"] ?? ""
        allowedUsers = env["FEISHU_ALLOWED_USERS"] ?? ""
        connectionMode = env["FEISHU_CONNECTION_MODE"] ?? "websocket"
    }

    func save() {
        let envPairs: [String: String] = [
            "FEISHU_APP_ID": appID,
            "FEISHU_APP_SECRET": appSecret,
            "FEISHU_DOMAIN": domain,
            "FEISHU_ENCRYPT_KEY": encryptKey,
            "FEISHU_VERIFICATION_TOKEN": verificationToken,
            "FEISHU_ALLOWED_USERS": allowedUsers,
            "FEISHU_CONNECTION_MODE": connectionMode == "websocket" ? "" : connectionMode
        ]
        applySaveOutcome(PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: [:]))
    }
}
