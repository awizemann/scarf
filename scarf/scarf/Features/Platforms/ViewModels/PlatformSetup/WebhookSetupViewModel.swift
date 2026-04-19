import Foundation

/// Webhook platform setup. Just the global enable/port/secret — per-subscription
/// routes live in the Webhooks sidebar feature.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks
@Observable
@MainActor
final class WebhookSetupViewModel {
    let context: ServerContext
    init(context: ServerContext = .local) { self.context = context }

    var enabled: Bool = false
    var port: String = "8644"
    var secret: String = ""

    var message: String?

    func load() {
        let env = HermesEnvService(context: context).load()
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
        message = PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: [:])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
