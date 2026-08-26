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

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
        self.subscriptionService = NousSubscriptionService(context: context)
    }


    var version = ""
    var updateInfo = ""
    var hasUpdate = false
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

    // MARK: - Supply-chain audit (`hermes audit`, v0.15)

    /// True while `hermes audit` is shelling out so the header button can show
    /// a spinner. The OSV.dev lookup is a network round-trip — easily a couple
    /// seconds — so this runs off MainActor and never blocks the UI.
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
        // Health runs four sync transport-mediated commands plus a process
        // probe — that's 4-5 ssh round-trips on remote, easily 1-2s. Detach
        // the whole load, store the handle, and bail between round-trips if
        // the user navigates away (cancelLoad()).
        loadTask?.cancel()
        loadTask = Task.detached { [weak self] in
            let pid = svc.hermesPID()
            if Task.isCancelled { return }
            let versionOutput = Self.probeVersion(ctx)
            if Task.isCancelled { return }
            let statusOutput = ctx.runHermes(["status"]).output
            if Task.isCancelled { return }
            let doctorOutput = ctx.runHermes(["doctor"]).output
            if Task.isCancelled { return }
            let subscription = subSvc.loadState()
            let config = svc.loadConfig()
            if Task.isCancelled { return }

            let lines = versionOutput.components(separatedBy: "\n")
            let version = lines.first ?? ""
            let updateLine = lines.first(where: { $0.contains("commits behind") })
            let hasUpdate = updateLine != nil
            let updateInfo = updateLine?.trimmingCharacters(in: .whitespaces) ?? ""

            let statusSections = Self.parseOutputStatic(statusOutput)
                + [Self.toolGatewaySection(subscription: subscription, config: config)]
            let doctorSections = Self.parseOutputStatic(doctorOutput)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hermesPID = pid
                self.hermesRunning = pid != nil
                self.version = version
                self.updateInfo = updateInfo
                self.hasUpdate = hasUpdate
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
    nonisolated private static func toolGatewaySection(subscription: NousSubscriptionState, config: HermesConfig) -> HealthSection {
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

        let auxOnNous = [
            ("vision", config.auxiliary.vision.provider),
            ("web_extract", config.auxiliary.webExtract.provider),
            ("compression", config.auxiliary.compression.provider),
            ("session_search", config.auxiliary.sessionSearch.provider),
            ("skills_hub", config.auxiliary.skillsHub.provider),
            ("approval", config.auxiliary.approval.provider),
            ("mcp", config.auxiliary.mcp.provider),
            ("curator", config.auxiliary.curator.provider),
        ].filter { $0.1 == "nous" }.map(\.0)
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

    private static func recordControlAction(_ action: UsageEvent.ControlAction, succeeded: Bool) {
        Analytics.record(.hermesControlAction(
            action: action, source: .healthPanel, outcome: .init(succeeded: succeeded)
        ))
    }

    func stopHermes() {
        let stopped = fileService.stopHermes()
        Self.recordControlAction(.stop, succeeded: stopped)
        actionMessage = "Stop signal sent"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshProcessStatus()
            self?.actionMessage = nil
        }
    }

    func startHermes() {
        let started = runHermes(["gateway", "start"]).exitCode == 0
        Self.recordControlAction(.start, succeeded: started)
        actionMessage = "Start requested"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshProcessStatus()
            self?.actionMessage = nil
        }
    }

    func restartHermes() {
        let stopped = fileService.stopHermes()
        actionMessage = "Restarting..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let started = self.runHermes(["gateway", "start"]).exitCode == 0
            // A restart only succeeded if both halves did; a stop that found
            // nothing running still has to bring the gateway back.
            Self.recordControlAction(.restart, succeeded: stopped && started)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.refreshProcessStatus()
                self?.actionMessage = nil
            }
        }
    }

    private func loadVersion() {
        let output = Self.probeVersion(context)
        let lines = output.components(separatedBy: "\n")
        version = lines.first ?? ""
        if let updateLine = lines.first(where: { $0.contains("commits behind") }) {
            updateInfo = updateLine.trimmingCharacters(in: .whitespaces)
            hasUpdate = true
        } else {
            updateInfo = ""
            hasUpdate = false
        }
    }

    /// Static-callable form for the detached load() task. The instance
    /// `parseOutput` below delegates here so existing call sites still work.
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

    private func parseOutput(_ output: String) -> [HealthSection] {
        var sections: [HealthSection] = []
        var currentTitle = ""
        var currentChecks: [HealthCheck] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("◆ ") {
                if !currentTitle.isEmpty {
                    sections.append(HealthSection(
                        title: currentTitle,
                        icon: iconForSection(currentTitle),
                        checks: currentChecks
                    ))
                }
                currentTitle = String(trimmed.dropFirst(2))
                currentChecks = []
                continue
            }

            if trimmed.hasPrefix("✓ ") {
                let text = String(trimmed.dropFirst(2))
                let (label, detail) = splitCheck(text)
                currentChecks.append(HealthCheck(label: label, status: .ok, detail: detail))
            } else if trimmed.hasPrefix("⚠ ") || trimmed.hasPrefix("⚠") {
                let text = trimmed.replacingOccurrences(of: "⚠ ", with: "").replacingOccurrences(of: "⚠", with: "")
                let (label, detail) = splitCheck(text)
                currentChecks.append(HealthCheck(label: label, status: .warning, detail: detail))
            } else if trimmed.hasPrefix("✗ ") {
                let text = String(trimmed.dropFirst(2))
                let (label, detail) = splitCheck(text)
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
                icon: iconForSection(currentTitle),
                checks: currentChecks
            ))
        }

        return sections
    }

    private func splitCheck(_ text: String) -> (String, String?) {
        if let parenStart = text.firstIndex(of: "(") {
            let label = text[text.startIndex..<parenStart].trimmingCharacters(in: .whitespaces)
            let detail = String(text[parenStart...]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            return (label, detail)
        }
        return (text, nil)
    }

    private func computeCounts() {
        let allChecks = (statusSections + doctorSections).flatMap(\.checks)
        okCount = allChecks.filter { $0.status == .ok }.count
        warningCount = allChecks.filter { $0.status == .warning }.count
        issueCount = allChecks.filter { $0.status == .error }.count
    }

    private func iconForSection(_ title: String) -> String {
        switch title {
        case "Environment": return "gearshape.2"
        case "API Keys": return "key"
        case "Auth Providers": return "person.badge.key"
        case "API-Key Providers": return "key.horizontal"
        case "Terminal Backend": return "terminal"
        case "Messaging Platforms": return "bubble.left.and.bubble.right"
        case "Gateway Service": return "antenna.radiowaves.left.and.right"
        case "Scheduled Jobs": return "clock.arrow.2.circlepath"
        case "Sessions": return "text.bubble"
        case "Python Environment": return "chevron.left.forwardslash.chevron.right"
        case "Required Packages": return "shippingbox"
        case "Configuration Files": return "doc.text"
        case "Directory Structure": return "folder"
        case "External Tools": return "wrench"
        case "API Connectivity": return "wifi"
        case "Submodules": return "arrow.triangle.branch"
        case "Tool Availability": return "wrench.and.screwdriver"
        case "Skills Hub": return "lightbulb"
        case "Honcho Memory": return "brain"
        default: return "circle"
        }
    }

    /// Capture `hermes dump` output — a setup summary used for debugging / support.
    /// Does NOT upload anything.
    func runDump() {
        actionMessage = "Running dump…"
        let result = runHermes(["dump"])
        diagnosticsOutput = result.output
        actionMessage = result.exitCode == 0 ? "Dump captured" : "Dump failed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.actionMessage = nil
        }
    }

    /// Upload a debug report via `hermes debug share`. THIS UPLOADS DATA to Nous
    /// Research support infrastructure — caller must confirm with the user first.
    func runDebugShare() {
        isSharingDebug = true
        actionMessage = "Uploading debug report…"
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: ["debug", "share"], timeout: 120)
            await MainActor.run {
                self.isSharingDebug = false
                self.diagnosticsOutput = result.output
                self.actionMessage = result.exitCode == 0 ? "Upload complete" : "Upload failed"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.actionMessage = nil
                }
            }
        }
    }

    /// Run `hermes security audit` (v0.15 OSV.dev supply-chain scan) off
    /// MainActor. NB the verb is `security audit`; bare `hermes audit` is not a
    /// CLI verb and routes to an agent chat turn instead of running the scan.
    /// Non-destructive read-only verb. On success we surface a one-line summary;
    /// on failure we surface the tail of the advisory list / stderr so the user
    /// can see which packages tripped the scan without leaving the view.
    func runAudit() {
        guard !isRunningAudit else { return }
        isRunningAudit = true
        auditMessage = "Running supply-chain audit…"
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["security", "audit"], timeout: 180)
            await MainActor.run {
                self.isRunningAudit = false
                let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.exitCode == 0 {
                    // Prefer a concise tail of the output (the summary line)
                    // over the full report — the panel-less inline strip is short.
                    let tail = trimmed.split(separator: "\n").suffix(2).joined(separator: " · ")
                    self.auditMessage = tail.isEmpty ? "No known advisories found." : tail
                } else {
                    let tail = trimmed.split(separator: "\n").suffix(4).joined(separator: " · ")
                    self.auditMessage = "Audit failed (exit \(result.exitCode)). \(tail)"
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
        sessionsOptimizeMessage = "Optimizing sessions database…"
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["sessions", "optimize"], timeout: 120)
            await MainActor.run {
                self.isRunningSessionsOptimize = false
                let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.exitCode == 0 {
                    // Prefer a concise tail of the output (the summary line)
                    // over the full report — the panel-less inline strip is short.
                    let tail = trimmed.split(separator: "\n").suffix(2).joined(separator: " · ")
                    self.sessionsOptimizeMessage = tail.isEmpty ? "Sessions database optimized." : tail
                } else {
                    let tail = trimmed.split(separator: "\n").suffix(4).joined(separator: " · ")
                    self.sessionsOptimizeMessage = "Optimize failed (exit \(result.exitCode)). \(tail)"
                }
            }
        }
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
        migrateXAIMessage = "Migrating xAI model…"
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["migrate", "xai", "--apply"], timeout: 120)
            let config = fileService.loadConfig()
            await MainActor.run {
                self.isMigratingXAI = false
                self.configuredModel = config.model
                self.configuredProvider = config.provider
                let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.exitCode == 0 {
                    // `migrate xai --apply` exits 0 even when there's nothing to
                    // migrate / no changes were written — don't claim success.
                    let lower = trimmed.lowercased()
                    if lower.contains("nothing to migrate") || lower.contains("no changes") {
                        self.migrateXAIMessage = "No retired xAI model to migrate."
                    } else {
                        self.migrateXAIMessage = "Migrated to \(config.model). You may need to restart the gateway."
                    }
                } else {
                    let tail = trimmed.split(separator: "\n").suffix(3).joined(separator: " · ")
                    self.migrateXAIMessage = "Migration failed (exit \(result.exitCode)). \(tail)"
                }
            }
        }
    }

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }

    // MARK: - Version probe (capability-gated argv, Hermes v0.20.5)
    //
    // At v0.20.5 the bare `hermes version` subcommand was removed
    // (`hasVersionFlagFullOutput`, see `HermesCapabilities`): an unknown
    // token falls through to plugin discovery and spawns a chat-agent turn
    // instead of printing a version line. `hermes --version` on v0.20.5+
    // now carries the full banner including the "commits behind" update
    // line that :164/:346 grep for; below v0.20.5, `--version` prints only
    // the short banner ("Run 'hermes version' for update status") and the
    // `commits behind` line is only obtainable via the bare `version`
    // subcommand.
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
    //      `--version` output lacks the update-status ("commits behind")
    //      section AND the version line we *did* parse out of it is below
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
            return run(context, args)
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

    /// True when `hermes --version` output needs the bare `version`
    /// fallback to get the update-status ("commits behind") section: the
    /// output doesn't already carry it, and the version we can parse out of
    /// it (if any) is below the 0.20.5 floor where `--version` gained that
    /// section. Unparseable output (no recognizable "Hermes Agent vX.Y.Z"
    /// line) is treated the same as "below 0.20.5" — we can't confirm the
    /// host is new enough to trust `--version` alone, so we fall back.
    nonisolated static func shouldFallBackToBareVersionSubcommand(output: String) -> Bool {
        guard !output.contains("commits behind") else { return false }
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["dashboard", "--no-open", "--port", String(port)]
        proc.environment = HermesFileService.enrichedEnvironment()
        // Discard stdout/stderr — we rely on the HTTP probe for liveness and
        // don't want a growing pipe buffer to block the subprocess.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            dashboardProcess = proc
            Task { [weak self] in
                // Give uvicorn up to ~6 seconds to bind the port, probing
                // every 300ms. First 200 response opens the browser.
                for _ in 0..<20 {
                    if await Self.probeDashboard(port: port) {
                        if let url = URL(string: "http://127.0.0.1:\(port)") {
                            await MainActor.run {
                                _ = NSWorkspace.shared.open(url)
                            }
                        }
                        break
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.dashboardStatus = WebDashboardStatus(
                        running: self.dashboardStatus.running,
                        port: self.dashboardStatus.port,
                        busy: false
                    )
                    self.actionMessage = nil
                }
            }
        } catch {
            Self.dashboardLogger.error("Failed to spawn hermes dashboard: \(error.localizedDescription, privacy: .public)")
            dashboardProcess = nil
            dashboardStatus = WebDashboardStatus(
                running: dashboardStatus.running,
                port: dashboardStatus.port,
                busy: false
            )
            actionMessage = "Failed to start: \(error.localizedDescription)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.actionMessage = nil
            }
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

        if let proc = dashboardProcess, proc.isRunning {
            proc.terminate()
            dashboardProcess = nil
        } else if let pid = Self.dashboardListenerPID(port: dashboardStatus.port) {
            // External instance — signal only the process actually
            // bound to our dashboard port, not anything that happens
            // to mention "hermes dashboard" in its argv.
            _ = Darwin.kill(pid, SIGTERM)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            Task {
                let running = await Self.probeDashboard(port: self.dashboardStatus.port)
                await MainActor.run {
                    self.dashboardStatus = WebDashboardStatus(
                        running: running,
                        port: self.dashboardStatus.port,
                        busy: false
                    )
                    self.actionMessage = nil
                }
            }
        }
    }

    /// Resolve the PID currently listening on the dashboard port via
    /// `lsof -tiTCP:<port> -sTCP:LISTEN`. Returns nil when nothing is
    /// bound or lsof fails. Trusting the port is correct here: Scarf
    /// owns the configured port, and stopping the listener is exactly
    /// the user-visible "Stop Dashboard" intent. We deliberately skip
    /// `lsof -c hermes` — Hermes installs as a Python shebang script,
    /// so the process COMM is `python` / `python3` and a `-c hermes`
    /// filter silently misses every standard install.
    private static func dashboardListenerPID(port: Int) -> pid_t? {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]

        let output = Pipe()
        lsof.standardOutput = output
        lsof.standardError = FileHandle.nullDevice

        do {
            try lsof.run()
            lsof.waitUntilExit()
            // lsof exits 1 when nothing matches — that's "no listener",
            // not an error. Anything else is something we can't recover
            // from in this code path; log and bail.
            guard lsof.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
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
