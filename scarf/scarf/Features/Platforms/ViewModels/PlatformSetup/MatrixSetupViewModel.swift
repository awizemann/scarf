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

            // B13: resolved without an early config guard so the `.env`
            // half still shows; the latched `loadRefusal` refuses the Save.
            let cfg = snapshot.config?.matrix
            let caps = snapshot.capabilities ?? .empty
            var fromEnv = Set<String>()
            envLines = Set(Self.envSettings.map(\.setting.envKey).filter { env[$0] != nil })
            func resolve(_ spec: PlatformEnvSetting, _ key: String, _ value: Bool?) -> Bool {
                let configValue = cfg?.presentKeys.contains(key) == true ? value : nil
                let r = spec.resolve(envValue: env[spec.envKey], configValue: configValue, capabilities: caps)
                if r.fromEnv { fromEnv.insert(spec.envKey) }
                return r.value
            }
            requireMention = resolve(.matrixRequireMention, "require_mention", cfg?.requireMention)
            autoThread = resolve(.matrixAutoThread, "auto_thread", cfg?.autoThread)
            dmMentionThreads = resolve(.matrixDMMentionThreads, "dm_mention_threads", cfg?.dmMentionThreads)
            envDecides = fromEnv
        }
    }

    /// The three toggles an env var can override, with their config.yaml key.
    static let envSettings: [(setting: PlatformEnvSetting, configKey: String)] = [
        (.matrixRequireMention, "matrix.require_mention"),
        (.matrixAutoThread, "matrix.auto_thread"),
        (.matrixDMMentionThreads, "matrix.dm_mention_threads")
    ]

    /// Env keys with a line in `.env` (any value). A Save removes them.
    private(set) var envLines: Set<String> = []
    /// Env keys whose `.env` value is what the gateway uses right now.
    private(set) var envDecides: Set<String> = []

    /// Caption under a toggle while `.env` holds its env var.
    func envCaption(for envKey: String) -> String? {
        PlatformSetupHelpers.envOverrideCaption(
            envKey: envKey, hasLine: envLines.contains(envKey), decides: envDecides.contains(envKey))
    }

    func save() {
        let plan = savePlan()
        commitSave(envPairs: plan.env, configKV: plan.config,
                   envUnsetAfterConfig: plan.envUnsetAfterConfig)
    }

    /// The `.env` pairs, config.yaml keys and moved `.env` lines a Save
    /// writes. All three toggles are always written, so their `.env` lines
    /// go — only after the config writes succeed (`saveForm`).
    func savePlan() -> (env: [String: String], config: [String: String], envUnsetAfterConfig: [String]) {
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
        let moved = Self.envSettings
            .filter { envLines.contains($0.setting.envKey) && configKV.keys.contains($0.configKey) }
            .map(\.setting.envKey)
        return (envPairs, configKV, moved)
    }
}
