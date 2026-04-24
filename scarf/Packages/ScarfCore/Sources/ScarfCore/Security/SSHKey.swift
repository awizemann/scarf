import Foundation

/// A single SSH keypair used to authenticate to a remote Hermes host.
///
/// **Why this lives in ScarfCore** (and not in the iOS package):
/// Keys are persisted by both the onboarding flow (iOS) and any future
/// test-harness or macOS companion. The *storage backend* is
/// platform-specific (iOS Keychain for the iPhone app, files or macOS
/// Keychain for future Mac use), but the value type is plain data.
public struct SSHKeyBundle: Sendable, Hashable, Codable {
    /// PEM-encoded OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----…`).
    /// Treat as sensitive — callers should keep it in secure storage and
    /// never log it, serialize it to disk unencrypted, or hand it to
    /// non-ScarfCore code.
    public var privateKeyPEM: String
    /// OpenSSH-format public key (`ssh-ed25519 AAAA… comment`). Suitable
    /// for copy-pasting into `~/.ssh/authorized_keys` on the remote.
    public var publicKeyOpenSSH: String
    /// Public-key comment — typically `"scarf-iphone-<uuid>"` or a
    /// user-chosen label. Surfaced in `authorized_keys` so the user
    /// can identify which device the key belongs to.
    public var comment: String
    /// ISO8601 timestamp string captured when the key was first minted
    /// or imported. Used by the UI to show "created 3 days ago".
    public var createdAt: String

    public init(
        privateKeyPEM: String,
        publicKeyOpenSSH: String,
        comment: String,
        createdAt: String
    ) {
        self.privateKeyPEM = privateKeyPEM
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.comment = comment
        self.createdAt = createdAt
    }

    /// Short display string with just the algorithm + a truncated
    /// fingerprint-shaped suffix. Safe to log.
    public var displayFingerprint: String {
        let parts = publicKeyOpenSSH.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return "ssh-key" }
        let algo = String(parts[0])
        let keyBody = String(parts[1])
        let prefix = keyBody.prefix(10)
        let suffix = keyBody.suffix(10)
        return "\(algo) \(prefix)…\(suffix)"
    }
}

/// Async-safe key storage contract.
///
/// Singleton API (`load()` / `save(_:)` / `delete()`) persists here
/// for the v1 single-server callers. M9 added the `ServerID`-keyed
/// variants so we can hold a key per configured server; singleton
/// semantics remain for the "primary" slot (first key when the list
/// is populated).
public protocol SSHKeyStore: Sendable {
    // MARK: - Singleton API (compat)

    /// Returns the primary stored key, or `nil` if the store is empty.
    /// In a multi-server world this picks the first key by stable
    /// ordering; callers with specific server context should prefer
    /// `load(for:)`.
    func load() async throws -> SSHKeyBundle?

    /// Overwrites the primary key. Does not affect other stored keys
    /// (M9 multi-server). Idempotent.
    func save(_ bundle: SSHKeyBundle) async throws

    /// Deletes ALL stored keys across every ServerID slot. Matches
    /// the v1 "forget" semantics.
    func delete() async throws

    // MARK: - Multi-server API (M9)

    /// Return the ids for every server with a stored key. Empty on
    /// fresh install.
    func listAll() async throws -> [ServerID]

    /// Load the key stored for the given server id, or nil if absent.
    func load(for id: ServerID) async throws -> SSHKeyBundle?

    /// Save or replace the key for the given server id. Leaves other
    /// servers' keys untouched.
    func save(_ bundle: SSHKeyBundle, for id: ServerID) async throws

    /// Remove the key for a specific server id. No-op if absent.
    func delete(for id: ServerID) async throws
}

/// Errors raised by `SSHKeyStore` implementations when the backing
/// store (Keychain, file) fails. Clients typically surface
/// `errorDescription` and prompt the user to reset onboarding.
public enum SSHKeyStoreError: Error, LocalizedError {
    /// The store contains data but it failed to decode as an
    /// `SSHKeyBundle`. Usually means a schema drift between app
    /// versions — the fix is to delete and re-onboard.
    case decodeFailed(String)
    /// The Keychain / filesystem returned an error. `osStatus` is
    /// non-nil on iOS when Security.framework returns an OSStatus.
    case backendFailure(message: String, osStatus: Int32?)

    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let msg): return "Stored SSH key is corrupted: \(msg)"
        case .backendFailure(let msg, let status):
            if let status { return "\(msg) (OSStatus \(status))" }
            return msg
        }
    }
}

/// Process-lifetime in-memory key store. Intended for tests and
/// previews — never for production. Thread-safe via an internal actor.
public actor InMemorySSHKeyStore: SSHKeyStore {
    private var bundles: [ServerID: SSHKeyBundle] = [:]

    public init(initial: SSHKeyBundle? = nil) {
        if let initial {
            self.bundles[ServerID()] = initial
        }
    }

    public func load() async throws -> SSHKeyBundle? {
        guard let id = bundles.keys.sorted(by: { $0.uuidString < $1.uuidString }).first else {
            return nil
        }
        return bundles[id]
    }

    public func save(_ bundle: SSHKeyBundle) async throws {
        if let primaryID = bundles.keys.sorted(by: { $0.uuidString < $1.uuidString }).first {
            bundles[primaryID] = bundle
        } else {
            bundles[ServerID()] = bundle
        }
    }

    public func delete() async throws { bundles.removeAll() }

    public func listAll() async throws -> [ServerID] {
        Array(bundles.keys)
    }

    public func load(for id: ServerID) async throws -> SSHKeyBundle? {
        bundles[id]
    }

    public func save(_ bundle: SSHKeyBundle, for id: ServerID) async throws {
        bundles[id] = bundle
    }

    public func delete(for id: ServerID) async throws {
        bundles.removeValue(forKey: id)
    }
}
