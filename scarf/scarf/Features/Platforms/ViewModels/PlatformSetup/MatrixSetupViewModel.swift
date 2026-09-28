import Foundation
import ScarfCore

/// Matrix setup. Supports both access-token and password auth. No SSO.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/matrix
@Observable
@MainActor
final class MatrixSetupViewModel: PlatformSetupForm {
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
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot(includeCapabilities: true) { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            homeserver = env["MATRIX_HOMESERVER"] ?? ""
            accessToken = env["MATRIX_ACCESS_TOKEN"] ?? ""
            userID = env["MATRIX_USER_ID"] ?? ""
            password = env["MATRIX_PASSWORD"] ?? ""
            allowedUsers = env["MATRIX_ALLOWED_USERS"] ?? ""
            homeRoom = env["MATRIX_HOME_ROOM"] ?? ""
            recoveryKey = env["MATRIX_RECOVERY_KEY"] ?? ""
            encryption = PlatformSetupHelpers.parseEnvBool(env["MATRIX_ENCRYPTION"])

            if let cfg = snapshot.config?.matrix {
                requireMention = cfg.requireMention
                autoThread = cfg.autoThread
                dmMentionThreads = cfg.dmMentionThreads
            }
            // B05 sweep: `.env`-first readers (`HermesEnvFirstSettings`).
            // require_mention is "on unless false/0/no/off"
            // (`matrix/adapter.py:950-952`); auto_thread / dm_mention_threads
            // "on only for true/1/yes" (`_extra_truthy`, `:930-934`).
            let caps = snapshot.capabilities ?? .empty
            let yes: (String) -> Bool = { ["true", "1", "yes"].contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
            if let v = PlatformSetupHelpers.envFirstBool(
                "matrix.require_mention", env: env, capabilities: caps, HermesEnvFirstSettings.denyFalse) { requireMention = v }
            if let v = PlatformSetupHelpers.envFirstBool("matrix.auto_thread", env: env, capabilities: caps, yes) { autoThread = v }
            if let v = PlatformSetupHelpers.envFirstBool("matrix.dm_mention_threads", env: env, capabilities: caps, yes) { dmMentionThreads = v }
            envFirst = PlatformSetupHelpers.envFirstState(
                configKeys: ["matrix.require_mention", "matrix.auto_thread", "matrix.dm_mention_threads"],
                env: env, capabilities: caps)
        }
    }

    /// B05: what `.env` holds for this form's env-first keys.
    private(set) var envFirst = PlatformSetupHelpers.EnvFirstState()

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
        commitSave(envPairs: PlatformSetupHelpers.removingEnvFirstLines(envPairs, envFirst), configKV: configKV)
    }
}
