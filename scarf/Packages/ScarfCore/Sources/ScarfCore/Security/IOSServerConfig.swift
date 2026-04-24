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

/// Async-safe multi-record storage contract.
///
/// Single-server callers (v1 onboarding flow, RootModel before M9)
/// use the no-arg `load()` / `save(_:)` / `delete()` methods, which
/// operate on the "primary" server (first entry in the list, or
/// the only entry on a fresh install). Multi-server callers use the
/// ID-keyed variants added in M9.
///
/// A migration helper is embedded: any implementation that discovers
/// a v1 singleton payload on `load()` must insert it under a fresh
/// `ServerID` and leave the list consistent. Callers shouldn't need
/// to know about the migration; they just see a populated list.
public protocol IOSServerConfigStore: Sendable {

    // MARK: - Singleton API (compat, still the default in v1)

    /// Returns the primary stored config, or `nil` if nothing has
    /// been saved yet. In a multi-server world this returns the
    /// first entry in the list (sorted by display name). Kept for
    /// back-compat with RootModel's single-server code path; new
    /// callers should prefer `load(id:)` / `listAll()`.
    func load() async throws -> IOSServerConfig?

    /// Overwrites any existing primary config. In a multi-server
    /// world, saves under the implementation's "primary" slot —
    /// preserving existing non-primary entries. Idempotent.
    func save(_ config: IOSServerConfig) async throws

    /// Deletes ALL stored configs. Matches the v1 "forget" semantics.
    func delete() async throws

    // MARK: - Multi-server API (M9)

    /// Return every configured server, mapped by its `ServerID`.
    /// Empty dictionary on a fresh install.
    func listAll() async throws -> [ServerID: IOSServerConfig]

    /// Load a specific server by id. Returns nil if not present.
    func load(id: ServerID) async throws -> IOSServerConfig?

    /// Save or replace the config for the given id. Does not affect
    /// other servers in the list.
    func save(_ config: IOSServerConfig, id: ServerID) async throws

    /// Remove a specific server by id. No-op if absent.
    func delete(id: ServerID) async throws
}

/// Process-lifetime in-memory config store. For tests and previews.
public actor InMemoryIOSServerConfigStore: IOSServerConfigStore {
    private var storage: [ServerID: IOSServerConfig] = [:]

    public init(initial: IOSServerConfig? = nil) {
        if let initial {
            self.storage[ServerID()] = initial
        }
    }

    public func load() async throws -> IOSServerConfig? {
        storage.values.sorted(by: { $0.displayName < $1.displayName }).first
    }

    public func save(_ config: IOSServerConfig) async throws {
        // Singleton save: replace the primary entry (or create one
        // if the list is empty). Never grows the list unexpectedly.
        if let primaryID = storage.keys.sorted(by: { ($0.uuidString) < ($1.uuidString) }).first {
            storage[primaryID] = config
        } else {
            storage[ServerID()] = config
        }
    }

    public func delete() async throws { storage.removeAll() }

    public func listAll() async throws -> [ServerID: IOSServerConfig] { storage }

    public func load(id: ServerID) async throws -> IOSServerConfig? { storage[id] }

    public func save(_ config: IOSServerConfig, id: ServerID) async throws {
        storage[id] = config
    }

    public func delete(id: ServerID) async throws {
        storage.removeValue(forKey: id)
    }
}
