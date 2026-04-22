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

/// Async-safe key storage contract. iOS implements this with the
/// Keychain; tests use `InMemorySSHKeyStore`.
///
/// Single-key storage is intentional: v1 of the iOS app binds one SSH
/// key to one Hermes server. Multi-key / multi-server comes later.
public protocol SSHKeyStore: Sendable {
    /// Returns the stored key bundle, or `nil` if the store is empty.
    /// Callers should prompt the onboarding flow when this is `nil`.
    func load() async throws -> SSHKeyBundle?

    /// Overwrites any existing key with `bundle`. Idempotent.
    func save(_ bundle: SSHKeyBundle) async throws

    /// Deletes the stored key. No-op if the store is empty.
    func delete() async throws
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
    private var bundle: SSHKeyBundle?

    public init(initial: SSHKeyBundle? = nil) {
        self.bundle = initial
    }

    public func load() async throws -> SSHKeyBundle? { bundle }
    public func save(_ bundle: SSHKeyBundle) async throws { self.bundle = bundle }
    public func delete() async throws { bundle = nil }
}
