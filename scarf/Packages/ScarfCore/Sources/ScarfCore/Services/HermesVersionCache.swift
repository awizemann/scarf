import Foundation
#if canImport(os)
import os
#endif

/// Process-wide, per-server cache for the `hermes --version` probe.
///
/// Before this existed, every consumer that needed the host's Hermes version
/// spawned its own `--version` subprocess: `HermesCapabilitiesStore` on each
/// store init, `ProjectTemplateInstaller` on every template install,
/// `FleetApplyExecutor` on every fleet apply. Nothing was shared and nothing
/// survived a relaunch, so a cold launch always painted capability-gated UI
/// as "unknown" (= hidden) until an unbounded subprocess answered — and a
/// transient probe failure silently blanked every gated surface.
///
/// This type collapses all of that into **one probe per server connection**:
///
/// - **Dedup.** Concurrent async callers for the same server join a single
///   in-flight `Task`; later callers hit the in-memory result.
/// - **Persistence.** A successful probe writes its raw version line to
///   `UserDefaults`, keyed by a *connection fingerprint* (see `key(for:)`).
///   The next launch can seed capability UI optimistically from that
///   last-known value while the fresh probe runs, then reconcile.
/// - **Graceful failure.** A failed probe is never cached and never
///   persisted, so a host that comes back later is re-probed rather than
///   pinned to a bogus answer.
///
/// **Only successful probes are cached.** A `.empty` (undetected) result is
/// deliberately *not* memoized: caching "I couldn't tell" would turn a
/// momentary PATH hiccup into a session-long capability blackout.
///
/// Thread-safety: a plain `NSLock` around two dictionaries. The probe itself
/// runs outside the lock, so a slow SSH round-trip to one host never blocks
/// a cache read for another.
public final class HermesVersionCache: @unchecked Sendable {

    /// Shared instance used by production code. Tests construct their own
    /// with an isolated `UserDefaults` suite and a stub probe.
    public static let shared = HermesVersionCache()

    /// Runs `hermes --version` against a server and parses the result.
    /// Injected so tests never spawn a subprocess.
    public typealias Probe = @Sendable (ServerContext) -> HermesCapabilities

    #if canImport(os)
    private let logger = Logger(subsystem: "com.scarf", category: "HermesVersionCache")
    #endif

    private let defaults: UserDefaults
    private let probe: Probe
    private let ttl: TimeInterval
    private let lock = NSLock()

    /// Successful probes completed in this process, keyed by `key(for:)`,
    /// with the instant they landed (see `ttl`).
    private var fresh: [String: (caps: HermesCapabilities, at: Date)] = [:]
    /// In-flight async probes, so N concurrent callers cause 1 subprocess.
    private var inFlight: [String: Task<HermesCapabilities, Never>] = [:]

    /// - Parameter ttl: How long a successful probe stays authoritative.
    ///   Bounds staleness after an out-of-band `hermes update`: the Mac app
    ///   already invalidates on foreground, but `capabilitiesSync` call sites
    ///   probe *other* hosts (fleet targets) that nothing else invalidates,
    ///   and a stale-high answer there would forward a CLI flag the host
    ///   doesn't understand. Ten minutes keeps the probe effectively
    ///   once-per-session while capping that window.
    public init(
        defaults: UserDefaults = .standard,
        ttl: TimeInterval = 600,
        probe: @escaping Probe = HermesVersionCache.subprocessProbe
    ) {
        self.defaults = defaults
        self.ttl = ttl
        self.probe = probe
    }

    // MARK: - Keying

    private static let defaultsKeyPrefix = "scarf.hermesVersionLine."

    /// Stable identity for a *connection*, not for a registry row.
    ///
    /// Deliberately **not** the `ServerID` UUID: the user can re-point an
    /// existing server entry at a different machine (Mac → Docker box), and
    /// keying on the row's UUID would hand the new host the old host's
    /// remembered version. Fingerprinting the actual connection coordinates
    /// (transport, user@host:port, Hermes home) means a re-pointed entry
    /// starts cold, while two entries that genuinely address the same
    /// installation correctly share one probe.
    public static func key(for context: ServerContext) -> String {
        switch context.kind {
        case .local:
            return "local|\(context.paths.home)"
        case .ssh(let config):
            let user = config.user ?? "-"
            let port = config.port.map(String.init) ?? "22"
            return "ssh|\(user)@\(config.host):\(port)|\(context.paths.home)"
        }
    }

    private func defaultsKey(for context: ServerContext) -> String {
        Self.defaultsKeyPrefix + Self.key(for: context)
    }

    // MARK: - Reads

    /// Result of a probe that already completed in this process, or `nil`.
    /// Never returns a persisted (previous-launch) value — callers that
    /// want that ask for `lastKnown(for:)` explicitly.
    public func cached(for context: ServerContext) -> HermesCapabilities? {
        lock.lock()
        defer { lock.unlock() }
        return unexpiredLocked(Self.key(for: context))
    }

    /// Caller must hold `lock`.
    private func unexpiredLocked(_ key: String) -> HermesCapabilities? {
        guard let entry = fresh[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < ttl else {
            fresh[key] = nil
            return nil
        }
        return entry.caps
    }

    /// The version this connection reported the last time a probe succeeded,
    /// possibly in a previous launch. `.empty` when we've never seen it.
    ///
    /// This is an *optimistic* value: the host may have been upgraded or
    /// downgraded since. Use it to avoid a cold-start flash of empty UI, and
    /// reconcile with the fresh probe when it lands.
    public func lastKnown(for context: ServerContext) -> HermesCapabilities {
        guard let line = defaults.string(forKey: defaultsKey(for: context)) else { return .empty }
        return HermesCapabilities.parse(line)
    }

    // MARK: - Probing

    /// Cached-or-probe, async. Concurrent callers for the same server share
    /// one subprocess. Returns `.empty` if the probe fails (not cached).
    public func capabilities(for context: ServerContext) async -> HermesCapabilities {
        let key = Self.key(for: context)

        lock.lock()
        if let hit = unexpiredLocked(key) {
            lock.unlock()
            return hit
        }
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task.detached(priority: .utility) { [self] () -> HermesCapabilities in
            let result = probe(context)
            record(result, key: key, context: context)
            return result
        }
        inFlight[key] = task
        lock.unlock()
        return await task.value
    }

    /// Cached-or-probe, synchronous. For `nonisolated` call sites that build
    /// CLI arguments inline (template install, fleet apply) and can't await.
    ///
    /// Never falls back to the persisted last-known value: those callers gate
    /// *CLI flags* on the answer, and forwarding a flag an older host doesn't
    /// understand is an argparse failure that aborts the whole operation. A
    /// failed probe must stay conservative (`.empty`), exactly as before.
    public func capabilitiesSync(for context: ServerContext) -> HermesCapabilities {
        let key = Self.key(for: context)

        lock.lock()
        if let hit = unexpiredLocked(key) {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Probe outside the lock. Two racing sync callers may both probe;
        // that's strictly better than holding a global lock across a subprocess,
        // and the result is idempotent.
        let result = probe(context)
        record(result, key: key, context: context)
        return result
    }

    /// Drop any memoized result and re-probe. Used by the "Re-detect" button
    /// and after `hermes update`, where the whole point is to observe a
    /// version that just changed.
    @discardableResult
    public func refresh(for context: ServerContext) async -> HermesCapabilities {
        invalidate(for: context)
        return await capabilities(for: context)
    }

    /// Forget the in-process result for this server. The persisted
    /// last-known value survives (it's only a cold-start hint); the next
    /// successful probe overwrites it.
    public func invalidate(for context: ServerContext) {
        lock.lock()
        fresh[Self.key(for: context)] = nil
        lock.unlock()
    }

    /// Forget everything, in memory only. Test hook.
    public func invalidateAll() {
        lock.lock()
        fresh.removeAll()
        lock.unlock()
    }

    private func record(_ caps: HermesCapabilities, key: String, context: ServerContext) {
        lock.lock()
        inFlight[key] = nil
        // Only successful detections are memoized/persisted — see type doc.
        if caps.detected { fresh[key] = (caps, Date()) }
        lock.unlock()

        if caps.detected {
            defaults.set(caps.versionLine, forKey: defaultsKey(for: context))
        }
    }

    // MARK: - Default probe

    /// The real probe: runs `hermes --version` over this server's transport
    /// (LocalTransport on Mac, SSH/Citadel on iOS) and parses the output.
    ///
    /// Lives here rather than on `HermesCapabilities` because
    /// `ServerContext.makeTransport()` is side-effecting; the parser stays pure.
    public static let subprocessProbe: Probe = { context in
        let transport = context.makeTransport()
        do {
            let result = try transport.runProcess(
                executable: context.paths.hermesBinary,
                args: ["--version"],
                stdin: nil,
                timeout: 10
            )
            // `hermes --version` writes to stdout but Scarf's transport
            // helpers occasionally split error output across stderr — fold
            // both so the parser sees whichever stream the line lands on.
            guard result.exitCode == 0 else { return .empty }
            return HermesCapabilities.parse(result.stdoutString + result.stderrString)
        } catch {
            return .empty
        }
    }
}
