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
    /// True when `hermes gateway status` reports this profile is served by
    /// the DEFAULT profile's multiplexer rather than by a gateway process of
    /// its own — the first branch of `_cmd_status`
    /// (`hermes_cli/gateway.py:6112-6115` at tag `v2026.9.7`), which prints
    /// `✓ Gateway is running via the default-profile multiplexer` and no PID
    /// at all. v0.21.1+; a pre-target host never prints it, so this stays
    /// `false` there and every badge renders exactly as before.
    let isServedByMultiplexer: Bool
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

    /// How `hermes gateway status` / `pairing …` are invoked. Production is
    /// `context.cliRunner`; tests inject a fake so the off-main and
    /// coalescing invariants are provable (see `HermesCLIRunner`).
    @ObservationIgnored nonisolated let cliRunner: HermesCLIRunner

    /// Cap on each read probe in `load()`. `gateway status` and `pairing
    /// list` answer in well under a second on a healthy host; the point of
    /// naming a shorter cap than `runHermes`'s 60 s default is charter C10 —
    /// a wedged SSH host must not pin a load task for a full minute while
    /// file-watcher ticks pile up behind it. Nothing user-visible changes on
    /// a healthy host: only the spinner's worst case moves.
    static let probeTimeout: TimeInterval = 30

    init(
        context: ServerContext = .local,
        capabilities: HermesCapabilities = .empty,
        cliRunner: HermesCLIRunner? = nil
    ) {
        self.context = context
        self.capabilities = capabilities
        self.cliRunner = cliRunner ?? context.cliRunner
    }

    var gateway = MessagingGatewayInfo(pid: nil, state: "unknown", exitReason: nil, startTime: nil, updatedAt: nil, platforms: [], isLoaded: false, isServedByMultiplexer: false, isRunning: false)
    var approvedUsers: [PairedUser] = []
    var pendingPairings: [PendingPairing] = []
    var isLoading = false
    var actionMessage: String?
    /// `hermes gateway list --json` snapshot. `nil` when the verb fails
    /// (pre-v0.13 host or no profiles registered yet) — the digest row
    /// hides itself in that case.
    var gatewayList: GatewayListSnapshot?

    /// Newest-wins token for `load()`. A load is unparameterised, so
    /// coalescing would normally do — but every mutation here (start / stop /
    /// approve / revoke) changes the very state a load reads, and a load that
    /// started BEFORE the mutation would otherwise commit pre-mutation data
    /// on top of the post-mutation reload. Mutations bump this token as they
    /// begin, so any load already in flight drops its result. Same shape as
    /// `InsightsViewModel`'s generation guard (F4), for the same reason:
    /// joining or replaying a stale pass answers the wrong question.
    @ObservationIgnored private var loadGeneration = 0

    /// Invalidate every in-flight `load()`. Called at the start of each
    /// mutation so a reload issued afterwards is the only one that can commit.
    private func invalidateInFlightLoads() {
        loadGeneration &+= 1
    }

    /// The file-watcher change token this VM last loaded (or is currently
    /// loading) for. `GatewayView` re-loads on every `lastChangeDate` tick,
    /// and the gateway writes `gateway_state.json` far more often than it
    /// changes anything Scarf renders — so without a token every rewrite
    /// spawned three fresh CLI invocations (`gateway status`, `pairing
    /// list`, `gateway list`) against a possibly-remote host. Same shape as
    /// `PlatformsViewModel.load(changeToken:force:)`.
    @ObservationIgnored private var loadedChangeToken: Date?
    @ObservationIgnored private var inFlightChangeToken: Date?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - changeToken: the file-watcher tick this load answers. A repeat of
    ///     the token already loaded, or already in flight, is a no-op — that
    ///     is the coalescing: N rapid ticks carrying one token produce one
    ///     in-flight load, not N.
    ///   - force: bypass the token check. Every internal reload (after a
    ///     start/stop/restart, approve, revoke) passes this, because those
    ///     change the very state a load reads and must never be coalesced
    ///     away against a stale token.
    func load(changeToken: Date? = nil, force: Bool = false) {
        if !force, hasLoaded, changeToken == (isLoading ? inFlightChangeToken : loadedChangeToken) {
            return
        }
        hasLoaded = true
        isLoading = true
        inFlightChangeToken = changeToken
        loadGeneration &+= 1
        let generation = loadGeneration
        let ctx = context
        let caps = capabilities
        let run = cliRunner
        // Cancel-prior so a superseded load stops between its probes rather
        // than running all three to completion just to have its result
        // dropped by the generation guard.
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // Two sync transport calls + three CLI invocations — substantial
            // remote latency. Detach the whole load and commit at the end.
            let snapshot = await Task.detached { () -> (MessagingGatewayInfo, (approved: [PairedUser], pending: [PendingPairing]), GatewayListSnapshot?)? in
                let status = Self.fetchGatewayStatus(context: ctx, run: run)
                if Task.isCancelled { return nil }
                let pairing = Self.fetchPairing(context: ctx, run: run)
                if Task.isCancelled { return nil }
                let listSnap = caps.hasGatewayList
                    ? HermesGatewayListService.fetch(context: ctx)
                    : nil
                return (status, pairing, listSnap)
            }.value
            guard let self, self.loadGeneration == generation else { return }
            guard let snapshot else { return }
            self.gateway = snapshot.0
            self.approvedUsers = snapshot.1.approved
            self.pendingPairings = snapshot.1.pending
            self.gatewayList = snapshot.2
            self.isLoading = false
            self.loadedChangeToken = changeToken
        }
    }

    /// Static form of the gateway-status walk so the detached load can call
    /// it without bouncing back to MainActor.
    nonisolated private static func fetchGatewayStatus(
        context: ServerContext,
        run: HermesCLIRunner
    ) -> MessagingGatewayInfo {
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

        let statusOutput = run(["gateway", "status"], probeTimeout).output
        let isLoaded = isServiceLoaded(pid: pid, statusOutput: statusOutput)

        return MessagingGatewayInfo(
            pid: pid, state: state, exitReason: exitReason,
            startTime: startTime, updatedAt: updatedAt,
            platforms: platforms, isLoaded: isLoaded,
            isServedByMultiplexer: isServedByMultiplexer(statusOutput: statusOutput),
            isRunning: isGatewayRunning(state: state, statusOutput: statusOutput)
        )
    }

    /// The v0.21.1 multiplexer marker printed by the FIRST branch of
    /// `_cmd_status` (`hermes_cli/gateway.py:6114` at tag `v2026.9.7`):
    ///
    /// ```
    /// ✓ Gateway is running via the default-profile multiplexer
    ///   Manage it from the default profile: hermes gateway status
    /// ```
    ///
    /// That branch runs when this profile has no gateway process of its own
    /// (`not snapshot.running`) but `named_profile_served_by_running_multiplexer()`
    /// says the default profile's multiplexer is carrying its inbound
    /// traffic. It prints **no PID** — the pid belongs to the default
    /// profile's process — which is exactly why `isServiceLoaded`'s
    /// `pid != nil` fallback badged a served satellite "not loaded".
    ///
    /// Matched on the distinguishing tail (`via the default-profile
    /// multiplexer`) rather than the whole line so the shared
    /// `✓ Gateway is running` prefix stays the property of
    /// `isGatewayRunning`.
    nonisolated static func isServedByMultiplexer(statusOutput: String) -> Bool {
        statusOutput.contains("via the default-profile multiplexer")
    }

    /// Live-probe liveness. `✗ Gateway is not running` and
    /// `✓ Gateway is running (PID: …)` are the two verdicts the manual
    /// branch of `hermes gateway status` prints (`hermes_cli/gateway.py`
    /// lines 6133/6127 at tag `v2026.9.7`); the systemd/launchd/Windows
    /// branches print neither, so there the stored `gateway_state` is all
    /// we have and the old behaviour is kept.
    ///
    /// v0.21.1's multiplexer branch prints `✓ Gateway is running via the
    /// default-profile multiplexer` (`gateway.py:6114`), which already
    /// satisfies the `✓ Gateway is running` prefix — so a served satellite
    /// reads as running with no change here.
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
    ///  - **v0.21.1:** `✓ Gateway is running via the default-profile
    ///    multiplexer` (`gateway.py:6114`) — the satellite profile IS being
    ///    served, by a supervised process belonging to the default profile,
    ///    and no PID is printed for it. This case is tested FIRST: it wins
    ///    over the `pid != nil` fallback, which would otherwise badge a
    ///    served profile "not loaded" purely for lack of a pid of its own.
    ///    `GatewayView` renders it as "Served by default profile" rather
    ///    than "Loaded" so the two are never conflated.
    nonisolated static func isServiceLoaded(pid: Int?, statusOutput: String) -> Bool {
        if statusOutput.contains("✗ Gateway is not running") { return false }
        if isServedByMultiplexer(statusOutput: statusOutput) { return true }
        if statusOutput.contains("(Running manually, not as a system service)") { return false }
        return pid != nil
    }

    nonisolated private static func fetchPairing(
        context: ServerContext,
        run: HermesCLIRunner
    ) -> (approved: [PairedUser], pending: [PendingPairing]) {
        let output = run(["pairing", "list"], probeTimeout).output
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
        guard !isBusy else { return }
        isBusy = true
        // Bump BOTH tokens before the CLI runs: `actionGeneration` cancels an
        // earlier action's settle timer, `loadGeneration` cancels any load
        // already reading the pre-action state.
        actionGeneration &+= 1
        invalidateInFlightLoads()
        let generation = actionGeneration
        let ctx = context

        Task { [weak self] in
            // `hermes gateway start|stop|restart` is a process spawn against a
            // possibly-remote host; running it inline froze the whole app for
            // the duration. Detached, exactly like `load()` above.
            let result = await Task.detached { ctx.runHermes(["gateway", verb]) }.value
            guard let self else { return }
            self.isBusy = false
            // A newer action superseded this one while the CLI ran — its
            // message and its reload own the UI now.
            guard self.actionGeneration == generation else { return }

            guard result.exitCode == 0 else {
                self.actionFailed = true
                self.actionMessage = SettingsViewModel.failureReason(from: result.output)
                    .map { String(localized: "Gateway \(label) failed: \($0)") }
                    ?? String(localized: "Gateway \(label) failed")
                // Reload anyway (the host may have moved), but never clear a
                // failure message on a timer — the user dismisses it by taking
                // the next action.
                self.load(force: true)
                return
            }

            self.actionFailed = false
            self.actionMessage = String(localized: "Gateway \(label) requested")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(settleSeconds))
                guard let self, self.actionGeneration == generation else { return }
                self.load(force: true)
                self.actionMessage = nil
            }
        }
    }

    func approvePairing(platform: String, code: String) {
        guard !isBusy else { return }
        isBusy = true
        invalidateInFlightLoads()
        let ctx = context
        Task { [weak self] in
            let result = await Task.detached {
                ctx.runHermes(["pairing", "approve", platform, code])
            }.value
            guard let self else { return }
            self.isBusy = false
            if result.exitCode != 0 {
                self.actionFailed = true
                self.actionMessage = SettingsViewModel.failureReason(from: result.output)
                    .map { String(localized: "Approve failed: \($0)") }
                    ?? String(localized: "Approve failed")
            } else {
                self.actionFailed = false
            }
            self.load(force: true)
        }
    }

    func revokeUser(_ user: PairedUser) {
        guard !isBusy else { return }
        isBusy = true
        invalidateInFlightLoads()
        let ctx = context
        Task { [weak self] in
            let result = await Task.detached {
                ctx.runHermes(["pairing", "revoke", user.platform, user.userId])
            }.value
            guard let self else { return }
            self.isBusy = false
            // Only drop the row when the CLI agreed — the optimistic removal
            // it replaced hid a failed revoke behind a vanished row until the
            // next load put it back.
            if result.exitCode == 0 {
                self.actionFailed = false
                self.approvedUsers.removeAll { $0.id == user.id }
            } else {
                self.actionFailed = true
                self.actionMessage = SettingsViewModel.failureReason(from: result.output)
                    .map { String(localized: "Revoke failed: \($0)") }
                    ?? String(localized: "Revoke failed")
            }
            self.load(force: true)
        }
    }

    /// True while a service action or pairing mutation is running. The view
    /// disables the buttons on it, so the state transition actually renders
    /// rather than the whole window freezing for the CLI's duration.
    private(set) var isBusy = false

    // MARK: - Private
    // (loadGatewayStatus / loadPairing were moved to static helpers above
    // so the detached load() can run them without touching MainActor state.)
}
