import Foundation
import ScarfCore

/// Webhook platform setup. Just the global enable/port/secret — per-subscription
/// routes live in the Webhooks sidebar feature.
///
/// **Two switches, both needed** (@ v2026.9.24). The gateway starts the
/// listener on `WEBHOOK_ENABLED` in `.env` (`gateway/config_env.py:318-327`),
/// but every `hermes webhook` verb checks ONLY config.yaml's
/// `platforms.webhook.enabled` (`_is_webhook_enabled`,
/// `hermes_cli/webhook.py:54-55`, gating each action at `:105-107`; the same
/// config-only check since v2026.3.30, Scarf's floor). A form that wrote only
/// the env flag brought the listener up and left the Webhooks tab stuck on
/// "not enabled" (S07-F4). The form writes both. It writes `false` only over
/// a config key that already exists, so an untouched form never creates an
/// explicit disable.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks
@Observable
@MainActor
final class WebhookSetupViewModel: PlatformSetupForm {
    let analyticsPlatform: UsageEvent.MessagingPlatform = .webhook
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

    var enabled: Bool = false
    var port: String = "8644"
    var secret: String = ""

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    /// Whether config.yaml already carries `platforms.webhook.enabled`.
    private var configHasEnabledKey = false

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot(includeConfig: false, includeRawConfigText: true) { [weak self] snapshot in
            guard let self else { return }
            self.apply(env: snapshot.env, rawConfigText: snapshot.rawConfigText)
        }
    }

    /// Enabled when either switch is on — the gateway listens on either, and
    /// Save then writes both so the CLI verbs agree.
    func apply(env: [String: String], rawConfigText: String?) {
        let configEnabled = rawConfigText
            .map { HermesYAML.parseNestedYAML($0).values["platforms.webhook.enabled"] }
            ?? nil
        configHasEnabledKey = configEnabled != nil
        enabled = PlatformSetupHelpers.parseEnvBool(env["WEBHOOK_ENABLED"])
            || PlatformSetupHelpers.parseEnvBool(configEnabled.map(HermesYAML.stripYAMLQuotes))
        port = env["WEBHOOK_PORT"] ?? "8644"
        secret = env["WEBHOOK_SECRET"] ?? ""
    }

    func save() {
        let plan = savePlan()
        commitSave(envPairs: plan.env, configKV: plan.config)
    }

    func savePlan() -> (env: [String: String], config: [String: String]) {
        let envPairs: [String: String] = [
            "WEBHOOK_ENABLED": enabled ? "true" : "",
            "WEBHOOK_PORT": port,
            "WEBHOOK_SECRET": secret
        ]
        var configKV: [String: String] = [:]
        if enabled || configHasEnabledKey {
            configKV["platforms.webhook.enabled"] = enabled ? "true" : "false"
        }
        return (envPairs, configKV)
    }
}
