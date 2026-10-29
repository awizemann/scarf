import Foundation
import ScarfCore

/// One SSH ControlMaster: the connection every `ssh` to a host shares
/// (`ControlPath=…/%C`, SSHTransport.swift `sshArgs`). `%C` hashes the
/// local host, remote host, port and user, so two server entries for the
/// same `user@host:port` share one master — and its channel limit, and its
/// fate when it dies. Local Hermes has no master; `.local` is one key for
/// every local context (tests' temp homes included).
///
/// Known under-count: the key is built from the server entry, not from
/// what ssh resolves (`ssh -G`). Two entries reaching one master by
/// different spellings — an `~/.ssh/config` alias vs the hostname, a
/// missing user vs the default user spelled out, a `Port` set only in
/// ssh_config — get two keys, so that master can carry up to twice its
/// budget. Resolving would mean a subprocess inside the synchronous
/// `LiveChatBudget.admit`; not worth it for a rare setup.
enum ControlMasterKey: Hashable, Sendable {
    case local
    case ssh(user: String, host: String, port: Int)

    /// The master `context` runs over. A missing user or port is the ssh
    /// default (`~/.ssh/config`, else the local user / 22) — the same
    /// connection as an entry that spells the default out, as far as Scarf
    /// can tell without reading ssh's config.
    nonisolated static func of(_ context: ServerContext) -> ControlMasterKey {
        switch context.kind {
        case .local:
            return .local
        case .ssh(let config):
            return .ssh(
                user: config.user?.trimmingCharacters(in: .whitespaces) ?? "",
                host: config.host.trimmingCharacters(in: .whitespaces).lowercased(),
                port: config.port ?? 22
            )
        }
    }

    var isRemote: Bool { self != .local }
}

/// Single-flight recovery of a dead ControlMaster, per master (parallel
/// chats P1, design §4).
///
/// gh#123: after sleep or a network change a master can hold its socket
/// with the TCP session behind it dead; every ssh through it hangs. The
/// recovery probes it and `-O exit`s a dead one
/// (`SSHTransport.recoverControlMasterIfDead`). Run once per failing chat,
/// that `-O exit` tore down the channel of every OTHER chat on the host
/// — including one whose own reconnect had just brought a fresh master up —
/// and their failures recovered again, a cascade. So every caller (each
/// chat's three failure paths and the wake sweep) goes through here:
///
/// - a recovery already running for the master is joined, not repeated;
/// - for `cooldown` after one finishes, its outcome is returned as is;
/// - the probe itself runs on a thread of its own (`OffPool`, charter C10).
///
/// Then the reconnects are staggered (`reconnectTurn`): after a recovery
/// that left no master, the first chat to reconnect leads, and the others
/// wait for its `hermes acp` to start — which brings the new master up —
/// before their own first attempt. N chats doing N simultaneous ssh
/// handshakes each authenticate on their own, which is the gh#138
/// side-effect storm (browser tabs, hardware-key touches).
///
/// Not covered here: `ServerRegistry`'s `-O exit` when a server is removed
/// (deliberate, nothing to coordinate), and the ACP spawn itself not going
/// through `SSHConnectionGate.admit` (a separate, older gap).
@MainActor
final class SSHMasterRecovery {
    static let shared = SSHMasterRecovery()

    typealias Outcome = SSHTransport.ControlMasterRecovery

    /// How long a finished recovery's outcome stands in for a new probe.
    private let cooldown: TimeInterval
    /// How long a follower waits for the leader's start before going anyway.
    private let followerWaitNanos: UInt64
    /// How long after a recovery its reconnect wave can still be led.
    private let waveLifetime: TimeInterval
    private let now: () -> Date

    init(
        cooldown: TimeInterval = 5,
        followerWait: TimeInterval = 3,
        waveLifetime: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.cooldown = cooldown
        self.followerWaitNanos = UInt64(followerWait * 1_000_000_000)
        self.waveLifetime = waveLifetime
        self.now = now
    }

    private var inFlight: [ControlMasterKey: Task<Outcome, Never>] = [:]
    private var lastOutcome: [ControlMasterKey: (at: Date, outcome: Outcome)] = [:]

    /// Recover `context`'s master if it is dead. Nil for a local context,
    /// which has none.
    @discardableResult
    func recover(context: ServerContext) async -> Outcome? {
        let key = ControlMasterKey.of(context)
        guard key.isRemote else { return nil }
        return await recover(key: key) {
            (context.makeTransport() as? SSHTransport)?.recoverControlMasterIfDead() ?? .noMaster
        }.outcome
    }

    /// What a `recover` call got back. `probedHere`: this call ran the
    /// probe (and any `-O exit`); false when it joined a recovery already
    /// running or got a cooled-down outcome — the master may have been
    /// rebuilt since, so the caller must not act on it as fresh.
    struct Result: Equatable {
        let outcome: Outcome
        let probedHere: Bool
    }

    /// The single-flight core. `probe` is blocking (it spawns `ssh -O
    /// check` / `-O exit` and waits) and runs off the main actor; only the
    /// first caller's probe runs, the rest share its outcome.
    func recover(key: ControlMasterKey, probe: @escaping @Sendable () -> Outcome) async -> Result {
        if let last = lastOutcome[key], now().timeIntervalSince(last.at) < cooldown {
            return Result(outcome: last.outcome, probedHere: false)
        }
        if let running = inFlight[key] {
            return Result(outcome: await running.value, probedHere: false)
        }
        let task = Task { @MainActor [weak self] () -> Outcome in
            let outcome = await OffPool.run(probe)
            if let self {
                self.inFlight[key] = nil
                self.lastOutcome[key] = (self.now(), outcome)
                // A master that answered needs no handshake; anything else
                // means the next ssh to the host makes a new one.
                if outcome != .alive { self.openReconnectWave(for: key) }
            }
            return outcome
        }
        inFlight[key] = task
        return Result(outcome: await task.value, probedHere: true)
    }

    // MARK: - Staggered reconnect

    /// A chat's place in the reconnect wave after a recovery.
    enum ReconnectTurn: Equatable {
        /// No wave (no recent recovery, or it was led already): go.
        case free
        /// First to reconnect: go, and call `leaderStarted(for:waveId:)`
        /// once the client's `start()` returned.
        case leader(waveId: UUID)
        /// Waited for the leader (or the timeout, or was cancelled); go.
        case follower

        var isLeader: Bool { if case .leader = self { true } else { false } }
    }

    private struct Wave {
        let id = UUID()
        let openedAt: Date
        var leaderClaimed = false
        var waiterIds: Set<UUID> = []
    }

    private var waves: [ControlMasterKey: Wave] = [:]
    /// Every parked follower, by its own id — not by wave, so a waiter is
    /// always reachable (by its timer, its cancellation, or the wave's end)
    /// whatever happened to the wave it parked on.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Open a reconnect wave for `key`: the next `reconnectTurn` leads.
    /// Internal for tests (`.local` has no recovery to open one).
    func openReconnectWave(for key: ControlMasterKey) {
        // Waiters on a wave being replaced go now rather than strand.
        if let old = waves[key] { resumeWaiters(old.waiterIds) }
        waves[key] = Wave(openedAt: now())
    }

    /// Wait for this chat's turn to reconnect over `key`'s master. Always
    /// returns: a follower goes when the leader reports, after
    /// `followerWait`, when the wave expires or is replaced, or when its
    /// task is cancelled (a ladder torn down by Stop must not stay parked).
    func reconnectTurn(for key: ControlMasterKey) async -> ReconnectTurn {
        guard var wave = waves[key] else { return .free }
        if now().timeIntervalSince(wave.openedAt) > waveLifetime {
            waves[key] = nil
            resumeWaiters(wave.waiterIds)
            return .free
        }
        guard wave.leaderClaimed else {
            wave.leaderClaimed = true
            waves[key] = wave
            return .leader(waveId: wave.id)
        }
        let waiterId = UUID()
        let budget = followerWaitNanos
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else {
                    cont.resume()
                    return
                }
                waiters[waiterId] = cont
                waves[key]?.waiterIds.insert(waiterId)
                // Bounded: a leader that never reports (cancelled, wedged in
                // `start()`) holds nobody longer than this.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: budget)
                    self?.resumeWaiter(waiterId)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(waiterId) }
        }
        return .follower
    }

    /// The leader of wave `waveId` got its `client.start()` back (or gave
    /// up): the master is up, or won't be by waiting. Releases that wave's
    /// followers and closes it — never a newer wave a later recovery opened.
    func leaderStarted(for key: ControlMasterKey, waveId: UUID) {
        guard let wave = waves[key], wave.id == waveId else { return }
        waves[key] = nil
        resumeWaiters(wave.waiterIds)
    }

    private func resumeWaiters(_ ids: Set<UUID>) {
        for id in ids { resumeWaiter(id) }
    }

    /// Resume one parked follower, once: whichever of its timer, its
    /// cancellation and its wave's end comes first.
    private func resumeWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
