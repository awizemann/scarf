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
    let analyticsPlatform: UsageEvent.MessagingPlatform = .whatsapp
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
    /// "bot" | "self-chat". Hermes's default when `WHATSAPP_MODE` is absent is
    /// `self-chat` (`gateway/platforms/whatsapp_common.py:77`,
    /// `plugins/platforms/whatsapp/adapter.py:393,505` @ `v2026.9.24`); the
    /// old `bot` default here switched a self-chat bridge to bot mode on an
    /// untouched Save (S07-F7).
    var mode: String = "self-chat"
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

    /// Whether config.yaml carries `whatsapp.reply_prefix` at all (S07-F2).
    ///
    /// Presence is the whole contract here. `_effective_reply_prefix`
    /// (`gateway/platforms/whatsapp_common.py:75-84` @ `v2026.9.24`) uses the
    /// config value whenever it is not `None` — an empty string included,
    /// which turns the header OFF — and only an ABSENT key falls through to
    /// `WHATSAPP_REPLY_PREFIX` and then the built-in "☤ *Hermes Agent*"
    /// header (`config_defaults.py:1600`: `None` = built-in, `""` disables).
    /// `HermesConfig` loads an absent key as `""`, so the field alone cannot
    /// tell "no header" from "Hermes's header".
    private(set) var replyPrefixInConfig = false
    /// `WHATSAPP_REPLY_PREFIX` from `.env` — what applies when the config key
    /// is absent. Shown, not edited.
    private(set) var envReplyPrefix: String?

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot(includeRawConfigText: true) { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            enabled = PlatformSetupHelpers.parseEnvBool(env["WHATSAPP_ENABLED"])
            mode = Self.mode(fromEnv: env["WHATSAPP_MODE"])
            allowedUsers = env["WHATSAPP_ALLOWED_USERS"] ?? ""
            allowAllUsers = PlatformSetupHelpers.parseEnvBool(env["WHATSAPP_ALLOW_ALL_USERS"])
            envReplyPrefix = env["WHATSAPP_REPLY_PREFIX"]
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
            replyPrefixInConfig = Self.replyPrefixIsSet(rawConfigText: snapshot.rawConfigText)
            unauthorizedDMDeclineMessage = cfg.unauthorizedDMDeclineMessage
        }
    }

    func save() {
        let plan = savePlan()
        commitSave(envPairs: plan.env, configKV: plan.config)
    }

    /// The `.env` pairs and config.yaml keys a Save writes.
    func savePlan() -> (env: [String: String], config: [String: String]) {
        let envPairs: [String: String] = [
            "WHATSAPP_ENABLED": PlatformSetupHelpers.envBool(enabled),
            "WHATSAPP_MODE": mode,
            // If "allow all" is set, the allowlist becomes "*" per hermes docs.
            "WHATSAPP_ALLOWED_USERS": allowAllUsers ? "*" : allowedUsers,
            "WHATSAPP_ALLOW_ALL_USERS": allowAllUsers ? "true" : ""
        ]
        var configKV: [String: String] = [
            "whatsapp.unauthorized_dm_behavior": unauthorizedDMBehavior
        ]
        // S07-F2: a blank field over an ABSENT key writes nothing. Writing
        // `""` there turned Hermes's self-chat header off (and shadowed any
        // `WHATSAPP_REPLY_PREFIX`) for a user who only came to change the
        // allowlist. A key that is already there is written as shown — blank
        // included, which is how the user turns the header off on purpose.
        if !replyPrefix.isEmpty || replyPrefixInConfig {
            configKV["whatsapp.reply_prefix"] = replyPrefix
        }
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
        return (envPairs, configKV)
    }

    /// What the reply header will be, in words, for the caption under the
    /// field. Self-chat only: Hermes adds no header in bot mode
    /// (`whatsapp_common.py:77-78`).
    var replyPrefixCaption: String {
        guard mode == "self-chat" else {
            return String(localized: "Only used in self-chat mode.")
        }
        if replyPrefixInConfig {
            return replyPrefix.isEmpty
                ? String(localized: "config.yaml sets an empty prefix, so replies carry no header. Use Hermes Default to bring the header back.")
                : String(localized: "Replies start with this header.")
        }
        if !replyPrefix.isEmpty {
            return String(localized: "Replies will start with this header once saved.")
        }
        if let envReplyPrefix {
            return envReplyPrefix.isEmpty
                ? String(localized: "WHATSAPP_REPLY_PREFIX in .env is empty, so replies carry no header.")
                : String(localized: "Blank: WHATSAPP_REPLY_PREFIX in .env sets the header.")
        }
        return String(localized: "Blank: replies use Hermes's default “☤ Hermes Agent” header.")
    }

    /// Remove `whatsapp.reply_prefix` so Hermes's own header (or
    /// `WHATSAPP_REPLY_PREFIX`) applies again. `hermes config unset` is the
    /// only way to make the key ABSENT — a `config set … ""` is the "no
    /// header" value, not the default. Gated on the verb's v0.19 floor
    /// (charter C1/C5), judged by output like every other unset.
    func useDefaultReplyPrefix(capabilities: HermesCapabilities) {
        let key = "whatsapp.reply_prefix"
        guard capabilities.hasConfigUnset else {
            showSaveFailure(HermesConfigUnset.belowFloorHint(key: key))
            return
        }
        guard !isBusy else { return }
        // Same latch `commitSave` honours: a config.yaml Scarf could not read
        // means `replyPrefixInConfig` is not known either.
        if let refusal = loadRefusal {
            showSaveFailure(refusal)
            return
        }
        guard replyPrefixInConfig else {
            replyPrefix = ""
            return
        }
        isSaving = true
        let run = cliRunner ?? context.cliRunner
        PlatformSetupHelpers.detached({
            // Literal key: the config-writer parity gate reads it off argv.
            let result = run(HermesConfigUnset.argv(key: "whatsapp.reply_prefix"), PlatformSetupHelpers.configSetTimeout)
            return HermesConfigUnset.judge(output: result.output, exitCode: result.exitCode)
        }, then: { [weak self] outcome in
            guard let self else { return }
            self.isSaving = false
            if outcome.succeeded {
                self.replyPrefix = ""
                self.replyPrefixInConfig = false
                self.applySaveOutcome(.success(String(localized: "Reply prefix reset to Hermes's default — restart gateway to apply")))
            } else if outcome.confidence == .unconfirmed {
                self.applySaveOutcome(.unconfirmed(outcome.detail
                    ?? String(localized: "Scarf could not confirm the reply prefix was removed — reload to check")))
            } else {
                self.showSaveFailure(outcome.detail
                    ?? String(localized: "Couldn't remove whatsapp.reply_prefix from config.yaml"))
            }
        })
    }

    /// `WHATSAPP_MODE` as the gateway resolves it: absent or blank is
    /// `self-chat` (`whatsapp_common.py:77` `… or "self-chat"`).
    nonisolated static func mode(fromEnv raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "self-chat" : value
    }

    /// Whether `whatsapp.reply_prefix` is present in config.yaml, the way
    /// Hermes sees it: a YAML null (`~`, `null`, or no value) loads as
    /// `None`, which is the same as absent. `nil` text (a refused read)
    /// answers false — the form's Save is refused then anyway.
    nonisolated static func replyPrefixIsSet(rawConfigText: String?) -> Bool {
        guard let rawConfigText else { return false }
        guard let raw = HermesYAML.parseNestedYAML(rawConfigText).values["whatsapp.reply_prefix"]
        else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return !["", "~", "null", "Null", "NULL"].contains(trimmed)
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
