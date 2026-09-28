import Foundation
import ScarfCore

/// Follows a gateway restart that Hermes is holding for in-flight work,
/// until the replacement is running (S07-F3).
///
/// The restart CLI is still capped at 60 s (charter C10); what outlives it
/// is this watch, which reads `gateway_state.json` off the main actor every
/// ``interval``. (For a named profile the read resolves the multiplexer's
/// root record, which can run a 5 s-capped `pgrep` — still off-main.) See
/// ``HermesGatewayRestartDrain`` for why the state file is the source.
///
/// It is bounded by Hermes's own wait (`budgetSeconds`, ~30 min by default)
/// plus a grace period, after which it stops and says the gateway has not
/// reported back. The user can leave at any time with ``stopWatching()``;
/// that only ends Scarf's watch — Hermes restarts the gateway either way.
@Observable
@MainActor
final class GatewayRestartDrainWatcher {

    enum Status: Equatable {
        case idle
        case watching(HermesGatewayRestartDrain.Phase)
        case restarted
        case failed(String?)
        /// Hermes's wait (plus grace) passed with no replacement reported.
        case gaveUp
        /// The old gateway exited and nothing started a new one within
        /// ``revivalGraceSeconds`` — the service manager is not going to.
        case notRevived
        /// The draining gateway is gone (or its record went stale with no
        /// proof it is alive) while the file still says draining: it died
        /// before finishing the restart.
        case stoppedWithoutRestart
        /// The user stopped watching; Hermes carries on.
        case left
    }

    private(set) var status: Status = .idle
    private(set) var startedAt: Date?

    /// Called once when the watch ends — by itself (restarted, failed, not
    /// revived, gave up) or by Stop Waiting. The pane reloads its status
    /// and settles its own message there.
    @ObservationIgnored var onFinished: (() -> Void)?

    @ObservationIgnored private let readState: @Sendable () -> Data?
    @ObservationIgnored private let isAlive: @Sendable (Int) -> Bool?
    @ObservationIgnored private let heartbeatStale: Duration
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let graceSeconds: Int
    @ObservationIgnored private let revivalGraceSeconds: Int
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - readState: returns `gateway_state.json` (the profile's own, or the
    ///     root record's entry for a multiplexed profile). Runs off the main
    ///     actor. Tests inject a fake.
    ///   - interval: poll cadence. Hermes refreshes `active_work` every 30 s
    ///     while draining, so 10 s is plenty.
    ///   - isAlive: whether a PID is still running on the host — `true`,
    ///     `false`, or `nil` when it cannot tell. Runs off the main actor.
    init(
        readState: @escaping @Sendable () -> Data?,
        isAlive: @escaping @Sendable (Int) -> Bool? = { _ in nil },
        interval: Duration = .seconds(10),
        graceSeconds: Int = 120,
        revivalGraceSeconds: Int = 90,
        heartbeatStaleSeconds: Int = HermesGatewayRestartDrain.heartbeatStaleSeconds
    ) {
        self.readState = readState
        self.isAlive = isAlive
        self.heartbeatStale = .seconds(heartbeatStaleSeconds)
        self.interval = interval
        self.graceSeconds = graceSeconds
        self.revivalGraceSeconds = revivalGraceSeconds
    }

    /// The production reader for `context`.
    convenience init(context: ServerContext) {
        self.init(
            readState: {
                HermesFileService(context: context)
                    .gatewayStateData(own: context.readData(context.paths.gatewayStateJSON))
            },
            isAlive: { pid in Self.probeLiveness(pid: pid, context: context) }
        )
    }

    /// `kill -0` — locally a syscall, remotely one `sh -c` over the existing
    /// SSH connection with a 10 s cap (C10: called off the main actor only).
    nonisolated static func probeLiveness(pid: Int, context: ServerContext) -> Bool? {
        guard pid > 0 else { return nil }
        if !context.isRemote {
            if kill(pid_t(pid), 0) == 0 { return true }
            return errno == ESRCH ? false : nil
        }
        guard let result = try? context.makeTransport().runProcess(
            executable: "/bin/sh", args: HermesGatewayRestartDrain.livenessArgv(pid: pid),
            stdin: nil, timeout: 10)
        else { return nil }
        return HermesGatewayRestartDrain.liveness(exitCode: result.exitCode, stderr: result.stderrString)
    }

    var isWatching: Bool {
        if case .watching = status { return true }
        return false
    }

    /// Begin watching from the draining snapshot the restart left behind.
    func start(from snapshot: HermesGatewayRestartDrain.Snapshot, budgetSeconds: Int?) {
        task?.cancel()
        startedAt = Date()
        status = .watching(.draining(work: snapshot.activeWork))
        let drainingPID = snapshot.pid
        let limit = (budgetSeconds ?? HermesGatewayRestartDrain.defaultBudgetSeconds) + graceSeconds
        let deadline = ContinuousClock.now + .seconds(limit)
        let read = readState
        let interval = interval
        let revivalGrace = Duration.seconds(revivalGraceSeconds)
        let alive = isAlive
        let staleAfter = heartbeatStale
        task = Task { [weak self] in
            // The draining record's heartbeat: when `updated_at` last CHANGED,
            // by this Mac's monotonic clock (host clocks may differ).
            var lastStamp = snapshot.updatedAt
            var stampChangedAt = ContinuousClock.now
            var polls = 0
            // When the old gateway was first seen gone with no replacement.
            // launchd KeepAlive / systemd RestartForceExitStatus relaunch
            // within seconds; a unit without them relied on the CLI's own
            // follow-up `start`/`kickstart`, which Scarf's timer killed.
            var goneSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                let data = await OffPool.run { read() }
                if Task.isCancelled { return }
                let snap = HermesGatewayRestartDrain.snapshot(stateJSON: data)
                let phase = HermesGatewayRestartDrain.phase(of: snap, drainingPID: drainingPID)
                polls += 1
                if snap?.updatedAt != lastStamp {
                    lastStamp = snap?.updatedAt
                    stampChangedAt = ContinuousClock.now
                }
                // A draining record that outlives its process: the gateway
                // crashed mid-drain and nothing will finish this restart.
                // Liveness every third poll (a remote probe is an SSH exec);
                // a stale heartbeat counts only when liveness is UNKNOWN,
                // because Hermes treats a stale heartbeat with a live PID as
                // a warning, not death.
                if case .draining = phase, let pid = drainingPID, polls % 3 == 0 {
                    let isLive = await OffPool.run { alive(pid) }
                    if Task.isCancelled { return }
                    let stale = ContinuousClock.now - stampChangedAt >= staleAfter
                    if isLive == false || (isLive == nil && stale) {
                        self?.finish(.stoppedWithoutRestart)
                        return
                    }
                }
                guard let self else { return }
                switch phase {
                case .restarted:
                    self.finish(.restarted)
                    return
                case .failed(let reason):
                    self.finish(.failed(reason))
                    return
                case .waitingForServiceManager:
                    let since = goneSince ?? ContinuousClock.now
                    goneSince = since
                    if ContinuousClock.now - since >= revivalGrace {
                        self.finish(.notRevived)
                        return
                    }
                    self.status = .watching(phase)
                default:
                    goneSince = nil
                    self.status = .watching(phase)
                }
                if ContinuousClock.now >= deadline {
                    self.finish(.gaveUp)
                    return
                }
            }
        }
    }

    /// The user leaves the wait. Hermes still restarts the gateway.
    func stopWatching() {
        guard isWatching else { return }
        task?.cancel()
        task = nil
        status = .left
        onFinished?()
    }

    /// Forget the watch entirely — a new gateway action owns the pane now.
    func reset() {
        task?.cancel()
        task = nil
        status = .idle
        startedAt = nil
    }

    private func finish(_ final: Status) {
        task = nil
        status = final
        onFinished?()
    }

    /// The banner's headline for the current status, or nil when idle.
    var headline: String? {
        switch status {
        case .idle:
            return nil
        case .watching(.draining):
            return String(localized: "Waiting for the current turn to finish before restarting the gateway…")
        case .watching(.waitingForServiceManager):
            return String(localized: "The old gateway has stopped — waiting for the service manager to start it again…")
        case .watching(.starting):
            return String(localized: "The gateway is starting…")
        case .watching:
            return String(localized: "Restarting the gateway…")
        case .restarted:
            return String(localized: "Gateway restarted")
        case .failed(let reason):
            return reason.map { String(localized: "The gateway didn't come back: \($0)") }
                ?? String(localized: "The gateway didn't come back after the restart")
        case .gaveUp:
            return String(localized: "Hermes's restart wait has passed and the gateway hasn't reported back — check its status.")
        case .left:
            return String(localized: "Stopped watching. Hermes still restarts the gateway when the current turn ends.")
        case .notRevived:
            return String(localized: "The old gateway stopped, but no new one has started. Start the gateway to bring it back.")
        case .stoppedWithoutRestart:
            return String(localized: "The old gateway stopped without restarting — it is no longer running. Check the status and start it if it isn't back.")
        }
    }

    /// What the gateway says it is still waiting on, when it says.
    var pendingWork: [String] {
        if case .watching(.draining(let work?)) = status { return work }
        return []
    }
}
