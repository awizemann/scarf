import Foundation
import ScarfCore
import AppKit

/// Home Assistant setup. Long-lived access token in `.env`, scalar filters via
/// `hermes config set` under `platforms.homeassistant.extra.*`.
///
/// **List fields** (`watch_domains`, `watch_entities`, `ignore_entities`) are
/// NOT editable in the form. `hermes config set` stores array arguments as
/// quoted strings instead of YAML lists, which hermes would then reject as
/// invalid. Users edit these directly in config.yaml — the view shows the
/// current values (read-only) and an "Edit in config.yaml" button that opens
/// the file.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/homeassistant
@Observable
@MainActor
final class HomeAssistantSetupViewModel: PlatformSetupForm {
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

    var url: String = "http://homeassistant.local:8123"
    var token: String = ""

    // Scalar filters — writable via hermes config set.
    var watchAll: Bool = false
    var cooldownSeconds: Int = 30

    // List filters — read-only; user must edit config.yaml manually.
    var watchDomains: [String] = []
    var watchEntities: [String] = []
    var ignoreEntities: [String] = []

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            url = env["HASS_URL"] ?? "http://homeassistant.local:8123"
            token = env["HASS_TOKEN"] ?? ""

            guard let cfg = snapshot.config?.homeAssistant else { return }
            watchAll = cfg.watchAll
            cooldownSeconds = cfg.cooldownSeconds
            watchDomains = cfg.watchDomains
            watchEntities = cfg.watchEntities
            ignoreEntities = cfg.ignoreEntities
        }
    }

    func save() {
        let envPairs: [String: String] = [
            "HASS_URL": url,
            "HASS_TOKEN": token
        ]
        // Only scalar config values — lists are skipped intentionally; see
        // file header comment for rationale.
        let configKV: [String: String] = [
            "platforms.homeassistant.extra.watch_all": PlatformSetupHelpers.envBool(watchAll),
            "platforms.homeassistant.extra.cooldown_seconds": String(cooldownSeconds)
        ]
        commitSave(envPairs: envPairs, configKV: configKV)
    }

    /// Open config.yaml in the user's default editor so they can manually edit
    /// the list-valued filter fields.
    func openConfigForLists() {
        context.openInLocalEditor(context.paths.configYAML)
    }
}
