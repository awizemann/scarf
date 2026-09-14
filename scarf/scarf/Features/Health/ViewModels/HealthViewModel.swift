import Foundation
import Darwin
import ScarfCore
#if canImport(AppKit)
import AppKit
#endif
import os

/// Observed state of the local `hermes dashboard` web UI (introduced in
/// Hermes v0.10.x). `port` defaults to 9119 — the CLI's default and the only
/// value Scarf launches with today.
struct WebDashboardStatus: Sendable, Equatable {
    var running: Bool
    var port: Int
    /// True while a start/stop transition is in flight so the UI can disable
    /// buttons and show a spinner.
    var busy: Bool

    static let defaultPort = 9119
    static let unknown = WebDashboardStatus(running: false, port: defaultPort, busy: false)
}

struct HealthCheck: Identifiable {
    let id = UUID()
    let label: String
    let status: CheckStatus
    let detail: String?

    enum CheckStatus {
        case ok
        case warning
        case error
    }
}

struct HealthSection: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let checks: [HealthCheck]
}

@Observable
final class HealthViewModel {
    let context: ServerContext
    private let fileService: HermesFileService
    private let subscriptionService: NousSubscriptionService
    /// Capability snapshot at view-init time. Environment capabilities
    /// arrive after `init` runs, so `HealthView` re-creates the VM via
    /// `attachCapabilitiesIfNeeded()` once the store resolves — same
    /// pattern as `MessagingGatewayViewModel.capabilities`. Used to gate
    /// the Tool Gateway section's Web Extract row on `hasWebExtractAux`.
    let capabilities: HermesCapabilities

    init(context: ServerContext = .local, capabilities: HermesCapabilities = .empty) {
        self.context = context
        self.fileService = HermesFileService(context: context)
        self.subscriptionService = NousSubscriptionService(context: context)
        self.capabilities = capabilities
    }


    var version = ""
    var updateInfo = ""
    var hasUpdate = false
    /// True when the update check couldn't reach `origin` (offline / no
    /// network / fetch timeout) so Hermes printed neither an "Update
    /// available…" line nor "Up to date" (`banner.py`'s `check_for_updates`
    /// returns `None` on a failed `git fetch` — `_startup_fast.py` then
    /// prints nothing at all). Distinct from `hasUpdate == false`, which
    /// also covers the genuine "confirmed current" case — collapsing the
    /// two would silently tell an offline user they're up to date.
    var updateStatusUnknown = false
    var statusSections: [HealthSection] = []
    var doctorSections: [HealthSection] = []
    var issueCount = 0
    var warningCount = 0
    var okCount = 0
    var isLoading = false
    var hermesRunning = false
    var hermesPID: pid_t?
    var actionMessage: String?

    /// Text output from `hermes dump` / `hermes debug share`. Shown in an expandable panel.
    var diagnosticsOutput: String = ""
    var isSharingDebug = false

    // MARK: - Supply-chain audit (`hermes security audit`, v0.15)

    /// True while `hermes security audit` is shelling out so the header button
    /// can show a spinner. The OSV.dev lookup is a network round-trip — easily
    /// a couple seconds — so this runs off MainActor and never blocks the UI.
    var isRunningAudit = false
    /// Inline result strip for the last audit run. Nil before the first run.
    /// Mirrors the `--setup-browser` inline-status pattern in `HealthView` —
    /// success summary or the tail of the advisory list / stderr on failure.
    var auditMessage: String?

    // MARK: - Sessions database optimize (`hermes sessions optimize`, v0.16)

    /// True while `hermes sessions optimize` is shelling out so the header
    /// button can show a spinner. Compacting the FTS index + VACUUM can take
    /// a few seconds, so this runs off MainActor and never blocks the UI.
    var isRunningSessionsOptimize = false
    /// Inline result strip for the last optimize run. Nil before the first run.
    /// Mirrors the audit-message pattern — success summary or the tail of
    /// stderr on failure.
    var sessionsOptimizeMessage: String?

    // MARK: - xAI retired-model migration (`hermes migrate xai`, v0.15)

    /// The configured model+provider, refreshed from `loadConfig()` whenever
    /// the view loads or a migration completes. Drives the retired-model warning.
    var configuredModel: String = ""
    var configuredProvider: String = ""
    /// True while `hermes migrate xai` is in flight.
    var isMigratingXAI = false
    /// Inline result strip for the last migration run.
    var migrateXAIMessage: String?

    /// May-15 (v0.15) retired xAI model IDs. When the configured model is one
    /// of these AND the provider is an xAI variant, Health surfaces a warning
    /// row with a one-tap `hermes migrate xai`. These mirror the keys in
    /// `ModelCatalogService.modelAliases` (kept local for clarity — the Health
    /// layer shouldn't reach across into the catalog's alias map).
    static let retiredXAIModels: Set<String> = [
        "grok-4-0709",
        "grok-4-fast-reasoning",
        "grok-4-fast-non-reasoning",
        "grok-4-1-fast-reasoning",
        "grok-4-1-fast-non-reasoning",
        "grok-code-fast-1",
        "grok-3",
        "grok-imagine-image-pro",
    ]

    /// True when the configured model is a retired xAI model under an xAI
    /// provider. The view gates the warning on this AND `hasXAIModelRetirement`.
    var configuredModelIsRetiredXAI: Bool {
        let providerIsXAI = configuredProvider == "xai" || configuredProvider == "xai-oauth"
        guard providerIsXAI else { return false }
        // Tolerate a `provider/model` form just in case the config stored it
        // fully qualified — compare on the trailing path component too.
        let bareModel = configuredModel.split(separator: "/").last.map(String.init) ?? configuredModel
        return Self.retiredXAIModels.contains(configuredModel)
            || Self.retiredXAIModels.contains(bareModel)
    }

    /// Liveness + control state for `hermes dashboard` (local web UI). The
    /// section in `HealthView` is hidden for remote contexts — the dashboard
    /// binds 127.0.0.1 by default and remote probing / tunneling is out of
    /// scope for v1.
    var dashboardStatus: WebDashboardStatus = .unknown
    /// Our own spawned subprocess, if the user hit "Launch Dashboard" from
    /// Scarf. Nil when the dashboard was started externally (we still detect
    /// it via the probe but can't terminate it cleanly via `Process.terminate`).
    private var dashboardProcess: Process?
    /// Background polling loop; started in `startDashboardMonitoring()` and
    /// cancelled on view disappear.
    private var dashboardProbeTask: Task<Void, Never>?
    /// In-flight `load()` task, stored so navigating away mid-load cancels
    /// the remaining SSH round-trips instead of letting all 4-5 complete
    /// against an unreachable remote. (t-aud11)
    private var loadTask: Task<Void, Never>?

    func load() {
        isLoading = true
        let ctx = context
        let svc = fileService
        let subSvc = subscriptionService
        let caps = capabilities
        // Health runs four sync transport-mediated commands plus a process
        // probe — that's 4-5 ssh round-trips on remote, easily 1-2s. Detach
        // the whole load, store the handle, and bail between round-trips if
        // the user navigates away (cancelLoad()).
        loadTask?.cancel()
        loadTask = Task.detached { [weak self] in
            // The five probes are mutually independent — none reads another's
            // output — so they run CONCURRENTLY rather than as five serial
            // remote round-trips. On a remote host this is the difference
            // between ~5×RTT and ~1×RTT on every Health visit (C10).
            // Each rides its own ``OffPool/run(_:)`` because the underlying
            // calls BLOCK (process spawn / SSH exec); running them as bare
            // `async let` would park seven cooperative-pool threads — and so
            // did the `Task.detached` this said before round-5 P52, since a
            // detached task is off the main actor but still ON that pool.
            async let pidProbe        = OffPool.run { svc.hermesPID() }
            async let versionProbe    = OffPool.run { Self.probeVersion(ctx) }
            // Every `runHermes` NAMES its timeout (P22's rule): the 60 s
            // default in `ServerContext+Mac.swift:21` is silent, so a site
            // that omits it cannot be read as having chosen anything. These
            // two are read-only probes behind a spinner.
            async let statusProbe     = OffPool.run { ctx.runHermes(["status"], timeout: 60).output }
            async let doctorProbe     = OffPool.run { ctx.runHermes(["doctor"], timeout: 60).output }
            async let subscriptionRead = OffPool.run { subSvc.loadState() }
            async let configRead      = OffPool.run { svc.loadConfig() }
            // v0.18+ — `computer-use permissions status --json` exits 1
            // when not ready, which is a STATE, not a failure, so the
            // stdout is parsed regardless of exit code. Skipped entirely
            // on hosts without the flag so no extra round-trip is spent.
            async let computerUseProbe = OffPool.run { () -> HermesComputerUseStatus? in
                guard caps.hasComputerUsePermissionsJSON else { return nil }
                // cua-driver's own probes cap at ~12s + ~10s + 5s inside
                // Hermes, so 45 bounds the whole thing without truncating a
                // slow-but-succeeding driver (C10: every subprocess has one).
                // stdout ONLY: cua-driver logs to stderr, and a warning
                // line carrying a `}` would truncate a brace-sliced payload.
                return HermesComputerUseStatus.parse(
                    ctx.runHermesSplit(["computer-use", "permissions", "status", "--json"], timeout: 45).stdout)
            }

            let pid = await pidProbe
            let versionOutput = await versionProbe
            let statusOutput = await statusProbe
            let doctorOutput = await doctorProbe
            let subscription = await subscriptionRead
            let config = await configRead
            let computerUse = await computerUseProbe
            // Cancellation drops the commit rather than painting a stale
            // panel (t-aud11). It no longer aborts BETWEEN round-trips —
            // there are no "between"s left — but since all six now overlap,
            // the window they occupy is one round-trip, not five.
            if Task.isCancelled { return }

            let lines = versionOutput.components(separatedBy: "\n")
            let version = lines.first ?? ""
            let updateStatus = Self.parseUpdateStatus(lines: lines)
            let hasUpdate = updateStatus.hasUpdate
            let updateInfo = updateStatus.updateInfo
            let updateStatusUnknown = updateStatus.unknown

            let statusSections = Self.parseOutputStatic(statusOutput)
                + [Self.toolGatewaySection(subscription: subscription, config: config, capabilities: caps)]
                + (computerUse.map { [Self.computerUseSection($0)] } ?? [])
            let doctorSections = Self.parseOutputStatic(doctorOutput)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hermesPID = pid
                self.hermesRunning = pid != nil
                self.version = version
                self.updateInfo = updateInfo
                self.hasUpdate = hasUpdate
                self.updateStatusUnknown = updateStatusUnknown
                self.statusSections = statusSections
                self.doctorSections = doctorSections
                self.configuredModel = config.model
                self.configuredProvider = config.provider
                self.computeCounts()
                self.isLoading = false
            }
        }
    }

    /// Cancel an in-flight `load()` (called on view disappear) so a slow
    /// remote's remaining SSH round-trips stop instead of running to
    /// completion behind the user's back. (t-aud11)
    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    /// Synthesize a Tool Gateway health section from the subscription state +
    /// `platform_toolsets` table. Runs alongside the other status sections so
    /// the user sees at a glance whether their Nous Portal subscription is
    /// wired up.
    ///
    /// This is distinct from the "Messaging Gateway" (inbound Slack/Discord/…
    /// requests) — the two are unrelated systems that unfortunately share the
    /// "gateway" name in Hermes's CLI output.
    ///
    /// `nonisolated` so `load()` can call it from `Task.detached` alongside
    /// `parseOutputStatic` without hopping back to MainActor.
    /// Computer Use readiness card from `computer-use permissions status
    /// --json` (v0.18+).
    ///
    /// Two things this deliberately does NOT do:
    /// - It never renders an unknown boolean as "denied". Hermes uses
    ///   `None` for "we couldn't ask" (driver missing, probe failed), and
    ///   telling a user to grant a permission they may already hold is
    ///   worse than saying "unknown".
    /// - It only shows the macOS TCC rows when `can_grant` is true. On a
    ///   remote Linux or Windows host there is no TCC model at all, and
    ///   readiness is driver health — Hermes's own CLI branches the same
    ///   way (`if st["can_grant"]: … else: driver health`).
    ///
    /// `nonisolated` so `load()` builds it on the detached hop.
    nonisolated static func computerUseSection(_ status: HermesComputerUseStatus) -> HealthSection {
        var checks: [HealthCheck] = []

        if !status.platformSupported {
            checks.append(HealthCheck(
                label: "Not supported on \(status.platform)",
                status: .warning,
                detail: "Computer Use runs on macOS, Windows and Linux."
            ))
        } else if !status.installed {
            checks.append(HealthCheck(
                label: "cua-driver not installed",
                status: .warning,
                detail: "Run `hermes computer-use install` on the host."
            ))
        } else {
            checks.append(HealthCheck(
                label: "cua-driver installed",
                status: .ok,
                detail: status.version
            ))
            if status.hasTCCPermissions {
                // Tri-state: nil = unknown, rendered as a warning with the
                // reason rather than as a denial.
                func tcc(_ label: String, _ value: Bool?) -> HealthCheck {
                    switch value {
                    case .some(true):  return HealthCheck(label: "\(label) granted", status: .ok, detail: nil)
                    case .some(false): return HealthCheck(
                        label: "\(label) not granted",
                        status: .error,
                        detail: "Run `hermes computer-use permissions grant` on the host."
                    )
                    case nil: return HealthCheck(
                        label: "\(label) unknown",
                        status: .warning,
                        detail: status.error ?? "cua-driver did not report this permission."
                    )
                    }
                }
                checks.append(tcc("Accessibility", status.accessibility))
                checks.append(tcc("Screen Recording", status.screenRecording))
                // `screen_recording_capturable` — a SECOND, distinct signal:
                // the grant can be recorded as given while capture still
                // fails (a stale TCC entry after an app update; the driver
                // needs a restart or a re-grant). Hermes's own doctor treats
                // granted-but-not-capturable as a failing row that outranks
                // the plain pass (`tools/computer_use/doctor.py:204-207` at
                // v2026.9.7), so Scarf must not report "granted" and stop.
                //
                // Tri-state exactly like the two rows above: nil means Scarf
                // could not ask (driver missing, probe failed), never
                // "cannot capture". Only rendered when Screen Recording is
                // actually granted — below that the grant row is the whole
                // story and a second unknown row is noise.
                if status.screenRecording == true {
                    switch status.screenRecordingCapturable {
                    case .some(true):
                        checks.append(HealthCheck(
                            label: "Screen Recording capturable", status: .ok, detail: nil))
                    case .some(false):
                        checks.append(HealthCheck(
                            label: "Screen Recording granted but not capturable",
                            status: .error,
                            detail: "The permission may need a re-grant in System Settings, or cua-driver needs a restart."
                        ))
                    case nil:
                        checks.append(HealthCheck(
                            label: "Screen Recording capture unknown",
                            status: .warning,
                            detail: status.error ?? "cua-driver did not report whether capture actually works."
                        ))
                    }
                }
            } else {
                checks.append(HealthCheck(
                    label: status.ready == true ? "Driver healthy" : "Driver not ready",
                    status: status.ready == true ? .ok : (status.ready == nil ? .warning : .error),
                    detail: "No permission toggles on \(status.platform)."
                ))
            }
        }

        for check in status.checks where check.isProblem {
            // Only cua-driver's KNOWN failure spellings paint red; an
            // unrecognised status is surfaced without claiming a fault (see
            // `HermesComputerUseCheck.severity`).
            checks.append(HealthCheck(
                label: check.label.isEmpty ? "cua-driver check" : check.label,
                status: check.severity == .failure ? .error : .warning,
                detail: check.message.isEmpty ? nil : check.message
            ))
        }
        if let error = status.error, !error.isEmpty {
            checks.append(HealthCheck(label: "Probe error", status: .warning, detail: error))
        }

        return HealthSection(title: "Computer Use", icon: "cursorarrow.rays", checks: checks)
    }

    nonisolated private static func toolGatewaySection(subscription: NousSubscriptionState, config: HermesConfig, capabilities: HermesCapabilities) -> HealthSection {
        var checks: [HealthCheck] = []

        let subscriptionCheck: HealthCheck = {
            if subscription.subscribed {
                return HealthCheck(
                    label: "Nous Portal subscription active",
                    status: .ok,
                    detail: "Tool requests route through the Nous Portal gateway."
                )
            }
            if subscription.present {
                return HealthCheck(
                    label: "Signed in, but Nous isn't the active provider",
                    status: .warning,
                    detail: "Open Settings → General and pick Nous Portal to route tools through the gateway."
                )
            }
            return HealthCheck(
                label: "Not subscribed",
                status: .warning,
                detail: "Run `hermes auth` and pick Nous Portal to enable subscription-gated tools."
            )
        }()
        checks.append(subscriptionCheck)

        if !config.platformToolsets.isEmpty {
            let platforms = config.platformToolsets.keys.sorted()
            for platform in platforms {
                let toolsets = config.platformToolsets[platform] ?? []
                checks.append(HealthCheck(
                    label: "\(platform): \(toolsets.count) toolset\(toolsets.count == 1 ? "" : "s")",
                    status: .ok,
                    detail: toolsets.joined(separator: ", ")
                ))
            }
        }

        var auxCandidates = [
            ("vision", config.auxiliary.vision.provider),
            ("web_extract", config.auxiliary.webExtract.provider),
            ("compression", config.auxiliary.compression.provider),
            ("session_search", config.auxiliary.sessionSearch.provider),
            ("skills_hub", config.auxiliary.skillsHub.provider),
            ("approval", config.auxiliary.approval.provider),
            ("mcp", config.auxiliary.mcp.provider),
            ("curator", config.auxiliary.curator.provider),
        ]
        // `auxiliary.web_extract.*` was deleted from the host's config
        // schema at v0.20.6+ (`HermesCapabilities.hasWebExtractAux`, an
        // inverse flag) — `web_extract` no longer routes through an
        // auxiliary LLM at all, so surfacing it here would report on a
        // config block the host ignores.
        if !capabilities.hasWebExtractAux {
            auxCandidates.removeAll { $0.0 == "web_extract" }
        }
        let auxOnNous = auxCandidates.filter { $0.1 == "nous" }.map(\.0)
        if !auxOnNous.isEmpty {
            checks.append(HealthCheck(
                label: "Auxiliary tasks routed through Nous",
                status: subscription.subscribed ? .ok : .warning,
                detail: auxOnNous.joined(separator: ", ")
            ))
        }

        return HealthSection(
            title: "Tool Gateway",
            icon: "arrow.triangle.branch",
            checks: checks
        )
    }

    func refreshProcessStatus() {
        let svc = fileService
        Task.detached { [weak self] in
            let pid = svc.hermesPID()
            await MainActor.run { [weak self] in
                self?.hermesPID = pid
                self?.hermesRunning = pid != nil
            }
        }
    }

    // MARK: - Hermes control
    //
    // The Health panel's Start / Stop / Restart buttons. Same
    // `hermes_control_action` shape as the menu bar's controls
    // (`HermesLiveRegistry` in `scarfApp.swift`), distinguished only by
    // `source` — so a restart here likewise reports one `restart`, never a
    // `stop` plus a `start`.

    /// Records the THREE-state outcome (P40b). A gateway verdict that could
    /// not confirm — an s6 host, where `_dispatch_via_service_manager_if_s6`
    /// prints nothing on success (`hermes_cli/gateway.py:5608-5629` @
    /// v2026.9.7) — is neither a success nor a refusal, and recording it as
    /// `failed` put a healthy container host into the failure funnel.
    private static func recordControlAction(
        _ action: UsageEvent.ControlAction, _ confidence: HermesCLIOutcome.Confidence
    ) {
        Analytics.record(.hermesControlAction(
            action: action, source: .healthPanel, outcome: .init(confidence)
        ))
    }

    /// True while Start / Stop / Restart is in flight. The buttons disable on
    /// it, so the busy state actually renders instead of the window freezing
    /// for the length of a remote `gateway start`.
    private(set) var isControlBusy = false

    func stopHermes() {
        guard !isControlBusy else { return }
        isControlBusy = true
        actionMessage = "Stopping…"
        let svc = fileService
        Task { [weak self] in
            // `stopHermes()` signals a process (an SSH round-trip on remote);
            // it never belonged on the MainActor. Detached, matching the
            // `runDebugShare` / `runAudit` precedent below.
            let outcome = await Task.detached { svc.stopHermes() }.value
            guard let self else { return }
            self.isControlBusy = false
            // P40: `stopHermes()` returns the OUTPUT verdict now, so the
            // Analytics outcome this feeds is no longer an exit code that
            // `_cmd_stop` returns whatever happened
            // (`hermes_cli/gateway.py:5974-6000` @ v2026.9.7). P40b made it
            // three-valued.
            Self.recordControlAction(.stop, outcome.confidence)
            self.actionMessage = Self.controlMessage(
                verb: .stop,
                done: String(localized: "Gateway stopped"),
                failed: String(localized: "Stop failed"),
                outcome: outcome
            )
            self.settleAndRefresh(after: 2)
        }
    }

    func startHermes() {
        guard !isControlBusy else { return }
        isControlBusy = true
        actionMessage = "Starting…"
        let ctx = context
        Task { [weak self] in
            let outcome = await Task.detached { Self.runGateway(.start, ctx) }.value
            guard let self else { return }
            self.isControlBusy = false
            Self.recordControlAction(.start, outcome.confidence)
            // P40: judged by the backend's own success line, not the exit
            // code — `launchd_start` returns WITHOUT `✓ Service started` when
            // the bootstrap degrades (`hermes_cli/gateway.py:3926-3928`,
            // `:3938-3939` @ v2026.9.7) and still exits 0.
            self.actionMessage = Self.controlMessage(
                verb: .start,
                done: String(localized: "Gateway started"),
                failed: String(localized: "Start failed"),
                outcome: outcome
            )
            self.settleAndRefresh(after: 3)
        }
    }

    func restartHermes() {
        guard !isControlBusy else { return }
        isControlBusy = true
        actionMessage = "Restarting…"
        let svc = fileService
        let ctx = context
        Task { [weak self] in
            let stop = await Task.detached { svc.stopHermes() }.value
            try? await Task.sleep(for: .seconds(2))
            let start = await Task.detached { Self.runGateway(.start, ctx) }.value
            guard let self else { return }
            self.isControlBusy = false
            // A restart only succeeded if both halves did; a stop that found
            // nothing running still has to bring the gateway back — and under
            // round-4 decision 2 that stop is itself a success, so this
            // conjunction now means what it says.
            Self.recordControlAction(
                .restart, .combined(stop.confidence, start.confidence)
            )
            self.actionMessage = Self.controlMessage(
                verb: .restart,
                done: String(localized: "Gateway restarted"),
                failed: String(localized: "Restart failed"),
                outcome: start
            )
            self.settleAndRefresh(after: 3)
        }
    }

    /// Run one gateway service verb and judge it by output (P40). Static and
    /// `nonisolated` so it can be called from the detached hop the three
    /// control actions share (charter C10).
    private nonisolated static func runGateway(
        _ verb: HermesGatewayServiceVerdict.Verb, _ context: ServerContext
    ) -> HermesCLIOutcome {
        let result = context.runHermes(HermesGatewayServiceVerdict.argv(verb), timeout: 60)
        return HermesGatewayServiceVerdict.judge(
            verb: verb, output: result.output, exitCode: result.exitCode
        )
    }

    /// The banner for one control action. Round-4 decision 2: the success
    /// wording claims the state, and a Stop that found nothing running says
    /// so in a neutral note instead of being reported either way.
    /// Internal rather than `private` so the three arms can be tested
    /// directly: this VM builds its own `HermesFileService` and there is no
    /// seam to inject a fake `hermes` through.
    nonisolated static func controlMessage(
        verb: HermesGatewayServiceVerdict.Verb,
        done: String, failed: String, outcome: HermesCLIOutcome
    ) -> String {
        // P40c: `.unconfirmed` is its own arm. `settleAndRefresh` re-probes
        // right after, so the honest neutral line is also the useful one.
        if outcome.confidence == .unconfirmed {
            return GatewayActionBanner.unconfirmed(verb, detail: outcome.detail)
        }
        guard outcome.succeeded else {
            return outcome.detail.map { "\(failed): \($0)" } ?? failed
        }
        return outcome.warning.map { "\(done) — \($0)" } ?? done
    }

    /// Give the process time to settle, re-probe, then clear the transient
    /// message. Shared by the three control actions so none of them can grow
    /// its own timing.
    private func settleAndRefresh(after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            self.refreshProcessStatus()
            self.actionMessage = nil
        }
    }

    /// Parses `hermes status` / `hermes doctor` section output. `nonisolated
    /// static` so `load()`'s detached probe task can call it off the main
    /// actor (charter C10).
    nonisolated static func parseOutputStatic(_ output: String) -> [HealthSection] {
        var sections: [HealthSection] = []
        var currentTitle = ""
        var currentChecks: [HealthCheck] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("◆ ") {
                if !currentTitle.isEmpty {
                    sections.append(HealthSection(
                        title: currentTitle,
                        icon: iconForSectionStatic(currentTitle),
                        checks: currentChecks
                    ))
                }
                currentTitle = String(trimmed.dropFirst(2))
                currentChecks = []
                continue
            }

            if trimmed.hasPrefix("✓ ") {
                let text = String(trimmed.dropFirst(2))
                let (label, detail) = splitCheckStatic(text)
                currentChecks.append(HealthCheck(label: label, status: .ok, detail: detail))
            } else if trimmed.hasPrefix("⚠ ") || trimmed.hasPrefix("⚠") {
                let text = trimmed.replacingOccurrences(of: "⚠ ", with: "").replacingOccurrences(of: "⚠", with: "")
                let (label, detail) = splitCheckStatic(text)
                currentChecks.append(HealthCheck(label: label, status: .warning, detail: detail))
            } else if trimmed.hasPrefix("✗ ") {
                let text = String(trimmed.dropFirst(2))
                let (label, detail) = splitCheckStatic(text)
                currentChecks.append(HealthCheck(label: label, status: .error, detail: detail))
            } else if trimmed.hasPrefix("→ ") || trimmed.hasPrefix("Error:") {
                if !currentChecks.isEmpty {
                    let last = currentChecks.removeLast()
                    let extra = trimmed.replacingOccurrences(of: "→ ", with: "").replacingOccurrences(of: "Error:", with: "").trimmingCharacters(in: .whitespaces)
                    let combined = [last.detail, extra].compactMap { $0 }.joined(separator: " ")
                    currentChecks.append(HealthCheck(label: last.label, status: last.status, detail: combined))
                }
            } else if !trimmed.isEmpty && trimmed.contains(":") && !trimmed.hasPrefix("┌") && !trimmed.hasPrefix("│") && !trimmed.hasPrefix("└") && !trimmed.hasPrefix("─") && !trimmed.hasPrefix("Run ") && !trimmed.hasPrefix("Found ") && !trimmed.hasPrefix("Tip:") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let val = parts[1].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty && key.count < 30 {
                        currentChecks.append(HealthCheck(label: key, status: .ok, detail: val))
                    }
                }
            }
        }

        if !currentTitle.isEmpty {
            sections.append(HealthSection(
                title: currentTitle,
                icon: iconForSectionStatic(currentTitle),
                checks: currentChecks
            ))
        }
        return sections
    }

    nonisolated private static func splitCheckStatic(_ text: String) -> (String, String?) {
        if let range = text.range(of: ":") {
            let label = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let detail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (label, detail.isEmpty ? nil : detail)
        }
        return (text, nil)
    }

    nonisolated private static func iconForSectionStatic(_ title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("system") || lower.contains("environment") { return "desktopcomputer" }
        if lower.contains("config") { return "doc.text" }
        if lower.contains("model") || lower.contains("provider") { return "brain" }
        if lower.contains("memory") { return "memorychip" }
        if lower.contains("session") { return "list.bullet" }
        if lower.contains("gateway") || lower.contains("platform") { return "antenna.radiowaves.left.and.right" }
        if lower.contains("skill") { return "wrench.and.screwdriver" }
        if lower.contains("mcp") { return "cube.box" }
        if lower.contains("plugin") { return "puzzlepiece" }
        if lower.contains("auth") || lower.contains("credential") { return "key" }
        if lower.contains("disk") || lower.contains("storage") { return "internaldrive" }
        if lower.contains("update") { return "arrow.triangle.2.circlepath" }
        return "circle"
    }

    private func computeCounts() {
        let allChecks = (statusSections + doctorSections).flatMap(\.checks)
        okCount = allChecks.filter { $0.status == .ok }.count
        warningCount = allChecks.filter { $0.status == .warning }.count
        issueCount = allChecks.filter { $0.status == .error }.count
    }

    /// Capture `hermes dump` output — a setup summary used for debugging / support.
    /// Does NOT upload anything.
    func runDump() {
        guard !isRunningDump else { return }
        isRunningDump = true
        actionMessage = "Running dump…"
        let ctx = context
        Task { [weak self] in
            // Longer than the 60 s default on purpose: `hermes dump` walks
            // state.db and the config tree, and on a remote host that is an
            // SSH round trip over the whole thing.
            let result = await OffPool.run { ctx.runHermes(["dump"], timeout: 120) }
            guard let self else { return }
            self.isRunningDump = false
            self.diagnosticsOutput = result.output
            self.actionMessage = result.exitCode == 0
                ? "Dump captured"
                : "Dump failed (exit \(result.exitCode))"
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.actionMessage = nil
            }
        }
    }

    /// Mirrors `isSharingDebug` / `isRunningAudit` — `hermes dump` is the same
    /// class of long CLI call and was the only one still run inline.
    private(set) var isRunningDump = false

    /// Run `hermes debug share`. With `local: false` THIS UPLOADS DATA to
    /// Nous Research support infrastructure — the caller must confirm with
    /// the user first (`HealthView`'s share confirmation dialog).
    ///
    /// **`-y` is what makes the upload path work at all.** From v0.18
    /// `_confirm_upload` (`hermes_cli/debug.py`) prints "Non-interactive
    /// mode requires --yes to confirm upload" and `sys.exit(1)` whenever
    /// stdin is not a TTY — which is every invocation Scarf makes — so this
    /// button could never once have produced a URL. The user's consent is
    /// the confirmation sheet that ran before we got here; `-y` just tells
    /// Hermes that consent was collected. Pre-v0.18 hosts have neither the
    /// flag nor the gate, so the argv omits it there (argparse would reject
    /// the whole command) and the upload proceeds as it always did.
    ///
    /// `local: true` passes `--local`, which collects the identical bundle
    /// and prints it WITHOUT any network I/O (`run_debug_share`'s first
    /// branch). The flag predates every version Scarf supports, so it needs
    /// no gate — it is the "just show me the report" answer for a user who
    /// does not want to upload.
    func runDebugShare(local: Bool = false) {
        isSharingDebug = true
        actionMessage = local ? "Collecting debug report…" : "Uploading debug report…"
        let argv = Self.debugShareArguments(local: local, capabilities: capabilities)
        Task.detached { [fileService, self] in
            let result = await OffPool.run {
                fileService.runHermesCLI(args: argv, timeout: 120)
            }
            // P54, round-6: judged by output. `run_debug_share` prints
            // `  (failed to upload: …)` AFTER the `Debug report uploaded:`
            // block, at exit 0 (`hermes_cli/debug.py:490`, `:494` @
            // `v2026.9.7`), so a run that got two of three pastes up read
            // identically to a clean one. See ``HermesDebugShareVerdict``.
            let outcome = HermesDebugShareVerdict.judge(
                output: result.output, exitCode: result.exitCode, local: local
            )
            await MainActor.run {
                self.isSharingDebug = false
                self.diagnosticsOutput = result.output
                self.actionMessage = Self.debugShareSummary(outcome: outcome, local: local)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.actionMessage = nil
                }
            }
        }
    }

    /// The strip text for a `debug share`, decided in one place so it is
    /// reachable from a test without a live `hermes` (the P47b convention).
    /// Three branches, not two: `.unconfirmed` is exit 0 with no
    /// `Debug report uploaded:` line, where there is no failure to report and
    /// nothing worth quoting — and the exit code stays out of it.
    nonisolated static func debugShareSummary(outcome: HermesCLIOutcome, local: Bool) -> String {
        if outcome.succeeded {
            let base = local
                ? String(localized: "Report collected")
                : String(localized: "Upload complete")
            // `--local` never uploads, so the verdict returns no warning for
            // it (``HermesDebugShareVerdict/judge(output:exitCode:local:)``
            // short-circuits) and `base` stands alone. A warning here is
            // therefore always the partial-UPLOAD arm.
            guard let note = outcome.warning, !note.isEmpty else { return base }
            // A partial upload is NOT "Upload complete": the links are in
            // the output either way, but the list is short and only Hermes
            // knows which target dropped out.
            return String(localized: "Upload partly complete. \(note)")
        }
        // Confidence alone, the same guard shape `sessionsOptimizeSummary`
        // uses: `judge` fills `detail` with `lines.last` on every arm, so an
        // unconfirmed run would otherwise be reported as failing with an
        // unrelated `Uploading...` line as its stated reason.
        if outcome.confidence == .unconfirmed {
            return String(localized: "hermes debug share printed no result. Check the host.")
        }
        let base = local
            ? String(localized: "Collection failed")
            : String(localized: "Upload failed")
        guard let detail = outcome.detail, !detail.isEmpty else { return base }
        return "\(base). \(detail)"
    }

    /// argv for `debug share`. Extracted so the gate is testable without a
    /// live host: on a pre-v0.18 host `-y` must be ABSENT (argparse would
    /// reject the whole command), and `--local` and `-y` are mutually
    /// exclusive by construction — there is nothing to confirm when nothing
    /// is uploaded.
    nonisolated static func debugShareArguments(
        local: Bool, capabilities: HermesCapabilities
    ) -> [String] {
        var args = ["debug", "share"]
        if local {
            args.append("--local")
        } else if capabilities.hasDebugShareYes {
            args.append("-y")
        }
        return args
    }

    /// argv for the supply-chain audit. NB the verb is `security audit`; bare
    /// `hermes audit` is not a CLI verb and routes to an agent chat turn
    /// instead of running the scan (charter C5).
    ///
    /// `--fail-on critical` is passed EXPLICITLY even though it is also the
    /// parser default (hermes_cli/subcommands/security.py:26 at v2026.9.7, and
    /// the same default, and the same 0/1/2 exit contract, back at
    /// v2026.5.29:12384-12389 — the release `security audit` first shipped in,
    /// which is exactly the `hasHermesAudit` floor gating this button). The
    /// exit code is the only
    /// thing distinguishing "found advisories" from "the scan broke", so the
    /// threshold that produces it must be Scarf's choice, not whatever a
    /// future Hermes changes the default to.
    static let auditArgs = ["security", "audit", "--fail-on", "critical"]

    /// Run `hermes security audit` (v0.15 OSV.dev supply-chain scan) off
    /// MainActor. Non-destructive read-only verb.
    ///
    /// The exit code here has THREE meanings, not two
    /// (`hermes_cli/security_audit.py::cmd_security_audit`, v2026.9.7:286-312,
    /// forwarded verbatim by `hermes_cli/main.py:2074-2075`):
    /// 0 = scan ran clean, 1 = scan ran and FOUND advisories at or above
    /// `--fail-on` (`return int(any(...))`, :311-312), 2 = the scan itself
    /// failed (a bad `--fail-on`, :293, or an OSV `RuntimeError`, :307, both
    /// printed to stderr). Rendering exit 1 as "Audit failed" told the user the
    /// scan broke exactly when it had worked and had something to say. The
    /// contract is identical at v2026.6.19:562-576, so this does not change
    /// what a pre-target host renders (charter C1).
    func runAudit() {
        guard !isRunningAudit else { return }
        isRunningAudit = true
        auditMessage = String(localized: "Running supply-chain audit…")
        Task.detached { [fileService] in
            let result = await OffPool.run {
                fileService.runHermesCLI(args: Self.auditArgs, timeout: 180)
            }
            await MainActor.run {
                self.isRunningAudit = false
                let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                switch HermesSecurityAuditVerdict(exitCode: result.exitCode) {
                case .clean:
                    // Exit 0 means "nothing at or above --fail-on", and the
                    // threshold is `critical` — so this arm also covers a
                    // report that IS listing high/moderate/low advisories
                    // (`int(any(severity >= threshold))`, security_audit.py
                    // :311-312). Printing its tail with no label told the user
                    // their environment was clean while the text above said
                    // otherwise. `_render_human`'s two heads (:255, :257) and
                    // its `  {severity}  {name}=={version}  {osv-id}` rows
                    // (:264) are what distinguish them, byte-identical back to
                    // **v2026.5.28** — the `hasHermesAudit` FLOOR tag
                    // (0.15.0), whose `security_audit.py` blob is
                    // byte-identical to the v2026.5.29 (0.15.1) one this
                    // comment used to cite (charter C1).
                    let report = HermesSecurityAuditReport.parse(result.output)
                    if report.findingCount > 0 {
                        let summary = report.severitySummary
                        self.auditMessage = summary.isEmpty
                            ? String(localized: "No critical advisories · \(report.findingCount) lower-severity finding(s).")
                            : String(localized: "No critical advisories · \(report.findingCount) finding(s): \(summary).")
                    } else {
                        // Prefer a concise tail of the output (the summary
                        // line) over the full report — the panel-less inline
                        // strip is short.
                        let tail = trimmed.split(separator: "\n").suffix(2).joined(separator: " · ")
                        self.auditMessage = tail.isEmpty ? String(localized: "No known advisories found.") : tail
                    }
                case .findings:
                    // The report IS the answer here; `_render_human` leads with
                    // `Found N known vulnerability finding(s) across M
                    // component(s):` (security_audit.py:257) and the highest
                    // severities sort first (:247-249), so show the head.
                    let head = trimmed.split(separator: "\n").prefix(4).joined(separator: " · ")
                    self.auditMessage = head.isEmpty
                        ? String(localized: "Advisories found.")
                        : String(localized: "Advisories found. \(head)")
                case .failed(let code):
                    let tail = trimmed.split(separator: "\n").suffix(4).joined(separator: " · ")
                    self.auditMessage = String(localized: "Audit failed (exit \(code)). \(tail)")
                }
            }
        }
    }

    /// Run `hermes sessions optimize` (v0.16) off MainActor. Compacts the FTS
    /// index and VACUUMs the sessions database. Non-destructive maintenance verb.
    /// On success we surface a one-line summary; on failure we surface the tail
    /// of stderr so the user can see what tripped without leaving the view.
    func runSessionsOptimize() {
        guard !isRunningSessionsOptimize else { return }
        isRunningSessionsOptimize = true
        sessionsOptimizeMessage = String(localized: "Optimizing sessions database…")
        Task.detached { [fileService] in
            let result = await OffPool.run {
                fileService.runHermesCLI(
                    args: HermesSessionsOptimizeVerdict.argv, timeout: 120
                )
            }
            await MainActor.run {
                self.isRunningSessionsOptimize = false
                let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                // P47: judged by OUTPUT. `_cmd_optimize` catches every
                // exception from `db.vacuum()`, prints
                // `Error: optimization failed: {e}` and RETURNS — exit 0
                // (`hermes_cli/sessions_cmd.py:809-819` @ `v2026.9.7`) — so
                // the pane rendered a failed VACUUM as its summary. The
                // success line is `Optimized {n} FTS index(es).` (`:817`).
                let outcome = HermesSessionsOptimizeVerdict.judge(
                    output: result.output, exitCode: result.exitCode
                )
                self.sessionsOptimizeMessage = Self.sessionsOptimizeSummary(
                    outcome: outcome, exitCode: result.exitCode, trimmed: trimmed
                )
            }
        }
    }

    /// The one place the `sessions optimize` strip's text is decided, lifted
    /// out of the detached hop so it can be exercised without a live host.
    ///
    /// Three answers, not two — the verdict has three states (P47b review,
    /// finding 1). A `.unconfirmed` run is exit 0 with neither
    /// `Optimized {n} FTS index(es).` (`hermes_cli/sessions_cmd.py:817` @
    /// `v2026.9.7`) nor `Error: optimization failed:` (`:815`): the verdict
    /// has just declared the status meaningless, so naming it would be the
    /// original bug in a new voice, and where the run printed nothing at all
    /// `"Optimize failed. "` with an empty tail said less than nothing. It
    /// says Hermes printed no result instead — the same sentence both
    /// memory-reset sites give (`MemoryView`, iOS `MemoryListView`).
    static func sessionsOptimizeSummary(
        outcome: HermesCLIOutcome, exitCode: Int32, trimmed: String
    ) -> String {
        if outcome.succeeded {
            // Prefer a concise tail of the output (the summary line)
            // over the full report — the panel-less inline strip is short.
            let tail = trimmed.split(separator: "\n").suffix(2).joined(separator: " · ")
            return tail.isEmpty ? String(localized: "Sessions database optimized.") : tail
        }
        if exitCode != 0 {
            let tail = trimmed.split(separator: "\n").suffix(4).joined(separator: " · ")
            return String(localized: "Optimize failed (exit \(exitCode)). \(tail)")
        }
        // Exit 0 and no success line: quoting "(exit 0)" here would be the
        // old bug in a new voice. A `.failed` verdict at exit 0 matched
        // `Error: optimization failed:` — Hermes's own reason line is the
        // whole message. `.unconfirmed` matched neither marker, so there is
        // no failure to report and nothing recognisable to quote.
        guard outcome.confidence != .unconfirmed, let detail = outcome.detail, !detail.isEmpty else {
            return String(localized: "hermes sessions optimize printed no result. Check the host.")
        }
        return String(localized: "Optimize failed. \(detail)")
    }

    /// Run `hermes migrate xai --apply` (v0.15) off MainActor to move a retired
    /// xAI model selection onto its successor. `--apply` is REQUIRED — bare
    /// `migrate xai` is dry-run only (prints the plan, writes nothing), so
    /// without it the rewrite never lands while we'd still report success.
    /// Hermes writes a timestamped config.yaml backup before rewriting. After
    /// completion we re-read config via `loadConfig()` so the retired-model
    /// warning clears when the model flips. Errors surface inline.
    func migrateXAI() {
        guard !isMigratingXAI else { return }
        isMigratingXAI = true
        migrateXAIMessage = String(localized: "Migrating xAI model…")
        Task.detached { [fileService] in
            let result = await OffPool.run {
                fileService.runHermesCLI(args: ["migrate", "xai", "--apply"], timeout: 120)
            }
            let config = fileService.loadConfig()
            await MainActor.run {
                self.isMigratingXAI = false
                self.configuredModel = config.model
                self.configuredProvider = config.provider
                let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.exitCode == 0 {
                    self.migrateXAIMessage = Self.migrateXAISummary(
                        output: trimmed, model: config.model
                    )
                } else {
                    let tail = trimmed.split(separator: "\n").suffix(3).joined(separator: " · ")
                    self.migrateXAIMessage = String(localized: "Migration failed (exit \(result.exitCode)). \(tail)")
                }
            }
        }
    }

    /// The strip text for an exit-0 `hermes migrate xai --apply`.
    ///
    /// P54, round-6. `_cmd_xai` has **two different** exit-0 arms and the old
    /// substring test (`"no changes"`) folded them into one sentence:
    ///
    /// - `✓ No retired xAI models in config — nothing to migrate.`
    ///   (`hermes_cli/migrate.py:44` @ `v2026.9.7`, `return 0` at `:45`).
    ///   Nothing to do, and nothing wrong.
    /// - `⚠ No changes written.` (`:74`, `return 0` at `:75`). Reached ONLY
    ///   after `find_retired_xai_refs` found references (`:43` returned
    ///   early otherwise) and `apply_migration` came back with
    ///   `config_changed == False` — the rewrite was attempted against a
    ///   config that still holds retired models and did not land. The user
    ///   was told "No retired xAI model to migrate.", which is the opposite
    ///   of what happened, and the Health warning they clicked the button to
    ///   clear stays up with no explanation.
    ///
    /// Copy only — the verb is already output-judged, and both arms are
    /// genuinely exit 0. Matched on the glyph-stripped, trimmed line so
    /// `rich`'s colour and the two-space indent do not matter; the two heads
    /// are distinct prefixes, so neither can match the other.
    ///
    /// Tag walk: both lines opened at `v2026.6.19` (`:50`, `:94`),
    /// `v2026.7.30` (`:50`, `:94`), `v2026.8.19` (`:50`, `:94`) and
    /// `v2026.9.7` (`:44`, `:74`) — byte-identical at all four; only the
    /// line numbers moved.
    nonisolated static func migrateXAISummary(output: String, model: String) -> String {
        let lines = HermesCLIVerdict.significantLines(output)
        func head(_ line: String) -> String { HermesCLIVerdict.unglyphed(line) }
        if lines.contains(where: { head($0).hasPrefix("No retired xAI models in config") }) {
            return String(localized: "No retired xAI model to migrate.")
        }
        if lines.contains(where: { head($0).hasPrefix("No changes written.") }) {
            return String(localized: """
                Hermes found retired xAI models but wrote no changes. \
                The config still names them — check it by hand.
                """)
        }
        return String(localized: "Migrated to \(model). You may need to restart the gateway.")
    }

    // MARK: - Version probe (capability-gated argv, Hermes v0.20.5)
    //
    // At v0.20.5 the bare `hermes version` subcommand was removed
    // (`hasVersionFlagFullOutput`, see `HermesCapabilities`): an unknown
    // token falls through to plugin discovery and spawns a chat-agent turn
    // instead of printing a version line. `hermes --version` on v0.20.5+
    // now carries the full banner including the "Update available…" (or
    // "Up to date") line `load()`'s update-status parsing
    // greps for; below v0.20.5, `--version` prints only the short banner
    // ("Run 'hermes version' for update status") and the update-status line
    // is only obtainable via the bare `version` subcommand.
    //
    // Bootstrap problem: Health may run before anything has ever probed
    // this host's capabilities, so we can't simply read
    // `HermesCapabilitiesStore` and branch. Strategy:
    //
    //   1. Check `HermesVersionCache`'s in-process cache (no subprocess) —
    //      if another probe (a capabilities store, a template install, a
    //      fleet apply) already answered for this host, trust it and pick
    //      argv directly. This is the common case: by the time Health
    //      loads, the window's own `HermesCapabilitiesStore` has usually
    //      already probed.
    //   2. Otherwise, probe with `--version` first — this is safe on EVERY
    //      Hermes version, old or new, because `--version` has always been
    //      a real flag and never falls through to a chat prompt.
    //   3. Only fall back to the bare `version` subcommand when the
    //      `--version` output lacks the update-status ("Update available…"
    //      or "Up to date") section AND the version line we *did* parse out of it is below
    //      0.20.5 (or unparseable, i.e. we can't confirm the host is new
    //      enough to trust `--version` alone). If `--version` already
    //      yielded a parseable version >= 0.20.5, we never issue bare
    //      `version` — that host doesn't have it.
    nonisolated static func probeVersion(
        _ context: ServerContext,
        cache: HermesVersionCache = .shared,
        run: @Sendable (ServerContext, [String]) -> String = { $0.runHermes($1).output }
    ) -> String {
        if let known = cache.cached(for: context), known.detected {
            let args = versionProbeArguments(for: known)
            let output = run(context, args)
            // Self-correct a stale warm cache: `HermesVersionCache` is
            // trusted for up to 10 minutes (its TTL), and a user can very
            // plausibly run `hermes update` from 0.20.4 to 0.20.5 with
            // Scarf still open during that window. If the cache said
            // "pre-0.20.5" and we issued bare `version`, but the host is
            // now actually 0.20.5+, `version` has been removed there and
            // falls through to plugin discovery — the output won't contain
            // a parseable "Hermes Agent vX.Y.Z" line (it's a chat/plugin
            // response, not a version banner). Detect that and retry with
            // `--version`, which is safe on every version, to recover.
            // The opposite staleness (cache says new, host was actually
            // downgraded) needs no correction: `--version` works everywhere.
            if args == ["version"], HermesCapabilities.parse(output).semver == nil {
                return run(context, ["--version"])
            }
            return output
        }

        let flagOutput = run(context, ["--version"])
        guard shouldFallBackToBareVersionSubcommand(output: flagOutput) else {
            return flagOutput
        }
        return run(context, ["version"])
    }

    /// Argv to use once the host's capabilities are already known.
    nonisolated static func versionProbeArguments(for capabilities: HermesCapabilities) -> [String] {
        capabilities.hasVersionFlagFullOutput ? ["--version"] : ["version"]
    }

    /// Parsed result of a `--version` / `version` update-status check.
    nonisolated struct UpdateStatus: Equatable {
        /// The raw "Update available…" line, trimmed. Empty when no update.
        let updateInfo: String
        var hasUpdate: Bool { !updateInfo.isEmpty }
        /// True when the check couldn't determine currentness at all — no
        /// "Update available…" line AND no "Up to date" line (offline / a
        /// failed `git fetch`; see `parseUpdateStatus(lines:)`).
        let unknown: Bool
        /// True when *either* a positive or negative update-status line is
        /// present — i.e. the output can be trusted as a full "carries the
        /// update section" banner rather than the old short banner.
        var hasUpdateStatusSection: Bool { hasUpdate || !unknown }
    }

    /// Shared update-status parse for `load()` and for
    /// `shouldFallBackToBareVersionSubcommand`'s "does this output already
    /// carry the section" check.
    ///
    /// Hermes prints exactly one of three "Update available" shapes
    /// (`_startup_fast.py:238-249`): plural "N commits behind", singular "1
    /// commit behind", or a count-less "Update available — run '…'" when
    /// the stale local ref only proves *some* update exists. Matching the
    /// "Update available" prefix (rather than "commits behind") catches all
    /// three; the old substring match missed the singular and count-less
    /// forms entirely.
    ///
    /// When the update check can't reach `origin` at all (offline / fetch
    /// timeout), `banner.py`'s `check_for_updates()` returns `None` and
    /// `_startup_fast.py` prints *neither* an "Update available…" line nor
    /// "Up to date" (banner.py:344-380, the `if not fetch_ok: … return None`
    /// path). That's a genuinely different state from "confirmed current"
    /// and must not collapse into it.
    nonisolated static func parseUpdateStatus(lines: [String]) -> UpdateStatus {
        if let updateLine = lines.first(where: { $0.hasPrefix("Update available") }) {
            return UpdateStatus(updateInfo: updateLine.trimmingCharacters(in: .whitespaces), unknown: false)
        }
        let confirmedUpToDate = lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Up to date" })
        return UpdateStatus(updateInfo: "", unknown: !confirmedUpToDate)
    }

    /// True when `hermes --version` output needs the bare `version`
    /// fallback to get the update-status section: the output doesn't
    /// already carry one (an "Update available…" line in any of its three
    /// shapes, or an explicit "Up to date"), and the version we can parse
    /// out of it (if any) is below the 0.20.5 floor where `--version`
    /// gained that section. Unparseable output (no recognizable "Hermes
    /// Agent vX.Y.Z" line) is treated the same as "below 0.20.5" — we can't
    /// confirm the host is new enough to trust `--version` alone, so we
    /// fall back.
    nonisolated static func shouldFallBackToBareVersionSubcommand(output: String) -> Bool {
        guard !parseUpdateStatus(lines: output.components(separatedBy: "\n")).hasUpdateStatusSection else {
            return false
        }
        guard let semver = HermesCapabilities.parse(output).semver else { return true }
        return semver < HermesCapabilities.SemVer(major: 0, minor: 20, patch: 5)
    }

    // MARK: - Web Dashboard (`hermes dashboard`)

    /// Called from `HealthView.onAppear`. Starts a background loop that
    /// probes `http://127.0.0.1:<port>/api/status` every 3s and keeps
    /// `dashboardStatus.running` in sync with reality — whether we launched
    /// the dashboard or the user did via terminal. No-op on remote contexts.
    func startDashboardMonitoring() {
        guard !context.isRemote else { return }
        dashboardProbeTask?.cancel()
        let port = dashboardStatus.port
        dashboardProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                let running = await Self.probeDashboard(port: port)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Preserve `busy` so the button stays disabled during an
                    // in-flight start/stop; only toggle the `running` bit.
                    self.dashboardStatus = WebDashboardStatus(
                        running: running,
                        port: self.dashboardStatus.port,
                        busy: self.dashboardStatus.busy
                    )
                    // Reap our spawned process if it exited externally.
                    if !running, let p = self.dashboardProcess, !p.isRunning {
                        self.dashboardProcess = nil
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopDashboardMonitoring() {
        dashboardProbeTask?.cancel()
        dashboardProbeTask = nil
    }

    /// Launch `hermes dashboard --no-open --port 9119` detached. We pass
    /// `--no-open` so Hermes doesn't try to open its own browser tab — Scarf
    /// opens the URL after the probe confirms the server is listening, which
    /// avoids the "Safari tab loads faster than uvicorn binds the port" race.
    func launchDashboard() {
        guard !context.isRemote else { return }
        guard !dashboardStatus.running, !dashboardStatus.busy else { return }
        guard let binary = fileService.hermesBinaryPath() else {
            actionMessage = "hermes binary not found"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.actionMessage = nil
            }
            return
        }

        dashboardStatus = WebDashboardStatus(
            running: dashboardStatus.running,
            port: dashboardStatus.port,
            busy: true
        )
        actionMessage = "Starting dashboard…"

        let port = dashboardStatus.port
        // No timeout on THIS process, deliberately: it is the dashboard
        // server, meant to outlive the click. C10's "every subprocess has a
        // timeout" is about waits — nothing here waits on it; liveness comes
        // from the HTTP probe below and the stop path signals it by PID.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["dashboard", "--no-open", "--port", String(port)]
        // Discard stdout/stderr — we rely on the HTTP probe for liveness and
        // don't want a growing pipe buffer to block the subprocess.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        // C10: `Process.run()` is fork/exec plus PATH and bundle resolution —
        // it can block for tens of milliseconds, and on a wedged filesystem
        // far longer. Spawn off the main actor and come back with either the
        // live process or the error; everything that touches view state stays
        // on MainActor.
        Task { [weak self] in
            // C10 (round-6 P58): the environment is resolved off the pool
            // too, not just the spawn. `enrichedEnvironment()` reads a
            // `static let` whose initialiser is two `zsh` probes at 5 s + 3 s
            // behind a `swift_once`, so setting it on the main actor froze
            // the window for up to eight seconds on the Start click — the
            // spawn below had been moved off and the line feeding it had not.
            proc.environment = await OffPool.run { HermesFileService.enrichedEnvironment() }
            // `OffPool.run`, not `Task.detached`: `run()` blocks on the
            // fork/exec (and on `ssh` for a remote context), and a blocking
            // call on the cooperative pool is the shape the P52 sweep exists
            // to catch. P58 moved `HermesProxyService`'s identical spawn and
            // left these three on the pool — round-6 lesson 3, the siblings.
            let spawnError: (any Error)? = await OffPool.run {
                do { try proc.run(); return nil } catch { return error }
            }
            guard let self else { return }
            if let spawnError {
                Self.dashboardLogger.error("Failed to spawn hermes dashboard: \(spawnError.localizedDescription, privacy: .public)")
                self.dashboardProcess = nil
                self.dashboardStatus = WebDashboardStatus(
                    running: self.dashboardStatus.running,
                    port: self.dashboardStatus.port,
                    busy: false
                )
                self.actionMessage = "Failed to start: \(spawnError.localizedDescription)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.actionMessage = nil
                }
                return
            }
            self.dashboardProcess = proc
            // Give uvicorn up to ~6 seconds to bind the port, probing every
            // 300ms. First 200 response opens the browser.
            for _ in 0..<20 {
                if await Self.probeDashboard(port: port) {
                    if let url = URL(string: "http://127.0.0.1:\(port)") {
                        _ = NSWorkspace.shared.open(url)
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self.dashboardStatus = WebDashboardStatus(
                running: self.dashboardStatus.running,
                port: self.dashboardStatus.port,
                busy: false
            )
            self.actionMessage = nil
        }
    }

    /// Stop the dashboard. If Scarf spawned it, send SIGTERM directly. If an
    /// external instance is running, find the PID listening on the dashboard
    /// port via `lsof` and signal that one process — never broadcast a
    /// `pkill -f "hermes dashboard"` that could match shell history, log
    /// tails, or any unrelated argv containing the substring.
    func stopDashboard() {
        guard !context.isRemote else { return }
        dashboardStatus = WebDashboardStatus(
            running: dashboardStatus.running,
            port: dashboardStatus.port,
            busy: true
        )
        actionMessage = "Stopping dashboard…"

        let port = dashboardStatus.port
        let owned = dashboardProcess
        let terminateOwned = owned?.isRunning == true
        if terminateOwned { dashboardProcess = nil }

        // The dashboard is a DAEMON: nothing waits on it, so the only budget
        // it can be given is on the way OUT. A bare `terminate()` was the
        // whole of this — no escalation and no ceiling — so a uvicorn that
        // ignores SIGTERM, or is wedged in an uninterruptible wait, left the
        // Stop button looking like it had worked while the child ran on,
        // holding the port against the next Start. Exactly the shape round-5
        // P48 fixed in `HermesProxyService.stop()`, and this is that sibling,
        // spelled the same way it is there:
        //
        // SIGTERM goes FIRST, here, before the wait. `waitUntilExit(timeout:)`
        // signals only once its budget is SPENT, so handing it the ceiling and
        // nothing else would poll a child nobody had asked to leave. The ask
        // is free and immediate; the ceiling is the grace AFTER it.
        //
        // A THREAD, and NOT inside the `Task` below: the primitive is a
        // `Thread.sleep` poll loop, and a `Task`/`Task.detached` closure is
        // the cooperative pool — one thread per core, unable to grow. That is
        // what `ProcessAsyncWaitP43cTests` proves, and it caught this
        // arrangement when the escalation was nested in the Task.
        if terminateOwned, let owned {
            let ceiling = Self.dashboardStopCeiling
            owned.terminate()
            Thread.detachNewThread {
                _ = owned.waitUntilExit(timeout: ceiling)
            }
        }

        // C10: the `lsof` probe is process work too — a whole spawn whose
        // `waitUntilExit()` had no timeout, so a hung lsof froze the window.
        // Off the main actor, then hop back.
        Task { [weak self] in
            // Owned children were already signalled and escalated above, off
            // the pool; only the EXTERNAL case has work left here.
            if !terminateOwned, let pid = await Self.dashboardListenerPID(port: port) {
                // Signal only the process actually bound to our dashboard
                // port, not anything that happens to mention
                // "hermes dashboard" in its argv.
                _ = Darwin.kill(pid, SIGTERM)
            }
            // Same settle delay as before, now a suspension rather than a
            // main-queue timer.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let running = await Self.probeDashboard(port: port)
            guard let self else { return }
            self.dashboardStatus = WebDashboardStatus(
                running: running,
                port: port,
                busy: false
            )
            self.actionMessage = nil
        }
    }

    /// How long to let `hermes dashboard` shut down cleanly before SIGKILL.
    /// Matched to ``HermesProxyService/stopCeiling``: both are HTTP servers
    /// with nothing to flush, and the row's own settle-and-probe below
    /// already waits 1.2 s before it reports, so a longer ceiling would only
    /// let the status line lie for longer.
    nonisolated static let dashboardStopCeiling: TimeInterval = 3

    /// Resolve the PID currently listening on the dashboard port via
    /// `lsof -tiTCP:<port> -sTCP:LISTEN`. Returns nil when nothing is
    /// bound or lsof fails. Trusting the port is correct here: Scarf
    /// owns the configured port, and stopping the listener is exactly
    /// the user-visible "Stop Dashboard" intent. We deliberately skip
    /// `lsof -c hermes` — Hermes installs as a Python shebang script,
    /// so the process COMM is `python` / `python3` and a `-c hermes`
    /// filter silently misses every standard install.
    private static let lsofTimeout: TimeInterval = 3

    /// `nonisolated`: the only caller is inside `Task.detached` (see
    /// `stopDashboard`), so this must not be main-actor work — and now that the
    /// body is four lines there is nothing left to justify an isolation hop.
    private nonisolated static func dashboardListenerPID(port: Int) async -> pid_t? {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]

        let output = Pipe()
        lsof.standardOutput = output
        lsof.standardError = FileHandle.nullDevice

        do {
            try lsof.run()
            // `Process.waitDraining` WAS hoisted out of this function in P33
            // and this copy was left behind: bounded wait, concurrent drain,
            // bounded drain grace — plus the read-end close this version never
            // did. An overrun is reported as "no listener", the same answer a
            // failed lsof has always given.
            let (exited, data) = await lsof.waitDrainingAsync(
                timeout: Self.lsofTimeout, pipes: [output])
            guard exited else {
                Self.dashboardLogger.warning("lsof timed out locating the dashboard listener")
                return nil
            }
            // lsof exits 1 when nothing matches — that's "no listener",
            // not an error. Anything else is something we can't recover
            // from in this code path; log and bail.
            guard lsof.terminationStatus == 0 else { return nil }
            let text = String(data: data[0], encoding: .utf8) ?? ""
            return text
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                .first
        } catch {
            Self.dashboardLogger.warning(
                "Failed to locate dashboard listener: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Open the dashboard in the default browser. Safe to call only when the
    /// probe reports `running: true` — UI gates the button on that.
    func openDashboardInBrowser() {
        guard let url = URL(string: "http://127.0.0.1:\(dashboardStatus.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// HEAD-shaped GET against `/api/status`. Returns true on any 2xx response.
    /// `/api/status` is whitelisted in `_PUBLIC_API_PATHS` in Hermes's
    /// `web_server.py` — no token required, so a bare GET works.
    ///
    /// `nonisolated` + `async` so the polling loop can call it without
    /// bouncing through MainActor on every tick.
    nonisolated private static func probeDashboard(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 1.0
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    nonisolated private static let dashboardLogger = Logger(subsystem: "com.scarf", category: "WebDashboard")
}
