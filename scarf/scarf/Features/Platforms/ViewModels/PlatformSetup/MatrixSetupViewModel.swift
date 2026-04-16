import Foundation

/// Matrix setup. Supports both access-token and password auth. No SSO.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/matrix
@Observable
@MainActor
final class MatrixSetupViewModel {
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

    func load() {
        let env = HermesEnvService().load()
        homeserver = env["MATRIX_HOMESERVER"] ?? ""
        accessToken = env["MATRIX_ACCESS_TOKEN"] ?? ""
        userID = env["MATRIX_USER_ID"] ?? ""
        password = env["MATRIX_PASSWORD"] ?? ""
        allowedUsers = env["MATRIX_ALLOWED_USERS"] ?? ""
        homeRoom = env["MATRIX_HOME_ROOM"] ?? ""
        recoveryKey = env["MATRIX_RECOVERY_KEY"] ?? ""
        encryption = PlatformSetupHelpers.parseEnvBool(env["MATRIX_ENCRYPTION"])

        let cfg = HermesFileService().loadConfig().matrix
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
        message = PlatformSetupHelpers.saveForm(envPairs: envPairs, configKV: configKV)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
