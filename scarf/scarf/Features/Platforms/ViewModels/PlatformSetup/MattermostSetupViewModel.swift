import Foundation
import ScarfCore

/// Mattermost setup. Server URL + personal access token (or bot token).
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/mattermost
@Observable
@MainActor
final class MattermostSetupViewModel: PlatformSetupForm {
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
    var token: String = ""
    var allowedUsers: String = ""
    var homeChannel: String = ""
    var freeResponseChannels: String = ""

    var replyMode: String = "off"
    var requireMention: Bool = true

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    let replyModeOptions = ["off", "thread"]

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            serverURL = env["MATTERMOST_URL"] ?? ""
            token = env["MATTERMOST_TOKEN"] ?? ""
            allowedUsers = env["MATTERMOST_ALLOWED_USERS"] ?? ""
            homeChannel = env["MATTERMOST_HOME_CHANNEL"] ?? ""
            freeResponseChannels = env["MATTERMOST_FREE_RESPONSE_CHANNELS"] ?? ""
            replyMode = env["MATTERMOST_REPLY_MODE"] ?? "off"

            guard let cfg = snapshot.config?.mattermost else { return }
            // config.yaml WINS and `.env` is only the fallback — the adapter's
            // own precedence (`_extra_or_env("require_mention",
            // "MATTERMOST_REQUIRE_MENTION", "true")`,
            // `plugins/platforms/mattermost/adapter.py:504`, helper at
            // `:491-494` @ `v2026.9.7`). So an ABSENT config key is the only
            // case where the `.env` value is what Hermes is actually using,
            // and reading config's resolved default over it would show the
            // user the wrong state of their own gateway.
            //
            // Nothing is migrated silently: the `.env` half is READ as the
            // fallback, and only a Save writes the config key (which is also
            // where the value starts winning).
            requireMention = cfg.requireMentionIsSet
                ?? PlatformSetupHelpers.parseEnvBool(env["MATTERMOST_REQUIRE_MENTION"] ?? "true")
        }
    }

    func save() {
        let envPairs: [String: String] = [
            "MATTERMOST_URL": serverURL,
            "MATTERMOST_TOKEN": token,
            "MATTERMOST_ALLOWED_USERS": allowedUsers,
            "MATTERMOST_HOME_CHANNEL": homeChannel,
            "MATTERMOST_FREE_RESPONSE_CHANNELS": freeResponseChannels,
            "MATTERMOST_REPLY_MODE": replyMode == "off" ? "" : replyMode
        ]
        // `require_mention` goes to config.yaml, NOT `.env`. The form READ it
        // from config and WROTE it to `.env`, so the toggle appeared to snap
        // back on the next load — and on a config that carries the key at
        // all, the `.env` write was inert, because `_extra_or_env` consults
        // `config.extra` FIRST (`adapter.py:491-494`, `:504` @ `v2026.9.7`).
        // One side, both directions: the side Hermes prefers.
        let configKV: [String: String] = [
            "mattermost.require_mention": PlatformSetupHelpers.envBool(requireMention)
        ]
        commitSave(envPairs: envPairs, configKV: configKV)
    }
}
