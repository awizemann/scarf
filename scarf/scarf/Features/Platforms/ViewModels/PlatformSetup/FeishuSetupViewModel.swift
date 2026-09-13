import Foundation
import ScarfCore

/// Feishu/Lark setup. Choose domain (feishu = China, lark = international).
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/feishu
@Observable
@MainActor
final class FeishuSetupViewModel: PlatformSetupForm {
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
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    let domainOptions = ["feishu", "lark"]
    let connectionOptions = ["websocket", "webhook"]

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot(includeConfig: false) { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            appID = env["FEISHU_APP_ID"] ?? ""
            appSecret = env["FEISHU_APP_SECRET"] ?? ""
            domain = env["FEISHU_DOMAIN"] ?? "lark"
            encryptKey = env["FEISHU_ENCRYPT_KEY"] ?? ""
            verificationToken = env["FEISHU_VERIFICATION_TOKEN"] ?? ""
            allowedUsers = env["FEISHU_ALLOWED_USERS"] ?? ""
            connectionMode = env["FEISHU_CONNECTION_MODE"] ?? "websocket"
        }
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
        commitSave(envPairs: envPairs, configKV: [:])
    }
}
