import Foundation
import ScarfCore

/// Matrix setup. Supports both access-token and password auth. No SSO.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/matrix
@Observable
@MainActor
final class MatrixSetupViewModel: OutcomeMessageHosting {
    let context: ServerContext
    init(context: ServerContext = .local) { self.context = context }

    var homeserver: String = ""
    var accessToken: String = ""        // preferred
    var userID: String = ""
    var password: String = ""           // alternative to accessToken
    var allowedUsers: String = ""
    var homeRoom: String = ""
    var recoveryKey: String = ""
    var encryption: Bool = false

    // config.yaml
    var requireMention: Bool = true
    var autoThread: Bool = true
    var dmMentionThreads: Bool = false

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false

    func load() {
        // GW-F6 / audit DI L10: an unreadable `.env` used to arrive as an
        // EMPTY one, so this form rendered blank fields over live values and
        // a Save then commented those keys out. Absent is still an empty
        // form (correct — nothing is set yet); unreadable says so.
        let (env, envReadFailure) = PlatformSetupHelpers.loadEnv(context: context)
        if let envReadFailure {
            message = envReadFailure
            messageIsFailure = true
        }
        homeserver = env["MATRIX_HOMESERVER"] ?? ""
        accessToken = env["MATRIX_ACCESS_TOKEN"] ?? ""
        userID = env["MATRIX_USER_ID"] ?? ""
        password = env["MATRIX_PASSWORD"] ?? ""
        allowedUsers = env["MATRIX_ALLOWED_USERS"] ?? ""
        homeRoom = env["MATRIX_HOME_ROOM"] ?? ""
        recoveryKey = env["MATRIX_RECOVERY_KEY"] ?? ""
        encryption = PlatformSetupHelpers.parseEnvBool(env["MATRIX_ENCRYPTION"])

        let cfg = HermesFileService(context: context).loadConfig().matrix
        requireMention = cfg.requireMention
        autoThread = cfg.autoThread
        dmMentionThreads = cfg.dmMentionThreads
    }

    func save() {
        let envPairs: [String: String] = [
            "MATRIX_HOMESERVER": homeserver,
            "MATRIX_ACCESS_TOKEN": accessToken,
            "MATRIX_USER_ID": userID,
            "MATRIX_PASSWORD": password,
            "MATRIX_ALLOWED_USERS": allowedUsers,
            "MATRIX_HOME_ROOM": homeRoom,
            "MATRIX_RECOVERY_KEY": recoveryKey,
            "MATRIX_ENCRYPTION": encryption ? "true" : ""
        ]
        let configKV: [String: String] = [
            "matrix.require_mention": PlatformSetupHelpers.envBool(requireMention),
            "matrix.auto_thread": PlatformSetupHelpers.envBool(autoThread),
            "matrix.dm_mention_threads": PlatformSetupHelpers.envBool(dmMentionThreads)
        ]
        applySaveOutcome(PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: configKV))
    }
}
