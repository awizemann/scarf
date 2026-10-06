import Foundation
import ScarfCore

/// WhatsApp Business Cloud API setup (Hermes v0.17, 25th platform). Unlike the
/// older `whatsapp` web-bridge (QR pairing), the Cloud API is Meta's hosted
/// webhook path. Get the values from the Meta for Developers app dashboard.
///
/// **Where Hermes reads these from** (all @ v2026.9.24). The credentials can
/// live in either of two places, and Hermes's own `hermes whatsapp-cloud`
/// wizard uses `.env`:
///
/// - `.env`: `gateway/config_env.py:523-533` maps
///   `WHATSAPP_CLOUD_PHONE_NUMBER_ID` + `_ACCESS_TOKEN` (both required for any
///   of them to apply) and the optional `_APP_ID`, `_APP_SECRET`, `_WABA_ID`,
///   `_VERIFY_TOKEN`, `_API_VERSION` into `platforms.whatsapp_cloud.extra`,
///   overriding the config copies, and enables the platform unless config.yaml
///   says `enabled: false` (`gateway/config_env.py:182-207`). The wizard saves
///   every credential there (`hermes_cli/setup_whatsapp_cloud.py:144-150`) and
///   the allowlist as `WHATSAPP_CLOUD_ALLOWED_USERS` (`:269-285`). Same env
///   bridge since whatsapp_cloud first shipped (v2026.6.19, in
///   `gateway/config.py`), so no capability gate.
/// - config.yaml `platforms.whatsapp_cloud.extra.*`, which is where Scarf
///   used to write them.
///
/// The allowlist is picked by PRESENCE: a config `allow_from` key wins, even
/// empty, over `WHATSAPP_CLOUD_ALLOW_FROM` / `WHATSAPP_CLOUD_ALLOWED_USERS`
/// (`gateway/platforms/whatsapp_common.py:113-128`). With no `dm_policy`
/// anywhere the adapter defaults to `allowlist` when an allowlist exists, else
/// `open` (`gateway/platforms/whatsapp_cloud.py:185-195`).
///
/// So the form reads both files and writes each value back where Hermes
/// reads it from, and never writes a key just because a field is blank: an
/// explicit `enabled: false` would switch off an adapter whose credentials
/// sit in `.env`, and an empty config `allow_from` would replace the
/// wizard's allowlist (S07-F3).
@Observable
@MainActor
final class WhatsAppCloudSetupViewModel: PlatformSetupForm {
    let analyticsPlatform: UsageEvent.MessagingPlatform = .whatsappCloud
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
    var allowFrom: String = "" {
        didSet {
            // Nothing names a policy, so the adapter derives it from the
            // allowlist; keep the picker showing what Hermes will enforce
            // until the user picks one.
            if dmPolicyFollowsAllowlist, dmPolicy == loadedDMPolicy {
                dmPolicy = Self.derivedPolicy(allowFrom: allowFrom, allowAll: allowAllOptIn)
                loadedDMPolicy = dmPolicy
            }
        }
    }

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false
    let dmPolicyOptions = ["open", "allowlist"]

    /// Where the credentials are written. `.env` unless config.yaml alone
    /// holds the required pair — an older Scarf wrote them there, and moving
    /// half of them would leave `.env` without the pair that gates the rest.
    private(set) var credentialsInConfig = false
    /// Where the allowlist came from: `nil` = config.yaml `allow_from` (the
    /// key is present), else the env var it was read from.
    private(set) var allowlistEnvKey: String? = WhatsAppCloudSetupViewModel.allowedUsersEnv
    /// Whether config.yaml carries `dm_policy`, and what the form showed.
    private var dmPolicyInConfig = false
    private var loadedDMPolicy = "open"
    /// True when no config key or env var names a DM policy, so Hermes
    /// derives it from the allowlist.
    private var dmPolicyFollowsAllowlist = true
    private var allowAllOptIn = false
    /// The config `allow_from` is a YAML list: `hermes config set` refuses a
    /// plain string over a list (`_refuse_container_type_mismatch`,
    /// `hermes_cli/config.py:3316-3335` @ v2026.9.24), so it is written back
    /// as a list literal.
    private var allowFromIsList = false
    /// config.yaml carries `platforms.whatsapp_cloud.enabled`.
    private var enabledKeyInConfig = false

    /// `dm_policy` default when nothing names one
    /// (`gateway/platforms/whatsapp_cloud.py:186-190` @ v2026.9.24).
    static func derivedPolicy(allowFrom: String, allowAll: Bool) -> String {
        !allowFrom.trimmingCharacters(in: .whitespaces).isEmpty && !allowAll ? "allowlist" : "open"
    }

    static let phoneEnv = "WHATSAPP_CLOUD_PHONE_NUMBER_ID"
    static let tokenEnv = "WHATSAPP_CLOUD_ACCESS_TOKEN"
    static let allowFromEnv = "WHATSAPP_CLOUD_ALLOW_FROM"
    static let allowedUsersEnv = "WHATSAPP_CLOUD_ALLOWED_USERS"

    /// Off the main actor (C10) — see ``PlatformSetupForm``. Reads `.env`,
    /// config.yaml and its raw text (for key presence).
    func load() {
        loadSnapshot(includeRawConfigText: true) { [weak self] snapshot in
            guard let self else { return }
            self.apply(env: snapshot.env, config: snapshot.config?.whatsappCloud, rawConfigText: snapshot.rawConfigText)
        }
    }

    /// Resolve every field the way the gateway does. `config` / `rawConfigText`
    /// are nil when config.yaml was refused; the `.env` half still applies.
    func apply(env: [String: String], config cfg: WhatsAppCloudSettings?, rawConfigText: String?) {
        let parsed = rawConfigText.map { HermesYAML.parseNestedYAML($0) }
        func present(_ leaf: String) -> Bool {
            let key = "platforms.whatsapp_cloud.extra." + leaf
            return parsed?.values[key] != nil || parsed?.lists[key] != nil
        }
        func envValue(_ name: String) -> String {
            (env[name] ?? "").trimmingCharacters(in: .whitespaces)
        }
        let envHasPair = !envValue(Self.phoneEnv).isEmpty && !envValue(Self.tokenEnv).isEmpty
        let configHasPair = !(cfg?.phoneNumberID ?? "").isEmpty && !(cfg?.accessToken ?? "").isEmpty
        credentialsInConfig = configHasPair && !envHasPair
        // The env copies only apply when the required pair is in `.env`.
        func cred(_ envName: String, _ configValue: String?) -> String {
            let fromEnv = envValue(envName)
            if envHasPair, !fromEnv.isEmpty { return fromEnv }
            if let configValue, !configValue.isEmpty { return configValue }
            return credentialsInConfig ? "" : fromEnv
        }
        phoneNumberID = cred(Self.phoneEnv, cfg?.phoneNumberID)
        accessToken = cred(Self.tokenEnv, cfg?.accessToken)
        verifyToken = cred("WHATSAPP_CLOUD_VERIFY_TOKEN", cfg?.verifyToken)
        appSecret = cred("WHATSAPP_CLOUD_APP_SECRET", cfg?.appSecret)
        appID = cred("WHATSAPP_CLOUD_APP_ID", cfg?.appID)
        wabaID = cred("WHATSAPP_CLOUD_WABA_ID", cfg?.wabaID)
        let version = cred("WHATSAPP_CLOUD_API_VERSION", present("api_version") ? cfg?.apiVersion : nil)
        apiVersion = version.isEmpty ? "v20.0" : version

        enabledKeyInConfig = parsed?.values["platforms.whatsapp_cloud.enabled"] != nil
        // Set before `allowFrom`, whose observer reads it.
        dmPolicyFollowsAllowlist = false
        if present("allow_from") || present("allowFrom") {
            allowlistEnvKey = nil
            let list = parsed?.lists["platforms.whatsapp_cloud.extra.allow_from"]
                ?? parsed?.lists["platforms.whatsapp_cloud.extra.allowFrom"]
            let scalar = HermesYAML.stripYAMLQuotes(
                parsed?.values["platforms.whatsapp_cloud.extra.allow_from"]
                    ?? parsed?.values["platforms.whatsapp_cloud.extra.allowFrom"] ?? "")
            if let list {
                allowFromIsList = true
                allowFrom = list.map(HermesYAML.stripYAMLQuotes).joined(separator: ",")
            } else if scalar.hasPrefix("[") {
                // Flow style: `allow_from: ["123", "456"]` or `[]`.
                allowFromIsList = true
                allowFrom = scalar.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { HermesYAML.stripYAMLQuotes($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ",")
            } else {
                allowFromIsList = false
                allowFrom = scalar
            }
        } else if !envValue(Self.allowFromEnv).isEmpty {
            allowFromIsList = false
            allowlistEnvKey = Self.allowFromEnv
            allowFrom = envValue(Self.allowFromEnv)
        } else {
            allowFromIsList = false
            allowlistEnvKey = Self.allowedUsersEnv
            allowFrom = envValue(Self.allowedUsersEnv)
        }

        // `extra.get("dm_policy") or env… or default` — an EMPTY config value
        // falls through like an absent one.
        dmPolicyInConfig = present("dm_policy")
        let configPolicy = dmPolicyInConfig ? (cfg?.dmPolicy ?? "") : ""
        let envPolicy = [envValue("WHATSAPP_CLOUD_DM_POLICY"), envValue("WHATSAPP_DM_POLICY")]
            .first { !$0.isEmpty }
        allowAllOptIn = PlatformSetupHelpers.parseEnvBool(env["WHATSAPP_CLOUD_ALLOW_ALL_USERS"])
        let named = configPolicy.isEmpty ? envPolicy : configPolicy
        dmPolicy = (named ?? Self.derivedPolicy(allowFrom: allowFrom, allowAll: allowAllOptIn)).lowercased()
        loadedDMPolicy = dmPolicy
        dmPolicyFollowsAllowlist = named == nil
    }

    func save() {
        let plan = savePlan()
        commitSave(envPairs: plan.env, configKV: plan.config)
    }

    /// The `.env` pairs and config.yaml keys a Save writes. See the type doc.
    func savePlan() -> (env: [String: String], config: [String: String]) {
        var env: [String: String] = [:]
        var configKV: [String: String] = [:]
        let configured = !phoneNumberID.trimmingCharacters(in: .whitespaces).isEmpty
            && !accessToken.trimmingCharacters(in: .whitespaces).isEmpty
        // whatsapp_cloud is a BUILT-IN platform, so `enabled` defaults false
        // unless `.env` carries the pair. Turn it on when the form holds the
        // pair (this also lifts a stale explicit `false`). Never write `false`:
        // a blank field here may be a credential that lives somewhere this
        // form does not show, and an explicit `false` beats `.env` credentials.
        if configured {
            configKV["platforms.whatsapp_cloud.enabled"] = "true"
        } else if enabledKeyInConfig,
                  phoneNumberID.trimmingCharacters(in: .whitespaces).isEmpty,
                  accessToken.trimmingCharacters(in: .whitespaces).isEmpty {
            // The user cleared BOTH required fields — and the form shows both
            // files, so nothing is left anywhere. Turn off the switch a
            // previous save turned on, or the gateway starts a credential-less
            // adapter that goes fatal. Only over a key that already exists.
            configKV["platforms.whatsapp_cloud.enabled"] = "false"
        }
        if credentialsInConfig {
            // Legacy layout: leave the block in config.yaml. These cross argv
            // (`hermes config set` has no other input) — the reason new
            // setups go to `.env` instead.
            configKV["platforms.whatsapp_cloud.extra.phone_number_id"] = phoneNumberID
            configKV["platforms.whatsapp_cloud.extra.access_token"] = accessToken
            configKV["platforms.whatsapp_cloud.extra.verify_token"] = verifyToken
            configKV["platforms.whatsapp_cloud.extra.app_secret"] = appSecret
            configKV["platforms.whatsapp_cloud.extra.app_id"] = appID
            configKV["platforms.whatsapp_cloud.extra.waba_id"] = wabaID
            configKV["platforms.whatsapp_cloud.extra.api_version"] = apiVersion
        } else {
            // `.env` (0600, written through the transport): no secret on argv.
            env[Self.phoneEnv] = phoneNumberID
            env[Self.tokenEnv] = accessToken
            env["WHATSAPP_CLOUD_VERIFY_TOKEN"] = verifyToken
            env["WHATSAPP_CLOUD_APP_SECRET"] = appSecret
            env["WHATSAPP_CLOUD_APP_ID"] = appID
            env["WHATSAPP_CLOUD_WABA_ID"] = wabaID
            env["WHATSAPP_CLOUD_API_VERSION"] = apiVersion
        }
        // The allowlist goes back to where it came from; config only when the
        // `allow_from` key is already there (presence wins in Hermes).
        if let envKey = allowlistEnvKey {
            env[envKey] = allowFrom
        } else if allowFromIsList {
            let items = allowFrom.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            configKV["platforms.whatsapp_cloud.extra.allow_from"] = "[" + items.joined(separator: ", ") + "]"
        } else {
            configKV["platforms.whatsapp_cloud.extra.allow_from"] = allowFrom
        }
        // `dm_policy` only when config.yaml already carries it or the user
        // changed it — otherwise the adapter's own default (allowlist when an
        // allowlist exists) must stay in charge.
        if dmPolicyInConfig || dmPolicy != loadedDMPolicy {
            configKV["platforms.whatsapp_cloud.extra.dm_policy"] = dmPolicy
        }
        return (env, configKV)
    }
}
