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
    init(
        readState: @escaping @Sendable () -> Data?,
        interval: Duration = .seconds(10),
        graceSeconds: Int = 120,
        revivalGraceSeconds: Int = 90
    ) {
        self.readState = readState
        self.interval = interval
        self.graceSeconds = graceSeconds
        self.revivalGraceSeconds = revivalGraceSeconds
    }

    /// The production reader for `context`.
    convenience init(context: ServerContext) {
        self.init(readState: {
            HermesFileService(context: context)
                .gatewayStateData(own: context.readData(context.paths.gatewayStateJSON))
        })
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
        task = Task { [weak self] in
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
                guard let self else { return }
                let phase = HermesGatewayRestartDrain.phase(
                    of: HermesGatewayRestartDrain.snapshot(stateJSON: data), drainingPID: drainingPID)
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
        }
    }

    /// What the gateway says it is still waiting on, when it says.
    var pendingWork: [String] {
        if case .watching(.draining(let work?)) = status { return work }
        return []
    }
}
