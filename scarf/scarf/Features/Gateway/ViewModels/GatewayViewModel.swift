import Foundation
import ScarfCore

// **Local rename for v0.13 / WS-5.** The user-facing label is "Messaging
// Gateway"; the type names mirror that. The `SidebarSection.gateway` enum
// case + `gateway_state.json` / `gateway.log` paths intentionally stay
// unchanged — those aren't user-facing strings, and renaming them would
// churn unrelated callers without changing what users see.

struct MessagingGatewayInfo {
    let pid: Int?
    let state: String
    let exitReason: String?
    let startTime: String?
    let updatedAt: String?
    let platforms: [PlatformInfo]
    /// True when `hermes gateway status` shows the gateway is running under a
    /// system service manager (systemd/launchd/Windows Scheduled Task) rather
    /// than as a bare foreground/manual process. Derived by exclusion: the
    /// manual-mode code path (`hermes_cli/gateway.py`'s `status` branch,
    /// present unchanged at v0.20.5 and v0.21.0) is the *only* path that
    /// prints "(Running manually, not as a system service)" — every
    /// service-managed branch (systemd/launchd/Windows) prints something
    /// else entirely, so its absence (while a PID is known) is a reliable
    /// signal. There is no "service is loaded" string anywhere in the CLI;
    /// the previous `contains("service is loaded")` check could never match.
    let isLoaded: Bool
    /// Live liveness verdict, NOT `state == "running"`.
    ///
    /// `gateway_state.json` is written by the gateway itself and nothing
    /// rewrites it on a crash, a `kill -9`, or a failed start — so
    /// `gateway_state` sits at `"running"` indefinitely after the process is
    /// gone, and the green badge cheerfully repeated it. `hermes gateway
    /// status` is the live probe (it derives pids from
    /// `get_gateway_runtime_snapshot()`), so its verdict wins where it has
    /// one; the file's `state` is only the fallback for the service-managed
    /// branches, which print neither marker.
    let isRunning: Bool
}

struct PlatformInfo: Identifiable {
    var id: String { name }
    let name: String
    let state: String
    let updatedAt: String?

    var isConnected: Bool { state == "connected" }

    var icon: String { KnownPlatforms.icon(for: name) }
}

struct PairedUser: Identifiable {
    var id: String { platform + userId }
    let platform: String
    let userId: String
    let name: String
}

struct PendingPairing: Identifiable {
    var id: String { platform + code }
    let platform: String
    let code: String
}

@Observable
@MainActor
final class MessagingGatewayViewModel {
    let context: ServerContext
    /// Capability snapshot at view-init time. Read for the v0.13 cross-
    /// profile digest (`hasGatewayList`); other v0.13 surfaces live on
    /// per-platform setup views. `.empty` is fine outside the per-server
    /// `ContextBoundRoot` (Previews, smoke tests).
    let capabilities: HermesCapabilities

    init(context: ServerContext = .local, capabilities: HermesCapabilities = .empty) {
        self.context = context
        self.capabilities = capabilities
    }

    var gateway = MessagingGatewayInfo(pid: nil, state: "unknown", exitReason: nil, startTime: nil, updatedAt: nil, platforms: [], isLoaded: false, isRunning: false)
    var approvedUsers: [PairedUser] = []
    var pendingPairings: [PendingPairing] = []
    var isLoading = false
    var actionMessage: String?
    /// `hermes gateway list --json` snapshot. `nil` when the verb fails
    /// (pre-v0.13 host or no profiles registered yet) — the digest row
    /// hides itself in that case.
    var gatewayList: GatewayListSnapshot?

    func load() {
        isLoading = true
        let ctx = context
        let caps = capabilities
        Task.detached { [weak self] in
            // Two sync transport calls + two CLI invocations — substantial
            // remote latency. Detach the whole load and commit at the end.
            let status = Self.fetchGatewayStatus(context: ctx)
            let pairing = Self.fetchPairing(context: ctx)
            let listSnap = caps.hasGatewayList
                ? HermesGatewayListService.fetch(context: ctx)
                : nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.gateway = status
                self.approvedUsers = pairing.approved
                self.pendingPairings = pairing.pending
                self.gatewayList = listSnap
                self.isLoading = false
            }
        }
    }

    /// Static form of the gateway-status walk so the detached load can call
    /// it without bouncing back to MainActor.
    nonisolated private static func fetchGatewayStatus(context: ServerContext) -> MessagingGatewayInfo {
        let stateJSON = context.readData(context.paths.gatewayStateJSON)
        var pid: Int?
        var state = "unknown"
        var exitReason: String?
        var startTime: String?
        var updatedAt: String?
        var platforms: [PlatformInfo] = []

        if let data = stateJSON,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pid = json["pid"] as? Int
            state = json["gateway_state"] as? String ?? "unknown"
            exitReason = json["exit_reason"] as? String
            startTime = json["start_time"] as? String
            updatedAt = json["updated_at"] as? String
            if let plats = json["platforms"] as? [String: Any] {
                platforms = plats.compactMap { key, value in
                    guard let info = value as? [String: Any] else { return nil }
                    return PlatformInfo(
                        name: key,
                        state: info["state"] as? String ?? "unknown",
                        updatedAt: info["updated_at"] as? String
                    )
                }.sorted { $0.name < $1.name }
            }
        }

        let statusOutput = context.runHermes(["gateway", "status"]).output
        let isLoaded = isServiceLoaded(pid: pid, statusOutput: statusOutput)

        return MessagingGatewayInfo(
            pid: pid, state: state, exitReason: exitReason,
            startTime: startTime, updatedAt: updatedAt,
            platforms: platforms, isLoaded: isLoaded,
            isRunning: isGatewayRunning(state: state, statusOutput: statusOutput)
        )
    }

    /// Live-probe liveness. `✗ Gateway is not running` and
    /// `✓ Gateway is running (PID: …)` are the two verdicts the manual
    /// branch of `hermes gateway status` prints (`hermes_cli/gateway.py`
    /// lines 8928/8958 at tag `v2026.8.31`); the systemd/launchd/Windows
    /// branches print neither, so there the stored `gateway_state` is all
    /// we have and the old behaviour is kept.
    nonisolated static func isGatewayRunning(state: String, statusOutput: String) -> Bool {
        if statusOutput.contains("✗ Gateway is not running") { return false }
        if statusOutput.contains("✓ Gateway is running") { return true }
        return state == "running"
    }

    /// True when `hermes gateway status` shows the gateway running under a
    /// system service manager rather than as a bare foreground/manual
    /// process. "(Running manually, not as a system service)" only prints
    /// from the manual-mode branch of `hermes gateway status`
    /// (`hermes_cli/gateway.py`'s `status` subcommand, confirmed identical
    /// at v0.20.5 and v0.21.0). Every service-managed branch (systemd /
    /// launchd / Windows Scheduled Task) prints entirely different text and
    /// never this phrase, so a running gateway (a known PID) whose status
    /// output lacks it is service-managed. There's no cross-platform
    /// "stale" signal in this output — launchd's "Service definition is
    /// stale…" and systemd's "…definition is outdated" are two different
    /// strings, neither reachable from the manual branch — so that concept
    /// is dropped rather than faked (see the retired `isStale` field).
    ///
    /// **The `gateway_state.json` pid is not proof of life.** A crash or a
    /// `kill -9` leaves the last-written pid in the file (nothing rewrites
    /// it on an unclean exit), so a pid-only test badges a dead gateway as
    /// "Loaded". `hermes gateway status` is the live probe — it derives
    /// pids from `get_gateway_runtime_snapshot()` — so its verdict wins:
    ///  - `✗ Gateway is not running` (manual branch, gateway.py:8958) →
    ///    never loaded, whatever the stale pid says.
    ///  - `✓ Gateway is running (PID: …)` + `(Running manually, …)` →
    ///    running, but not service-managed.
    ///  - A service-managed branch (systemd/launchd/Windows) prints
    ///    neither marker; there we still need the pid as the liveness
    ///    signal, so the original test applies.
    nonisolated static func isServiceLoaded(pid: Int?, statusOutput: String) -> Bool {
        if statusOutput.contains("✗ Gateway is not running") { return false }
        if statusOutput.contains("(Running manually, not as a system service)") { return false }
        return pid != nil
    }

    nonisolated private static func fetchPairing(context: ServerContext) -> (approved: [PairedUser], pending: [PendingPairing]) {
        let output = context.runHermes(["pairing", "list"]).output
        var approved: [PairedUser] = []
        var pending: [PendingPairing] = []

        var inApproved = false
        var inPending = false

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("Approved Users") { inApproved = true; inPending = false; continue }
            if trimmed.contains("Pending") { inPending = true; inApproved = false; continue }
            if trimmed.isEmpty || trimmed.hasPrefix("Platform") || trimmed.hasPrefix("--------") { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if inApproved && parts.count >= 3 {
                let platform = String(parts[0])
                let userId = String(parts[1])
                let name = parts[2...].joined(separator: " ")
                approved.append(PairedUser(platform: platform, userId: userId, name: name))
            } else if inPending && parts.count >= 2 {
                let platform = String(parts[0])
                let code = String(parts[1])
                pending.append(PendingPairing(platform: platform, code: code))
            }
        }
        return (approved, pending)
    }

    func startGateway() { runServiceAction("start", label: "start", settleSeconds: 2) }

    func stopGateway() { runServiceAction("stop", label: "stop", settleSeconds: 2) }

    func restartGateway() { runServiceAction("restart", label: "restart", settleSeconds: 3) }

    /// Generation token for the deferred settle-and-reload. Every service
    /// action bumps it; the pending block from an earlier action sees a
    /// stale token and does nothing. Without this, clicking Stop within two
    /// seconds of Start let Start's timer clear Stop's message and fire an
    /// extra reload on top of it — and a sticky failure message posted by
    /// the second action was wiped by the first action's timer.
    @ObservationIgnored private var actionGeneration = 0

    /// True while `actionMessage` is reporting a failure — the view paints it
    /// as an error and it is never auto-cleared.
    private(set) var actionFailed = false

    /// One code path for start/stop/restart so the exit code can't be
    /// dropped on one of them. `hermes gateway start` exits 1 on its real
    /// failure paths (`hermes_cli/gateway.py`, verified at v2026.8.31), and
    /// the previous code discarded that entirely — a start that never
    /// happened still announced "Gateway start requested" and then, two
    /// seconds later, showed the badge built from the pre-existing
    /// `gateway_state.json`.
    ///
    /// The exit code is the only signal read here: `gateway stop` prints
    /// "✗ No gateway running for this profile" and still exits 0, so a
    /// no-op stop reports as requested — the reload that follows tells the
    /// truth. Substring-matching that prose is not a protocol.
    private func runServiceAction(_ verb: String, label: String, settleSeconds: Double) {
        let result = runHermes(["gateway", verb])
        actionGeneration &+= 1
        let generation = actionGeneration

        guard result.exitCode == 0 else {
            actionFailed = true
            actionMessage = SettingsViewModel.failureReason(from: result.output)
                .map { String(localized: "Gateway \(label) failed: \($0)") }
                ?? String(localized: "Gateway \(label) failed")
            // Reload anyway (the host may have moved), but never clear a
            // failure message on a timer — the user dismisses it by taking
            // the next action.
            load()
            return
        }

        actionFailed = false
        actionMessage = String(localized: "Gateway \(label) requested")
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) { [weak self] in
            guard let self, self.actionGeneration == generation else { return }
            self.load()
            self.actionMessage = nil
        }
    }

    func approvePairing(platform: String, code: String) {
        runHermes(["pairing", "approve", platform, code])
        load()
    }

    func revokeUser(_ user: PairedUser) {
        runHermes(["pairing", "revoke", user.platform, user.userId])
        approvedUsers.removeAll { $0.id == user.id }
    }

    // MARK: - Private
    // (loadGatewayStatus / loadPairing were moved to static helpers above
    // so the detached load() can run them without touching MainActor state.)

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }
}
