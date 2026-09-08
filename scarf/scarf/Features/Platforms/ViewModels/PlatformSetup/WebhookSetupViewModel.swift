import Foundation
import ScarfCore

/// Webhook platform setup. Just the global enable/port/secret — per-subscription
/// routes live in the Webhooks sidebar feature.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks
@Observable
@MainActor
final class WebhookSetupViewModel: OutcomeMessageHosting {
    let context: ServerContext
    init(context: ServerContext = .local) { self.context = context }

    var enabled: Bool = false
    var port: String = "8644"
    var secret: String = ""

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
        enabled = PlatformSetupHelpers.parseEnvBool(env["WEBHOOK_ENABLED"])
        port = env["WEBHOOK_PORT"] ?? "8644"
        secret = env["WEBHOOK_SECRET"] ?? ""
    }

    func save() {
        let envPairs: [String: String] = [
            "WEBHOOK_ENABLED": enabled ? "true" : "",
            "WEBHOOK_PORT": port,
            "WEBHOOK_SECRET": secret
        ]
        applySaveOutcome(PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: [:]))
    }
}
