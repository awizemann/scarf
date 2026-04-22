import Foundation

/// Persistent connection parameters for the iOS app's single
/// configured Hermes server.
///
/// **iOS is single-server in v1.** Multi-server management comes in
/// a later phase; until then this one record is all the storage the
/// app needs outside of the Keychain-backed SSH key.
public struct IOSServerConfig: Sendable, Hashable, Codable {
    /// Hostname or `~/.ssh/config`-like alias typed by the user.
    public var host: String
    /// Remote username. Optional — `nil` defers to whatever login the
    /// remote SSH daemon considers default (unlike the Mac app,
    /// iOS can't consult `~/.ssh/config`, so we usually want this set).
    public var user: String?
    /// TCP port. `nil` → 22.
    public var port: Int?
    /// Remote path to `hermes` binary. `nil` → rely on remote `$PATH`.
    public var hermesBinaryHint: String?
    /// Override for the remote `$HOME/.hermes` directory. `nil` →
    /// `~/.hermes` (expanded by the remote shell).
    public var remoteHome: String?
    /// User-chosen label that shows up in the UI. Defaults to the
    /// hostname but users can rename (e.g. "Home Server").
    public var displayName: String

    public init(
        host: String,
        user: String? = nil,
        port: Int? = nil,
        hermesBinaryHint: String? = nil,
        remoteHome: String? = nil,
        displayName: String
    ) {
        self.host = host
        self.user = user
        self.port = port
        self.hermesBinaryHint = hermesBinaryHint
        self.remoteHome = remoteHome
        self.displayName = displayName
    }

    /// Convenience bridge to the `ServerContext` that services across
    /// ScarfCore use (`HermesDataService(context:)` etc.). The returned
    /// context carries the SSH-kind so any transport constructed from
    /// it runs over SSH.
    ///
    /// **Note:** The iOS `SSHTransport` path won't actually exec
    /// `/usr/bin/ssh` (which doesn't exist on iOS). In M3 a Citadel-
    /// backed `ServerTransport` will replace that — at which point
    /// `makeTransport()` on an iOS `ServerContext` will dispatch to
    /// the Citadel one, and the rest of the service layer continues
    /// unchanged.
    public func toServerContext(id: ServerID) -> ServerContext {
        let ssh = SSHConfig(
            host: host,
            user: user,
            port: port,
            identityFile: nil, // key comes from Keychain on iOS
            remoteHome: remoteHome,
            hermesBinaryHint: hermesBinaryHint
        )
        return ServerContext(
            id: id,
            displayName: displayName,
            kind: .ssh(ssh)
        )
    }
}

/// Async-safe single-record storage contract. iOS implements this
/// with `UserDefaults`; tests use `InMemoryIOSServerConfigStore`.
public protocol IOSServerConfigStore: Sendable {
    /// Returns the stored config, or `nil` if nothing has been saved
    /// yet (fresh install, or the user reset onboarding).
    func load() async throws -> IOSServerConfig?

    /// Overwrites any existing config. Idempotent.
    func save(_ config: IOSServerConfig) async throws

    /// Deletes the stored config. No-op if empty.
    func delete() async throws
}

/// Process-lifetime in-memory config store. For tests and previews.
public actor InMemoryIOSServerConfigStore: IOSServerConfigStore {
    private var config: IOSServerConfig?

    public init(initial: IOSServerConfig? = nil) {
        self.config = initial
    }

    public func load() async throws -> IOSServerConfig? { config }
    public func save(_ config: IOSServerConfig) async throws { self.config = config }
    public func delete() async throws { config = nil }
}
