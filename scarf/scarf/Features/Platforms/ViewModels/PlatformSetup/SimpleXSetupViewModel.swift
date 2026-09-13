import Foundation
import ScarfCore

/// SimpleX Chat setup (Hermes v0.14, 22nd platform; v0.17 added group +
/// auto-accept controls). SimpleX has no user identifiers or central servers —
/// the agent connects to a local `simplex-chat` daemon over WebSocket. All
/// config is environment variables (`SIMPLEX_*` / `HERMES_SIMPLEX_*`) in
/// `~/.hermes/.env`.
@Observable
@MainActor
final class SimpleXSetupViewModel: PlatformSetupForm {
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

    // Required
    var wsURL: String = ""
    // Access
    var allowedUsers: String = ""
    var allowAllUsers: Bool = false
    var groupAllowed: String = ""
    var autoAccept: Bool = true
    // Optional
    var homeChannel: String = ""
    var homeChannelName: String = ""
    var textBatchDelay: String = "0.8"

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
            wsURL = env["SIMPLEX_WS_URL"] ?? ""
            allowedUsers = env["SIMPLEX_ALLOWED_USERS"] ?? ""
            allowAllUsers = PlatformSetupHelpers.parseEnvBool(env["SIMPLEX_ALLOW_ALL_USERS"])
            // "*" in the allowlist is the equivalent of allow-all — normalize so the
            // checkbox reflects either form (mirrors the WhatsApp web-bridge form).
            if allowedUsers == "*" {
                allowAllUsers = true
                allowedUsers = ""
            }
            groupAllowed = env["SIMPLEX_GROUP_ALLOWED"] ?? ""
            // SIMPLEX_AUTO_ACCEPT defaults to true when the key is absent.
            autoAccept = env["SIMPLEX_AUTO_ACCEPT"].map { PlatformSetupHelpers.parseEnvBool($0) } ?? true
            homeChannel = env["SIMPLEX_HOME_CHANNEL"] ?? ""
            homeChannelName = env["SIMPLEX_HOME_CHANNEL_NAME"] ?? ""
            textBatchDelay = env["HERMES_SIMPLEX_TEXT_BATCH_DELAY"] ?? "0.8"
        }
    }

    func save() {
        let envPairs: [String: String] = [
            "SIMPLEX_WS_URL": wsURL,
            "SIMPLEX_ALLOWED_USERS": allowAllUsers ? "*" : allowedUsers,
            "SIMPLEX_ALLOW_ALL_USERS": allowAllUsers ? "true" : "",
            "SIMPLEX_GROUP_ALLOWED": groupAllowed,
            "SIMPLEX_AUTO_ACCEPT": PlatformSetupHelpers.envBool(autoAccept),
            "SIMPLEX_HOME_CHANNEL": homeChannel,
            "SIMPLEX_HOME_CHANNEL_NAME": homeChannelName,
            "HERMES_SIMPLEX_TEXT_BATCH_DELAY": textBatchDelay
        ]
        commitSave(envPairs: envPairs, configKV: [:])
    }
}
