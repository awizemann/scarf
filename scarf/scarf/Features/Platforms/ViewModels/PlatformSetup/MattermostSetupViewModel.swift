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
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false
    let replyModeOptions = ["off", "thread"]

    /// `.env` carries a `MATTERMOST_REQUIRE_MENTION` line (any value). A
    /// Save removes it — see ``savePlan()``.
    private(set) var requireMentionEnvLine = false
    /// The `.env` line is what the gateway is using right now, over
    /// config.yaml (v0.21.3+ with a non-blank value). Drives the caption.
    private(set) var requireMentionFromEnv = false

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot(includeCapabilities: true) { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            serverURL = env["MATTERMOST_URL"] ?? ""
            token = env["MATTERMOST_TOKEN"] ?? ""
            allowedUsers = env["MATTERMOST_ALLOWED_USERS"] ?? ""
            homeChannel = env["MATTERMOST_HOME_CHANNEL"] ?? ""
            freeResponseChannels = env["MATTERMOST_FREE_RESPONSE_CHANNELS"] ?? ""
            replyMode = env["MATTERMOST_REPLY_MODE"] ?? "off"

            // NO early `guard` on the config half. P37 finding 5's mirror
            // image, the shape P51 fixed in `NtfySetupViewModel` and left
            // here: an early `guard let cfg = snapshot.config?.mattermost
            // else { return }` over ONE of two independently-proven reads
            // throws the other one away. The latched `loadRefusal` still
            // refuses the Save.
            let envValue = env["MATTERMOST_REQUIRE_MENTION"]
            requireMentionEnvLine = envValue != nil
            let resolved = Self.resolveRequireMention(
                envValue: envValue,
                configValue: snapshot.config?.mattermost.requireMentionIsSet,
                envWins: snapshot.capabilities?.isV0213OrLater ?? false
            )
            requireMention = resolved.value
            requireMentionFromEnv = resolved.fromEnv
        }
    }

    /// `require_mention` the way the host's adapter resolves it.
    ///
    /// **The precedence flipped at v0.21.3 (v2026.9.14).** Up to v0.21.2 the
    /// adapter's `_extra_or_env` read config.yaml FIRST and `.env` only as
    /// the fallback (`plugins/platforms/mattermost/adapter.py:510` @
    /// `v2026.9.11`). From v2026.9.14 it is `extra_or_secret`: a NON-BLANK
    /// `MATTERMOST_REQUIRE_MENTION` wins, then `config.extra`, then `"true"`
    /// (`gateway/platforms/_shared.py:106-128`, `mattermost/adapter.py:503`
    /// @ `v2026.9.24`) — S07-F4. So a `.env` line an older Scarf wrote made
    /// the toggle inert on a current host while the form showed config's
    /// value.
    ///
    /// `mattermostRequireMention(envValue:)`, NOT `parseEnvBool`: the
    /// adapter's rule is `str(...).lower() not in {"false","0","no"}` — a
    /// three-word DENYlist (round-6 P53). `configValue` is
    /// `MattermostSettings.requireMentionIsSet` (nil = key absent).
    nonisolated static func resolveRequireMention(
        envValue: String?, configValue: Bool?, envWins: Bool
    ) -> (value: Bool, fromEnv: Bool) {
        let envSet = !(envValue?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        if envWins, envSet {
            return (HermesYAML.mattermostRequireMention(envValue: envValue), true)
        }
        if let configValue { return (configValue, false) }
        // Absent config key: the `.env` value is what the adapter falls back
        // to on every host (absent → the adapter's `"true"` default).
        return (HermesYAML.mattermostRequireMention(envValue: envValue), envValue != nil)
    }

    /// Caption under the toggle while `.env` is the source.
    var requireMentionCaption: String? {
        guard requireMentionEnvLine else { return nil }
        return requireMentionFromEnv
            ? String(localized: "MATTERMOST_REQUIRE_MENTION in .env sets this now. Saving moves it to config.yaml and removes the .env line.")
            : String(localized: "Saving removes the unused MATTERMOST_REQUIRE_MENTION line from .env.")
    }

    func save() {
        let plan = savePlan()
        commitSave(envPairs: plan.env, configKV: plan.config)
    }

    /// The `.env` pairs and config.yaml keys a Save writes.
    func savePlan() -> (env: [String: String], config: [String: String]) {
        var envPairs: [String: String] = [
            "MATTERMOST_URL": serverURL,
            "MATTERMOST_TOKEN": token,
            "MATTERMOST_ALLOWED_USERS": allowedUsers,
            "MATTERMOST_HOME_CHANNEL": homeChannel,
            "MATTERMOST_FREE_RESPONSE_CHANNELS": freeResponseChannels,
            "MATTERMOST_REPLY_MODE": replyMode == "off" ? "" : replyMode
        ]
        // ONE source for `require_mention`: config.yaml, and the `.env` line
        // goes. Config is where `hermes config set` writes and where the
        // shared-key bridge resolves the spelling (`bridgeResolvedKeys`);
        // removing the env line is what makes that value the one the adapter
        // reads on BOTH sides of the v0.21.3 flip (see
        // ``resolveRequireMention``). An empty pair is an `unset` (the line is
        // commented out); only sent when the line exists.
        if requireMentionEnvLine {
            envPairs["MATTERMOST_REQUIRE_MENTION"] = ""
        }
        let configKV: [String: String] = [
            "mattermost.require_mention": PlatformSetupHelpers.envBool(requireMention)
        ]
        return (envPairs, configKV)
    }
}
