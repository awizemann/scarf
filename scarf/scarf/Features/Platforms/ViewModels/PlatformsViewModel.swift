import Foundation
import os

/// Platform list/selection coordinator. Per-platform configuration now lives in
/// dedicated `<Platform>SetupViewModel` classes under `ViewModels/PlatformSetup/`.
/// This VM only manages the sidebar list, connectivity detection, and the
/// "Restart Gateway" action.
@Observable
@MainActor
final class PlatformsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "PlatformsViewModel")
    private let fileService = HermesFileService()

    var gatewayState: GatewayState?
    var selected: HermesToolPlatform = KnownPlatforms.cli
    var message: String?
    var restartInProgress: Bool = false

    var platforms: [HermesToolPlatform] { KnownPlatforms.all }

    func load() {
        gatewayState = fileService.loadGatewayState()
    }

    func connectivity(for platform: HermesToolPlatform) -> PlatformConnectivity {
        if let pState = gatewayState?.platforms?[platform.name] {
            if let err = pState.error, !err.isEmpty { return .error(err) }
            if pState.connected == true { return .connected }
        }
        return hasConfigBlock(for: platform) ? .configured : .notConfigured
    }

    /// Does the platform have any configuration on disk — either a top-level
    /// `<platform>:` block in config.yaml, or an "identifying" env var in
    /// `.env` (e.g. `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`)?
    ///
    /// We need the env-var check because the new per-platform setup forms
    /// write credentials to `.env` primarily; most platforms don't create a
    /// YAML block until the user saves a behavior toggle. Without this,
    /// platforms configured via the new flow would display as "Not configured"
    /// until the first YAML edit.
    func hasConfigBlock(for platform: HermesToolPlatform) -> Bool {
        if platform.name == "cli" { return true }
        let yaml = (try? String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8)) ?? ""
        for line in yaml.components(separatedBy: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            if line.trimmingCharacters(in: .whitespaces) == "\(platform.name):" { return true }
        }
        // Env-var fallback: any identifying env var for this platform counts
        // as "configured". Uses the shared `identifyingEnvVar(for:)` mapping.
        if let key = Self.identifyingEnvVar(for: platform.name) {
            let env = HermesEnvService().load()
            if let value = env[key], !value.isEmpty { return true }
        }
        return false
    }

    /// Primary credential env var for a platform — the one whose presence
    /// signals that the user has started setup. Centralized here so both the
    /// connectivity detector and future diagnostics agree on the check.
    private static func identifyingEnvVar(for platformName: String) -> String? {
        switch platformName {
        case "telegram": return "TELEGRAM_BOT_TOKEN"
        case "discord": return "DISCORD_BOT_TOKEN"
        case "slack": return "SLACK_BOT_TOKEN"
        case "whatsapp": return "WHATSAPP_ENABLED"
        case "signal": return "SIGNAL_ACCOUNT"
        case "email": return "EMAIL_ADDRESS"
        case "matrix": return "MATRIX_HOMESERVER"
        case "mattermost": return "MATTERMOST_URL"
        case "feishu": return "FEISHU_APP_ID"
        case "imessage": return "BLUEBUBBLES_SERVER_URL"
        case "homeassistant": return "HASS_TOKEN"
        case "webhook": return "WEBHOOK_ENABLED"
        default: return nil
        }
    }

    /// Restart the hermes gateway so newly-saved config takes effect. Runs on a
    /// background task so the UI stays responsive during the ~second or two
    /// `hermes gateway restart` takes.
    func restartGateway() {
        restartInProgress = true
        message = "Restarting gateway…"
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["gateway", "restart"], timeout: 30)
            await MainActor.run {
                self.restartInProgress = false
                self.message = result.exitCode == 0 ? "Gateway restarted" : "Restart failed"
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }
}
