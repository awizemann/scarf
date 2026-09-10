import Foundation
import ScarfCore
import os

/// Platform list/selection coordinator. Per-platform configuration now lives in
/// dedicated `<Platform>SetupViewModel` classes under `ViewModels/PlatformSetup/`.
/// This VM only manages the sidebar list, connectivity detection, and the
/// "Restart Gateway" action.
@Observable
@MainActor
final class PlatformsViewModel: OutcomeMessageHosting {
    private let logger = Logger(subsystem: "com.scarf", category: "PlatformsViewModel")
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }


    var gatewayState: GatewayState?
    var selected: HermesToolPlatform = KnownPlatforms.cli
    var message: String?
    /// Outcome of `message` (GW-F4) — the bar's colour, glyph and VoiceOver
    /// announcement come from this stored fact, never from the prose.
    var messageIsFailure = false
    var restartInProgress: Bool = false

    /// Per-platform "has config on disk" set, computed off-main in `load()`
    /// (one config.yaml + one `.env` read, vs. the old per-platform-per-render
    /// transport reads). `connectivity` / `hasConfigBlock` read this cache so a
    /// body re-render never does synchronous scp/SSH on the main thread.
    private(set) var configuredPlatforms: Set<String> = []

    var platforms: [HermesToolPlatform] { KnownPlatforms.all }

    /// Tracks the file-watcher change token this VM last loaded for, so a
    /// plain section re-entry (same token) skips the remote re-read while a
    /// real on-disk change (advanced token) or a `force` still reloads
    /// (t-aud24). The VM instance is cached in `AppCoordinator`, so this
    /// state persists across section switches.
    @ObservationIgnored private var loadedChangeToken: Date?
    @ObservationIgnored private var hasLoaded = false

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func load(changeToken: Date? = nil, force: Bool = false) {
        if !force, hasLoaded, loadedChangeToken == changeToken { return }
        hasLoaded = true
        let svc = fileService
        let ctx = context
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // Gateway state, config.yaml and `.env` all read through the
            // transport — synchronous scp/SSH round-trips on remote. Compute
            // them ONCE off main so neither a file-watcher tick nor a body
            // re-render stalls the main thread (gh#102 pattern). Cancel-prior
            // + the is-cancelled guard so an older tick's slower read can't
            // land after a newer one and latch stale data (the synchronous
            // load this replaced couldn't interleave); advance the freshness
            // token only on a committed read.
            let result = await Task.detached {
                (state: svc.loadGatewayState(), configured: Self.computeConfiguredPlatforms(context: ctx))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.gatewayState = result.state
            self.configuredPlatforms = result.configured
            self.loadedChangeToken = changeToken
        }
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
        return configuredPlatforms.contains(platform.name)
    }

    /// Compute, off main, the set of platforms with configuration on disk —
    /// a top-level `<platform>:` block in config.yaml OR an identifying env
    /// var in `.env`. Reads each source ONCE (vs. the old per-platform read).
    /// Detection mirrors the previous `hasConfigBlock` exactly.
    nonisolated static func computeConfiguredPlatforms(context: ServerContext) -> Set<String> {
        let yaml = context.readText(context.paths.configYAML) ?? ""
        // A top-level section is `<name>:` followed by ANYTHING — Hermes
        // emits preserved-but-empty sections flow-style (`slack: {}`,
        // `_strip_default_values` preserve_keys) and hand-written configs
        // carry trailing comments (`slack:  # work`). The old
        // `hasSuffix(":")` test saw neither, so a configured platform
        // rendered as unconfigured. Split at the `key: value` separator
        // colon instead — `HermesYAML.plainKeySeparatorIndex`, the same rule
        // the parser and the writers use: the first colon followed by
        // whitespace or end-of-line, so a colon inside the key
        // (`slack:dev: {}`) stays part of the key rather than truncating it
        // to a platform name the file never mentioned.
        // (`.whitespacesAndNewlines` so a CRLF config.yaml doesn't leave a
        // `\r` glued to every section name.)
        let topLevel = Set(
            yaml.components(separatedBy: "\n")
                .filter { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") }
                .compactMap { line -> String? in
                    // A leading U+FEFF is in neither `.whitespaces` nor
                    // `.whitespacesAndNewlines`, so on a BOM'd config.yaml
                    // the file's FIRST top-level section came back named
                    // "\u{FEFF}slack" and that platform rendered as
                    // unconfigured. Same root cause, same strip, as the
                    // parser and the writers.
                    let trimmed = YAMLScalar.strippingBOM(
                        line.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                    guard let colon = HermesYAML.plainKeySeparatorIndex(in: trimmed)
                    else { return nil }
                    let name = String(trimmed[trimmed.startIndex..<colon])
                        .trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return nil }
                    // Only a bare/quoted plain key is a section name; a
                    // `- item` row or a document marker is not.
                    guard !name.hasPrefix("-"), !name.hasPrefix("#") else { return nil }
                    return name
                }
        )
        // Tolerant `load()` on purpose (GW-F6 / audit DI L10): this decides
        // which platform rows LOOK configured, and nothing is written as a
        // result. A blip shows one platform as unconfigured for one paint
        // and self-corrects on the next read. The setup FORMS, whose blank
        // fields turn into `unset` writes, take `loadProven` instead.
        let env = HermesEnvService(context: context).load()
        var configured: Set<String> = []
        for platform in KnownPlatforms.all where platform.name != "cli" {
            if topLevel.contains(platform.name) {
                configured.insert(platform.name)
            } else if let key = identifyingEnvVar(for: platform.name),
                      let value = env[key], !value.isEmpty {
                configured.insert(platform.name)
            }
        }
        return configured
    }

    /// Primary credential env var for a platform — the one whose presence
    /// signals that the user has started setup. Centralized here so both the
    /// connectivity detector and future diagnostics agree on the check.
    nonisolated private static func identifyingEnvVar(for platformName: String) -> String? {
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
        // `imessage` was Scarf's own spelling for this adapter; it is no
        // longer a KnownPlatforms row, so that arm was unreachable.
        case "bluebubbles": return "BLUEBUBBLES_SERVER_URL"
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
        // In-progress, not an outcome: shown in the success style because
        // nothing has failed yet, and replaced the moment the CLI returns.
        message = String(localized: "Restarting gateway…")
        messageIsFailure = false
        Task.detached { [weak self, fileService] in
            let result = fileService.runHermesCLI(args: ["gateway", "restart"], timeout: 30)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.restartInProgress = false
                self.applySaveOutcome(
                    result.exitCode == 0
                        ? .success(String(localized: "Gateway restarted"))
                        : .failure(String(localized: "Restart failed"))
                )
                self.load(force: true)
            }
        }
    }
}
