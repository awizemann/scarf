import Foundation
import ScarfCore

/// WhatsApp setup. Unlike other platforms, pairing requires scanning a QR code
/// via the `hermes whatsapp` CLI wizard — we expose that as an embedded
/// terminal below the config form.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp
@Observable
@MainActor
final class WhatsAppSetupViewModel {
    let context: ServerContext

    init(context: ServerContext = .local) {
        self.context = context
    }

    var enabled: Bool = false
    var mode: String = "bot"        // "bot" | "self-chat"
    var allowedUsers: String = ""   // Comma-separated phone numbers (no +)
    var allowAllUsers: Bool = false

    // config.yaml knobs
    var unauthorizedDMBehavior: String = "pair"     // "pair" | "ignore"
    var replyPrefix: String = ""

    var message: String?
    let modeOptions = ["bot", "self-chat"]
    let unauthorizedOptions = ["pair", "ignore"]

    /// The embedded terminal for the pairing step. Owned here so we can
    /// `stop()` it cleanly when the user navigates away.
    let terminalController = EmbeddedSetupTerminalController()
    var pairingInProgress: Bool = false

    func load() {
        let env = HermesEnvService(context: context).load()
        enabled = PlatformSetupHelpers.parseEnvBool(env["WHATSAPP_ENABLED"])
        mode = env["WHATSAPP_MODE"] ?? "bot"
        allowedUsers = env["WHATSAPP_ALLOWED_USERS"] ?? ""
        allowAllUsers = PlatformSetupHelpers.parseEnvBool(env["WHATSAPP_ALLOW_ALL_USERS"])
        // Hermes accepts two equivalent ways to mean "allow everyone":
        //   WHATSAPP_ALLOW_ALL_USERS=true  OR  WHATSAPP_ALLOWED_USERS=*
        // Normalize so the checkbox reflects either form.
        if allowedUsers == "*" {
            allowAllUsers = true
            allowedUsers = ""
        }

        let cfg = HermesFileService(context: context).loadConfig().whatsapp
        unauthorizedDMBehavior = cfg.unauthorizedDMBehavior
        replyPrefix = cfg.replyPrefix
    }

    func save() {
        let envPairs: [String: String] = [
            "WHATSAPP_ENABLED": PlatformSetupHelpers.envBool(enabled),
            "WHATSAPP_MODE": mode,
            // If "allow all" is set, the allowlist becomes "*" per hermes docs.
            "WHATSAPP_ALLOWED_USERS": allowAllUsers ? "*" : allowedUsers,
            "WHATSAPP_ALLOW_ALL_USERS": allowAllUsers ? "true" : ""
        ]
        let configKV: [String: String] = [
            "whatsapp.unauthorized_dm_behavior": unauthorizedDMBehavior,
            "whatsapp.reply_prefix": replyPrefix
        ]
        message = PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: configKV)
        clearMessageAfterDelay()
    }

    /// Launch `hermes whatsapp` in the embedded terminal. The user scans the QR
    /// code; hermes writes the session to `~/.hermes/platforms/whatsapp/session`
    /// and exits when pairing is complete.
    func startPairing() {
        pairingInProgress = true
        terminalController.onExit = { [weak self] _ in
            self?.pairingInProgress = false
            self?.message = "Pairing terminal exited — check output for status"
            self?.clearMessageAfterDelay()
        }
        terminalController.start(
            executable: context.paths.hermesBinary,
            arguments: ["whatsapp"]
        )
    }

    func stopPairing() {
        terminalController.stop()
        pairingInProgress = false
    }

    private func clearMessageAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
