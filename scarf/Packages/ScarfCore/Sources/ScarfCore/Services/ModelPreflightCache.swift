import Foundation

/// Process-lifetime memo of POSITIVE `ModelPreflight` verdicts, keyed by
/// `ServerID` (the same key `CitadelTransportPool` uses). ScarfGo consults it
/// before reading `config.yaml` on every chat start/resume (gh#150): a cached
/// "configured" skips the read — which on a Docker host can cost two cold
/// `hermes config` runs. A negative verdict is never stored, so a server that
/// still needs a model is re-checked every time. A stale positive costs
/// nothing extra: Hermes reports a missing model on the first prompt.
///
/// Used by the iOS app only; the Mac does not consult it.
public final class ModelPreflightCache: @unchecked Sendable {
    public static let shared = ModelPreflightCache()

    private let lock = NSLock()
    private var configured: Set<ServerID> = []

    public init() {}

    /// True when this server previously passed the preflight in this process.
    public func isKnownConfigured(_ server: ServerID) -> Bool {
        lock.withLock { configured.contains(server) }
    }

    /// Record a verdict. Only `.configured` is remembered; any other result
    /// clears the entry so the next start re-checks.
    public func record(_ result: ModelPreflight.Result, for server: ServerID) {
        lock.withLock {
            if result.isConfigured {
                configured.insert(server)
            } else {
                configured.remove(server)
            }
        }
    }

    /// Drop the server's entry (model changed, server forgotten).
    public func invalidate(_ server: ServerID) {
        _ = lock.withLock { configured.remove(server) }
    }
}
