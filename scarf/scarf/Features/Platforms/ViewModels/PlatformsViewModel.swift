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
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false
    var restartInProgress: Bool = false

    /// Per-platform "has config on disk" set, computed off-main in `load()`
    /// (one config.yaml + one `.env` read, vs. the old per-platform-per-render
    /// transport reads). `connectivity` / `hasConfigBlock` read this cache so a
    /// body re-render never does synchronous scp/SSH on the main thread.
    private(set) var configuredPlatforms: Set<String> = []

    /// Whether `configuredPlatforms` holds a READ rather than its empty
    /// initial value. The roster filter needs the difference: "no platform is
    /// configured" and "we have not looked yet" are the same `Set` but must
    /// render differently, or a sub-floor row the user configured themselves
    /// is hidden for the first paint and pops in when the detached load
    /// lands. Until this is true the filter treats every row as possibly
    /// configured, which is what Scarf rendered before the gate existed.
    private(set) var hasLoadedConfiguredPlatforms = false

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
            self.hasLoadedConfiguredPlatforms = true
            self.loadedChangeToken = changeToken
        }
    }

    /// Snap `selected` back to `cli` once the post-load roster no longer
    /// offers it (round-3 decision 8). Called by `PlatformsView` whenever the
    /// visible list changes — which is the moment `hasLoadedConfiguredPlatforms`
    /// flips and the moment capabilities land.
    func reconcileSelection(visible: [HermesToolPlatform]) {
        let reconciled = KnownPlatforms.reconcile(selection: selected, against: visible)
        guard reconciled.name != selected.name else { return }
        logger.info("selection \(self.selected.name, privacy: .public) left the roster; snapping to \(reconciled.name, privacy: .public)")
        selected = reconciled
    }

    func connectivity(for platform: HermesToolPlatform) -> PlatformConnectivity {
        if let pState = gatewayState?.platforms?[platform.name] {
            if let err = pState.error, !err.isEmpty { return .error(err) }
            if pState.connected == true { return .connected }
        }
        return hasConfigBlock(for: platform) ? .configured : .notConfigured
    }

    /// Does the platform have any configuration on disk — a top-level
    /// `<platform>:` block in config.yaml, a nested `platforms.<platform>.…`
    /// key, or an "identifying" env var in `.env` (e.g.
    /// `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`)?
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
    /// a top-level `<platform>:` block in config.yaml, a nested
    /// `platforms.<platform>.…` key, or an identifying env var in `.env`.
    /// Reads each source ONCE (vs. the old per-platform read).
    nonisolated static func computeConfiguredPlatforms(context: ServerContext) -> Set<String> {
        let yaml = context.readText(context.paths.configYAML) ?? ""
        // A top-level section is `<name>:` followed by ANYTHING — Hermes
        // emits preserved-but-empty sections flow-style (`slack: {}`,
        // `_strip_default_values` preserve_keys) and hand-written configs
        // carry trailing comments (`slack:  # work`). The old
        // `hasSuffix(":")` test saw neither, so a configured platform
        // rendered as unconfigured. Split at the `key: value` separator
        // colon instead — `HermesYAML.plainKeySeparatorIndex`, the same rule
        // the parser and the writers use: the first colon followed by a
        // SPACE or end-of-line (a tab there is a PyYAML ScannerError, not a
        // separator — P42c), so a colon inside the key
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
        // NESTED keys count too. Every row added to the gated set carries a
        // setup form that writes `platforms.<name>.…` and nothing at indent 0
        // (`NtfySetupViewModel.save`, `WhatsAppCloudSetupViewModel.save`), and
        // the five rows with no Scarf form at all (`yuanbao`, `teams`,
        // `google_chat`, `line`, `buzz`) are configured by `hermes setup`,
        // which writes the same nested block. Detecting only a top-level
        // section made `isConfigured` permanently false for exactly the rows
        // `isVisible`'s widen-for-current hatch exists to protect, so a failed
        // version probe removed a channel the user had set up in Scarf's own
        // form with no UI path back to it. `gateway.platforms.<name>` is
        // accepted for the same reason `HermesConfig+YAML` accepts it as the
        // alternate bridge source.
        let nestedKeys = {
            let parsed = HermesYAML.parseNestedYAML(yaml)
            var keys = Set(parsed.values.keys)
            keys.formUnion(parsed.lists.keys)
            keys.formUnion(parsed.maps.keys)
            return keys
        }()
        func hasNestedBlock(_ name: String) -> Bool {
            for path in ["platforms.\(name)", "gateway.platforms.\(name)"] {
                // The path itself (a flow map or a bare `platforms: {ntfy: …}`)
                // or anything under it.
                if nestedKeys.contains(path) { return true }
                if nestedKeys.contains(where: { $0.hasPrefix(path + ".") }) { return true }
            }
            return false
        }
        let env = HermesEnvService(context: context).load()
        var configured: Set<String> = []
        for platform in KnownPlatforms.all where platform.name != "cli" {
            if topLevel.contains(platform.name) || hasNestedBlock(platform.name) {
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
        // The gated rows whose Scarf setup form writes `.env` at all. `ntfy`
        // writes `NTFY_TOPIC` (`NtfySetupViewModel.swift:64`) and `simplex`
        // writes `SIMPLEX_WS_URL` (`SimpleXSetupViewModel.swift:65`); those
        // are the keys each form's own LOAD treats as the primary field, so
        // they are the honest "setup has started" signal. `whatsapp_cloud`
        // deliberately has no arm — its form writes config.yaml only
        // (`WhatsAppCloudSetupViewModel.swift:86-97`), and the nested-block
        // check above is what finds it. Same for the five form-less rows.
        case "ntfy": return "NTFY_TOPIC"
        case "simplex": return "SIMPLEX_WS_URL"
        default: return nil
        }
    }

    /// Restart the hermes gateway so newly-saved config takes effect. Runs on a
    /// background task so the UI stays responsive during the ~second or two
    /// `hermes gateway restart` takes.
    /// The banner for a refused restart. The reason is Hermes's own line, so
    /// it is interpolated into the already-localized stem rather than being
    /// part of a format key nobody could translate meaningfully.
    private nonisolated static func restartFailureMessage(_ detail: String?) -> String {
        let stem = String(localized: "Restart failed")
        return detail.map { "\(stem): \($0)" } ?? stem
    }

    /// The bar for a `gateway restart` verdict — THREE arms, not two (P40c).
    /// A `.unconfirmed` verdict (the s6 dispatch that prints nothing,
    /// `hermes_cli/gateway.py:5608-5629` @ v2026.9.7; the foreground
    /// `run_gateway` that never returns, `:6062-6066`) is not a failure: it
    /// gets the neutral wording and a non-failure bar, and the `load(force:)`
    /// that follows the call is what tells the real state. Pure and `static`
    /// so the three arms can be tested without a live `hermes`.
    static func restartBanner(_ outcome: HermesCLIOutcome) -> OutcomeMessage {
        if outcome.confidence == .unconfirmed {
            // `.unconfirmed`, not `.success` (P55b): the prose already says
            // nothing was proven, and a green seal over it asserts a restart
            // Hermes never confirmed — the exact two-state bug P54b's third
            // `Kind` arm exists to end.
            return .unconfirmed(GatewayActionBanner.unconfirmed(.restart, detail: outcome.detail))
        }
        return outcome.succeeded
            ? .success(String(localized: "Gateway restarted"))
            : .failure(Self.restartFailureMessage(outcome.detail))
    }

    func restartGateway() {
        restartInProgress = true
        // In-progress, not an outcome: shown in the success style because
        // nothing has failed yet, and replaced the moment the CLI returns.
        message = String(localized: "Restarting gateway…")
        messageIsFailure = false
        // The third flag has to be cleared too (P55b): a prior `.unconfirmed`
        // verdict does not auto-clear, so leaving it set paints the amber
        // question mark over this in-progress line.
        messageIsUnconfirmed = false
        Task.detached { [weak self, fileService] in
            // P40: judged by output, like every other gateway-service call
            // site — `_cmd_restart` has exit-0 refusal arms
            // (`hermes_cli/gateway.py:6047` @ v2026.9.7) and `cmd_gateway`
            // discards the return anyway (`hermes_cli/main.py:1736-1742`).
            let outcome = fileService.restartGateway()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.restartInProgress = false
                self.applySaveOutcome(Self.restartBanner(outcome))
                self.load(force: true)
            }
        }
    }
}
