import Foundation
import ScarfCore

/// WhatsApp Business Cloud API setup (Hermes v0.17, 25th platform). Unlike the
/// older `whatsapp` web-bridge (QR pairing via `.env`), the Cloud API is Meta's
/// hosted webhook path: all config lives under `platforms.whatsapp_cloud.extra.*`
/// in config.yaml — including the access token, app secret, and webhook verify
/// token (secrets). Get these from the Meta for Developers app dashboard.
///
/// `dmPolicy = allowlist` activates `allowFrom`; `open` (default) responds to
/// any sender. Group routing + webhook host/port/path keep Hermes' defaults and
/// can be hand-edited in config.yaml if needed.
@Observable
@MainActor
final class WhatsAppCloudSetupViewModel: PlatformSetupForm {
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

    // Required
    var phoneNumberID: String = ""
    var accessToken: String = ""
    // Webhook
    var verifyToken: String = ""
    var appSecret: String = ""
    var appID: String = ""
    // Optional
    var wabaID: String = ""
    var apiVersion: String = "v20.0"
    // DM allowlist
    var dmPolicy: String = "open"
    var allowFrom: String = ""

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false
    let dmPolicyOptions = ["open", "allowlist"]

    /// Off the main actor (C10) — see ``PlatformSetupForm``. Config-only:
    /// whatsapp_cloud keeps every credential in config.yaml (see `save()`).
    func load() {
        loadSnapshot(includeEnv: false) { [weak self] snapshot in
            guard let self, let cfg = snapshot.config?.whatsappCloud else { return }
            phoneNumberID = cfg.phoneNumberID
            accessToken = cfg.accessToken
            verifyToken = cfg.verifyToken
            appSecret = cfg.appSecret
            appID = cfg.appID
            wabaID = cfg.wabaID
            apiVersion = cfg.apiVersion.isEmpty ? "v20.0" : cfg.apiVersion
            dmPolicy = cfg.dmPolicy.isEmpty ? "open" : cfg.dmPolicy
            allowFrom = cfg.allowFrom
        }
    }

    func save() {
        // KNOWN, UNFIXABLE HERE: `access_token` / `app_secret` cross the
        // command line as `hermes config set … <secret>` argv, and on a
        // remote host every local user can read that out of /proc while the
        // call runs. Every other platform Scarf configures has an env-var
        // path to move the secret into `.env` (0600, written through the
        // transport); whatsapp_cloud does not — `gateway/platforms/
        // whatsapp_cloud.py:164-166` reads all six credentials out of the
        // config section and NOTHING from the environment (`os.environ` and
        // `getenv` occur in neither that file nor
        // `hermes_cli/setup_whatsapp_cloud.py`, which only prompts
        // interactively). Verified against Hermes **v2026.9.7**. The fix belongs UPSTREAM:
        // WHATSAPP_CLOUD_ACCESS_TOKEN / _APP_SECRET env fallbacks in the
        // adapter, at which point this moves to `envPairs` exactly like
        // NtfySetupViewModel's token did. Do not "solve" it locally by
        // shelling a secret through a different verb — they all use argv.
        //
        // whatsapp_cloud is a BUILT-IN platform (not a plugin), so the gateway
        // parses it as disabled (`enabled` defaults false) unless config.yaml
        // says otherwise — writing the `extra.*` creds alone leaves a
        // configured-but-OFF adapter that never starts. Enable it only when the
        // required creds are present; disable a half-filled form.
        let configured = !phoneNumberID.trimmingCharacters(in: .whitespaces).isEmpty
            && !accessToken.trimmingCharacters(in: .whitespaces).isEmpty
        let configKV: [String: String] = [
            "platforms.whatsapp_cloud.enabled": configured ? "true" : "false",
            "platforms.whatsapp_cloud.extra.phone_number_id": phoneNumberID,
            "platforms.whatsapp_cloud.extra.access_token": accessToken,
            "platforms.whatsapp_cloud.extra.verify_token": verifyToken,
            "platforms.whatsapp_cloud.extra.app_secret": appSecret,
            "platforms.whatsapp_cloud.extra.app_id": appID,
            "platforms.whatsapp_cloud.extra.waba_id": wabaID,
            "platforms.whatsapp_cloud.extra.api_version": apiVersion,
            "platforms.whatsapp_cloud.extra.dm_policy": dmPolicy,
            "platforms.whatsapp_cloud.extra.allow_from": allowFrom
        ]
        commitSave(envPairs: [:], configKV: configKV)
    }
}
