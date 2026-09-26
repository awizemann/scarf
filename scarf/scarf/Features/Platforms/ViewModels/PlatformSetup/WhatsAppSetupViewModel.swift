import Foundation
import ScarfCore

/// WhatsApp setup. Unlike other platforms, pairing requires scanning a QR code
/// via the `hermes whatsapp` CLI wizard — we expose that as an embedded
/// terminal below the config form.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp
@Observable
@MainActor
final class WhatsAppSetupViewModel: PlatformSetupForm {
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
        self.cliRunner = cliRunner
        self.context = context
    }

    var enabled: Bool = false
    var mode: String = "bot"        // "bot" | "self-chat"
    var allowedUsers: String = ""   // Comma-separated phone numbers (no +)
    var allowAllUsers: Bool = false

    // config.yaml knobs
    var unauthorizedDMBehavior: String = "pair"     // "pair" | "ignore" | "decline" (v0.21.4+)
    var replyPrefix: String = ""
    /// The GLOBAL `unauthorized_dm_decline_message` — applies to every
    /// platform's decline reply, not just WhatsApp's (see
    /// ``WhatsAppSettings/unauthorizedDMDeclineMessage``'s doc comment for
    /// the reader-verified reason). Only meaningful (and only shown by
    /// ``WhatsAppSetupView``) while `unauthorizedDMBehavior == "decline"`.
    /// Empty uses Hermes's own default reply text.
    var unauthorizedDMDeclineMessage: String = ""

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false
    let modeOptions = ["bot", "self-chat"]
    let unauthorizedOptions = ["pair", "ignore"]

    /// The embedded terminal for the pairing step. Owned here so we can
    /// `stop()` it cleanly when the user navigates away.
    let terminalController = EmbeddedSetupTerminalController()
    var pairingInProgress: Bool = false

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
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

            guard let cfg = snapshot.config?.whatsapp else { return }
            unauthorizedDMBehavior = cfg.unauthorizedDMBehavior
            replyPrefix = cfg.replyPrefix
            unauthorizedDMDeclineMessage = cfg.unauthorizedDMDeclineMessage
        }
    }

    func save() {
        let envPairs: [String: String] = [
            "WHATSAPP_ENABLED": PlatformSetupHelpers.envBool(enabled),
            "WHATSAPP_MODE": mode,
            // If "allow all" is set, the allowlist becomes "*" per hermes docs.
            "WHATSAPP_ALLOWED_USERS": allowAllUsers ? "*" : allowedUsers,
            "WHATSAPP_ALLOW_ALL_USERS": allowAllUsers ? "true" : ""
        ]
        var configKV: [String: String] = [
            "whatsapp.unauthorized_dm_behavior": unauthorizedDMBehavior,
            "whatsapp.reply_prefix": replyPrefix
        ]
        // Only written while "decline" is active — a blank value on any
        // other choice is Hermes's own inert default, not worth a key.
        //
        // GLOBAL key, bare (not `whatsapp.…`, not `gateway.…`):
        // `_hm_send_unauthorized_decline` reads `self.config
        // .unauthorized_dm_decline_message` (`gateway/run_inbound.py:140`
        // @ `v2026.9.24`) — a top-level `GatewayConfig` field with no
        // per-platform override, unlike `unauthorized_dm_behavior` (a
        // `_SHARED_KEYS` member the WhatsApp block DOES carry). A
        // `whatsapp.unauthorized_dm_decline_message` key is inert: no
        // Hermes reader at any tag ever looks under `whatsapp.*` for it.
        if unauthorizedDMBehavior == "decline" {
            configKV["unauthorized_dm_decline_message"] = unauthorizedDMDeclineMessage
        }
        commitSave(envPairs: envPairs, configKV: configKV)
    }

    /// Non-nil on a remote context: pairing cannot run from this window.
    /// Round-5 decision 15 — see
    /// ``PlatformSetupHelpers/remoteOnlyHostNotice(_:)``.
    var remotePairingNotice: String? {
        PlatformSetupHelpers.remoteOnlyHostNotice(context)
    }

    /// Launch `hermes whatsapp` in the embedded terminal. The user scans the QR
    /// code; hermes writes the session to `~/.hermes/platforms/whatsapp/session`
    /// and exits when pairing is complete.
    func startPairing() {
        // The terminal is a LOCAL spawn and `hermesBinary` is the REMOTE
        // path — guarded here as well as at the button so the refusal does
        // not depend on one view remembering to disable a control.
        guard remotePairingNotice == nil else { return }
        pairingInProgress = true
        terminalController.onExit = { [weak self] _ in
            self?.pairingInProgress = false
            self?.applySaveOutcome(.success(String(localized: "Pairing terminal exited — check output for status")))
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
}
