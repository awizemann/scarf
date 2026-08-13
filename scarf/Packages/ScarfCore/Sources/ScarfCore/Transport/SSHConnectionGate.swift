import Foundation

/// Per-host circuit breaker for outbound SSH connection attempts (gh#138).
///
/// **Why this exists.** Every SSH invocation goes through the user's real
/// `~/.ssh/config`, and a `ProxyCommand` there can have side effects well
/// beyond a TCP dial — Cloudflare Zero Trust's `cloudflared access ssh`
/// opens a browser OAuth tab on every fresh connection attempt, hardware
/// or Secretive agents prompt for a touch, jump hosts can trigger MFA.
/// Scarf's background pollers (remote file watcher every 3s, connection
/// status every 15s) retry a dead connection forever, so an expired Zero
/// Trust session overnight meant thousands of browser tabs.
///
/// **What it does.** Tracks consecutive connection-level failures per host.
/// After `failureThreshold` failures the gate *opens*: callers are rejected
/// instantly (no ssh process spawned, so no ProxyCommand side effects)
/// until a backoff delay elapses. Then exactly one caller is admitted as a
/// probe — claiming the probe slot pushes `nextAllowed` forward so
/// concurrent callers stay rejected while it runs. A successful probe
/// closes the gate and everything resumes at full speed; a failed probe
/// doubles the delay (capped at `maxDelay`).
///
/// Only *connection-level* failures count (ssh exit 255, launch timeout).
/// A remote command that runs and exits non-zero proves the connection is
/// alive and resets the counter.
///
/// Thread-safe via an internal lock; `shared` is the app-wide instance.
/// Tests construct their own and drive time through the `now:` parameters.
public final class SSHConnectionGate: @unchecked Sendable {
    public static let shared = SSHConnectionGate()

    public enum Admission: Equatable {
        case allowed
        /// Gate is open; no attempt should be made before `retryAt`.
        case blocked(retryAt: Date)
    }

    private struct HostState {
        var consecutiveFailures = 0
        var currentDelay: TimeInterval = 0
        var nextAllowed = Date.distantPast
        var isOpen = false
    }

    private let lock = NSLock()
    private var states: [String: HostState] = [:]

    /// Consecutive connection failures before the gate opens.
    public let failureThreshold: Int
    /// First backoff delay once open; doubles per failed probe.
    public let baseDelay: TimeInterval
    /// Backoff ceiling.
    public let maxDelay: TimeInterval

    public init(failureThreshold: Int = 3, baseDelay: TimeInterval = 30, maxDelay: TimeInterval = 300) {
        self.failureThreshold = failureThreshold
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Stable key for a server. Port matters: the same hostname on two
    /// ports is two distinct SSH endpoints (and two ProxyCommand rules).
    public static func key(host: String, port: Int?) -> String {
        "\(host):\(port ?? 22)"
    }

    /// Ask permission to spawn an SSH attempt toward `key`. When the gate
    /// is open and the backoff has elapsed, the caller is admitted as the
    /// single probe (the slot is claimed atomically here).
    public func admit(_ key: String, now: Date = Date()) -> Admission {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[key], state.isOpen else { return .allowed }
        if now >= state.nextAllowed {
            // Claim the probe slot: push nextAllowed forward so concurrent
            // callers are rejected while this probe is in flight.
            state.nextAllowed = now.addingTimeInterval(state.currentDelay)
            states[key] = state
            return .allowed
        }
        return .blocked(retryAt: state.nextAllowed)
    }

    /// The connection worked (the remote actually executed something —
    /// remote exit code is irrelevant). Fully closes the gate.
    public func recordSuccess(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        states[key] = nil
    }

    /// A connection-level failure (ssh exit 255 / dial timeout).
    public func recordFailure(_ key: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var state = states[key] ?? HostState()
        state.consecutiveFailures += 1
        if state.consecutiveFailures >= failureThreshold {
            state.currentDelay = state.isOpen
                ? min(state.currentDelay * 2, maxDelay)
                : baseDelay
            state.isOpen = true
            state.nextAllowed = now.addingTimeInterval(state.currentDelay)
        }
        states[key] = state
    }

    /// Whether the gate is currently open (rejecting attempts) for `key`.
    public func isOpen(_ key: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let state = states[key], state.isOpen else { return false }
        return now < state.nextAllowed
    }

    /// Forget everything about `key`. Used when the user explicitly
    /// retries (Test Connection, manual reconnect) — user intent overrides
    /// the backoff — and when a server is removed.
    public func reset(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        states[key] = nil
    }
}
