import Foundation
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
final class HomeAssistantSetupViewModel {
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

    func load() {
        let env = HermesEnvService().load()
        url = env["HASS_URL"] ?? "http://homeassistant.local:8123"
        token = env["HASS_TOKEN"] ?? ""

        let cfg = HermesFileService().loadConfig().homeAssistant
        watchAll = cfg.watchAll
        cooldownSeconds = cfg.cooldownSeconds
        watchDomains = cfg.watchDomains
        watchEntities = cfg.watchEntities
        ignoreEntities = cfg.ignoreEntities
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
        message = PlatformSetupHelpers.saveForm(envPairs: envPairs, configKV: configKV)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }

    /// Open config.yaml in the user's default editor so they can manually edit
    /// the list-valued filter fields.
    func openConfigForLists() {
        NSWorkspace.shared.open(URL(fileURLWithPath: HermesPaths.configYAML))
    }
}
