import Foundation
import ScarfCore

/// Webhook platform setup. Just the global enable/port/secret — per-subscription
/// routes live in the Webhooks sidebar feature.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks
@Observable
@MainActor
final class WebhookSetupViewModel: PlatformSetupForm {
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

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot(includeConfig: false) { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            enabled = PlatformSetupHelpers.parseEnvBool(env["WEBHOOK_ENABLED"])
            port = env["WEBHOOK_PORT"] ?? "8644"
            secret = env["WEBHOOK_SECRET"] ?? ""
        }
    }

    func save() {
        let envPairs: [String: String] = [
            "WEBHOOK_ENABLED": enabled ? "true" : "",
            "WEBHOOK_PORT": port,
            "WEBHOOK_SECRET": secret
        ]
        commitSave(envPairs: envPairs, configKV: [:])
    }
}
