import Foundation
import ScarfCore
import CryptoKit
#if canImport(os)
import os
#endif

// MARK: - Host-key pinning (trust on first use)
//
// ScarfGo's answer to the Mac's `StrictHostKeyChecking=accept-new`
// (`ScarfCore/Transport/SSHTransport.swift`). Every Citadel connect funnel
// validates the server's host key through `PinnedHostKeyValidator`
// (`PinnedHostKeyValidator.swift`), which consults this store:
//
//   - no pin for the endpoint  → pin the presented key silently, connect
//     (first connect, including servers paired before pinning shipped);
//   - pinned key presented     → connect;
//   - a different key          → refuse with `HostKeyMismatchError`, and
//     remember the presented key as `rejected` so the server's System tab
//     can offer a deliberate, confirmed "Trust new key".
//
// **Identity is the SSH endpoint (host + port), not the ServerID.** The
// runtime connections never see the entry's ServerID: every feature view
// builds its `ServerContext` under a fixed per-view context id
// (`ChatView.sharedContextID`, `ScarfGoTabRoot.systemTabContextID`, …), and
// onboarding's Test Connection runs before the entry exists. The endpoint is
// what a host key actually belongs to — OpenSSH's known_hosts keys on it the
// same way — so two entries for one machine (different users) share one pin,
// and an entry re-onboarded at a new host or port starts a fresh pin.
// `RootModel` prunes pins whose endpoint no server entry uses any more
// (forget, sign-out, app launch).
//
// Host keys are public, so this lives in UserDefaults beside the server
// list (`com.scarf.ios.servers.v2`), not in the Keychain.

/// The SSH endpoint a host key is pinned to. `host` is lowercased (OpenSSH
/// matches host names case-insensitively); a nil port is 22.
public struct HostKeyEndpoint: Hashable, Codable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int?) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port ?? 22
    }

    /// The known_hosts spelling: `host` on port 22, `[host]:port` otherwise.
    /// Also the storage key.
    public var storageKey: String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// For people: `host`, or `host:port` off the default port.
    public var displayName: String {
        port == 22 ? host : "\(host):\(port)"
    }
}

public extension IOSServerConfig {
    /// The endpoint this entry's host key is pinned under.
    var hostKeyEndpoint: HostKeyEndpoint { HostKeyEndpoint(host: host, port: port) }
}

/// A host key as ScarfGo stores it: the OpenSSH public-key line
/// (`algorithm base64`, no comment) and its OpenSSH-style SHA-256
/// fingerprint (`SHA256:…`, unpadded base64, what `ssh-keygen -lf` prints).
public struct HostKeyFingerprint: Hashable, Codable, Sendable {
    public let openSSHKey: String
    public let fingerprint: String
    /// When ScarfGo first saw (pinned) or was last presented (rejected) this key.
    public let seenAt: Date

    public init(openSSHKey: String, seenAt: Date = Date()) throws {
        let normalized = try Self.normalize(openSSHKey)
        self.openSSHKey = normalized.line
        self.fingerprint = Self.sha256Fingerprint(blob: normalized.blob)
        self.seenAt = seenAt
    }

    /// The key algorithm, e.g. `ssh-ed25519`.
    public var algorithm: String {
        String(openSSHKey.split(separator: " ").first ?? "")
    }

    /// `SHA256:<unpadded base64 of SHA-256(key blob)>` — byte-identical to
    /// OpenSSH's default fingerprint for an `algorithm base64 [comment]` line.
    public static func sha256Fingerprint(openSSHKey: String) throws -> String {
        sha256Fingerprint(blob: try normalize(openSSHKey).blob)
    }

    static func sha256Fingerprint(blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob))
        var b64 = digest.base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:" + b64
    }

    /// Split an OpenSSH public-key line into `algorithm base64` (comment
    /// dropped) and the decoded key blob.
    static func normalize(_ line: String) throws -> (line: String, blob: Data) {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])), !blob.isEmpty else {
            throw HostKeyFormatError.unparseable
        }
        return ("\(parts[0]) \(parts[1])", blob)
    }
}

public enum HostKeyFormatError: Error, Sendable {
    case unparseable
}

/// What ScarfGo knows about one endpoint's host key.
public struct HostKeyRecord: Codable, Sendable, Equatable {
    public var endpoint: HostKeyEndpoint
    /// The trusted key. Connections succeed only when the server presents it.
    public var pinned: HostKeyFingerprint
    /// The most recent DIFFERENT key the server presented (and ScarfGo
    /// refused). `nil` when there is no unresolved identity change.
    public var rejected: HostKeyFingerprint?

    public init(endpoint: HostKeyEndpoint, pinned: HostKeyFingerprint, rejected: HostKeyFingerprint? = nil) {
        self.endpoint = endpoint
        self.pinned = pinned
        self.rejected = rejected
    }
}

/// The server presented a host key that doesn't match the pinned one.
/// Connections to the endpoint stay refused until the user re-trusts it.
public struct HostKeyMismatchError: Error, LocalizedError, Sendable, Equatable {
    public let endpoint: HostKeyEndpoint
    /// Fingerprint of the key ScarfGo trusts (`SHA256:…`).
    public let expectedFingerprint: String
    /// Fingerprint of the key the server just presented (`SHA256:…`).
    public let presentedFingerprint: String

    public init(endpoint: HostKeyEndpoint, expectedFingerprint: String, presentedFingerprint: String) {
        self.endpoint = endpoint
        self.expectedFingerprint = expectedFingerprint
        self.presentedFingerprint = presentedFingerprint
    }

    public var errorDescription: String? {
        String(
            localized: "Server identity changed for \(endpoint.displayName). ScarfGo didn’t connect because the server presented a different host key than the one it trusted before. This happens when a server is reinstalled or its SSH keys are regenerated, but it can also mean someone is intercepting the connection. Trusted key: \(expectedFingerprint). Presented key: \(presentedFingerprint). If you expected this change, open this server’s System tab and choose Trust New Key.",
            comment: "Connection error when an SSH server's host key no longer matches the pinned one. 1: host or host:port. 2: trusted fingerprint. 3: presented fingerprint (both SHA256:…)."
        )
    }
}

/// The outcome of checking a presented host key against the pin.
public enum HostKeyEvaluation: Sendable, Equatable {
    /// No pin existed; the presented key is now pinned.
    case pinnedOnFirstUse(HostKeyFingerprint)
    /// The presented key is the pinned one.
    case matched
    /// The presented key differs; it was recorded as `rejected`.
    case mismatch(HostKeyMismatchError)
}

/// Thread-safe, UserDefaults-backed host-key pins, keyed by
/// `HostKeyEndpoint.storageKey`.
///
/// Synchronous on purpose: `PinnedHostKeyValidator` is called on a NIO event
/// loop and must answer its promise without hopping to an actor. Each call is
/// one small JSON read (and at most one write) under a lock — no I/O beyond
/// UserDefaults' own in-memory cache, so it never stalls the loop. UI callers
/// on the main actor should still use the `async` wrappers (`Task.detached`)
/// so the main actor never waits on a lock held by an event loop.
///
/// No in-memory cache: every call reads UserDefaults, so two instances over
/// the same defaults key (the app's `.shared` and a test's) stay coherent.
public final class HostKeyPinStore: @unchecked Sendable {
    public static let defaultDefaultsKey = "com.scarf.ios.host-key-pins.v1"
    /// Posted (on an arbitrary thread) after any change. `object` is the store.
    public static let didChangeNotification = Notification.Name("com.scarf.ios.hostKeyPinsDidChange")

    /// The app-wide store every production connect funnel uses.
    public static let shared = HostKeyPinStore()

    private let defaults: any HostKeyPinBacking
    private let key: String
    private let lock = NSLock()

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "HostKeyPinStore")
    #endif

    public init(defaults: UserDefaults = .standard, key: String = HostKeyPinStore.defaultDefaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Over any key-value backing — tests pass `InMemoryHostKeyPinBacking`
    /// so they never create a UserDefaults suite (each one leaves a plist in
    /// `~/Library/Preferences` that cfprefsd won't remove).
    public init(backing: any HostKeyPinBacking, key: String = HostKeyPinStore.defaultDefaultsKey) {
        self.defaults = backing
        self.key = key
    }

    // MARK: Reads

    public func record(for endpoint: HostKeyEndpoint) -> HostKeyRecord? {
        lock.withLock { readAll()[endpoint.storageKey] }
    }

    public func allRecords() -> [HostKeyRecord] {
        lock.withLock { Array(readAll().values) }
    }

    // MARK: The validator's decision

    /// Check `presentedOpenSSHKey` against the endpoint's pin, pinning it on
    /// first use and recording it as `rejected` on a mismatch. Atomic: two
    /// concurrent first connects can't both pin different keys.
    public func evaluate(presentedOpenSSHKey: String, for endpoint: HostKeyEndpoint) throws -> HostKeyEvaluation {
        let presented = try HostKeyFingerprint(openSSHKey: presentedOpenSSHKey)
        let result: HostKeyEvaluation = lock.withLock {
            var all = readAll()
            guard var record = all[endpoint.storageKey] else {
                all[endpoint.storageKey] = HostKeyRecord(endpoint: endpoint, pinned: presented)
                writeAll(all)
                return .pinnedOnFirstUse(presented)
            }
            if record.pinned.openSSHKey == presented.openSSHKey {
                // The server is back on its trusted key; an earlier
                // rejection is no longer an open question.
                if record.rejected != nil {
                    record.rejected = nil
                    all[endpoint.storageKey] = record
                    writeAll(all)
                }
                return .matched
            }
            if record.rejected?.openSSHKey != presented.openSSHKey {
                record.rejected = presented
                all[endpoint.storageKey] = record
                writeAll(all)
            }
            return .mismatch(HostKeyMismatchError(
                endpoint: endpoint,
                expectedFingerprint: record.pinned.fingerprint,
                presentedFingerprint: presented.fingerprint
            ))
        }
        if case .matched = result {} else { postChange() }
        return result
    }

    // MARK: Writes

    /// Replace the pin with the key the server presented in its last refused
    /// connection — the "Trust new key" action. Only that exact key is
    /// trusted: pass the fingerprint the user was shown, and if the server
    /// has since presented yet another key, nothing changes and this
    /// returns `false` (the UI re-reads and shows the newer one).
    @discardableResult
    public func trustRejectedKey(for endpoint: HostKeyEndpoint, expectedFingerprint: String) -> Bool {
        let changed: Bool = lock.withLock {
            var all = readAll()
            guard var record = all[endpoint.storageKey],
                  let rejected = record.rejected,
                  rejected.fingerprint == expectedFingerprint else { return false }
            record.pinned = HostKeyFingerprint(rebasing: rejected, seenAt: Date())
            record.rejected = nil
            all[endpoint.storageKey] = record
            writeAll(all)
            return true
        }
        if changed { postChange() }
        return changed
    }

    /// Pin `openSSHKey` for `endpoint` outright, replacing any pin.
    public func pin(openSSHKey: String, for endpoint: HostKeyEndpoint) throws {
        let key = try HostKeyFingerprint(openSSHKey: openSSHKey)
        lock.withLock {
            var all = readAll()
            all[endpoint.storageKey] = HostKeyRecord(endpoint: endpoint, pinned: key)
            writeAll(all)
        }
        postChange()
    }

    /// Forget the endpoint's pin; the next connect pins afresh.
    public func remove(_ endpoint: HostKeyEndpoint) {
        let changed: Bool = lock.withLock {
            var all = readAll()
            guard all.removeValue(forKey: endpoint.storageKey) != nil else { return false }
            writeAll(all)
            return true
        }
        if changed { postChange() }
    }

    /// Drop every pin whose endpoint is not in `endpoints` — called with the
    /// endpoints of the remaining server entries after a forget, at launch,
    /// and after onboarding (a re-onboarded entry at a new host or port
    /// leaves its old endpoint's pin behind).
    public func prune(keeping endpoints: Set<HostKeyEndpoint>) {
        let keep = Set(endpoints.map(\.storageKey))
        let changed: Bool = lock.withLock {
            let all = readAll()
            let kept = all.filter { keep.contains($0.key) }
            guard kept.count != all.count else { return false }
            writeAll(kept)
            return true
        }
        if changed { postChange() }
    }

    public func removeAll() {
        lock.withLock { defaults.removeObject(forKey: key) }
        postChange()
    }

    // MARK: Async wrappers for the main actor

    public func recordOffMain(for endpoint: HostKeyEndpoint) async -> HostKeyRecord? {
        await Task.detached { self.record(for: endpoint) }.value
    }

    public func allRecordsOffMain() async -> [HostKeyRecord] {
        await Task.detached { self.allRecords() }.value
    }

    public func trustRejectedKeyOffMain(for endpoint: HostKeyEndpoint, expectedFingerprint: String) async -> Bool {
        await Task.detached {
            self.trustRejectedKey(for: endpoint, expectedFingerprint: expectedFingerprint)
        }.value
    }

    public func pruneOffMain(keeping endpoints: Set<HostKeyEndpoint>) async {
        await Task.detached { self.prune(keeping: endpoints) }.value
    }

    public func removeAllOffMain() async {
        await Task.detached { self.removeAll() }.value
    }

    // MARK: Storage (call with `lock` held)

    /// Decoded per record, so one damaged entry doesn't drop the others.
    /// Anything undecodable is first copied, byte for byte, to
    /// `<key>.corrupt-<unix time>` (never overwritten, for diagnosis), and
    /// the store is rewritten with what survived so later reads are clean.
    /// A dropped entry pins afresh on its next connect (trust on first use
    /// again) — the same exposure as a server never connected before.
    private func readAll() -> [String: HostKeyRecord] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            quarantine(data, reason: "not a JSON object")
            defaults.removeObject(forKey: key)
            return [:]
        }
        let decoder = JSONDecoder()
        var records: [String: HostKeyRecord] = [:]
        var dropped: [String] = []
        for (storageKey, value) in raw {
            if let entry = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
               let record = try? decoder.decode(HostKeyRecord.self, from: entry) {
                records[storageKey] = record
            } else {
                dropped.append(storageKey)
            }
        }
        if !dropped.isEmpty {
            quarantine(data, reason: "\(dropped.count) undecodable record(s)")
            writeAll(records)
        }
        return records
    }

    /// The key a damaged blob is backed up under.
    public var corruptBackupKeyPrefix: String { key + ".corrupt-" }

    private func quarantine(_ data: Data, reason: String) {
        var backupKey = corruptBackupKeyPrefix + String(Int(Date().timeIntervalSince1970))
        var n = 1
        while defaults.object(forKey: backupKey) != nil {
            n += 1
            backupKey = corruptBackupKeyPrefix + String(Int(Date().timeIntervalSince1970)) + "-\(n)"
        }
        defaults.set(data, forKey: backupKey)
        #if canImport(os)
        Self.logger.error("Host-key pins partly unreadable (\(reason, privacy: .public)); original kept under \(backupKey, privacy: .public)")
        #endif
    }

    private func writeAll(_ all: [String: HostKeyRecord]) {
        if all.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

extension HostKeyFingerprint {
    /// Same key, new timestamp (re-trusting a rejected key pins it "now").
    init(rebasing other: HostKeyFingerprint, seenAt: Date) {
        self.openSSHKey = other.openSSHKey
        self.fingerprint = other.fingerprint
        self.seenAt = seenAt
    }
}

/// The few UserDefaults calls `HostKeyPinStore` makes. Implementations must
/// be thread-safe (the store calls them under its own lock, from any thread).
public protocol HostKeyPinBacking: AnyObject {
    func data(forKey key: String) -> Data?
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: HostKeyPinBacking {}

/// Process-lifetime backing for tests and previews. Two stores over the same
/// instance behave like two launches over the same UserDefaults.
public final class InMemoryHostKeyPinBacking: HostKeyPinBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? { lock.withLock { values[key] as? Data } }
    public func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    public func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    public func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
    public var allKeys: [String] { lock.withLock { Array(values.keys) } }
}
