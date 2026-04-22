import Foundation
import Security
import os

/// Thin wrapper around the macOS Keychain for template-config secrets.
/// Scarf doesn't have other Keychain users yet so this file is the one
/// place that touches the `Security` framework; keep it small and
/// auditable so a reader can tell at a glance what we store, under what
/// identifiers, and when items are removed.
///
/// **What we store.** Generic passwords (kSecClassGenericPassword) in
/// the login Keychain. Each item is identified by a (service, account)
/// pair derived from the template slug + field key + project-path hash
/// — see `TemplateKeychainRef.make`. The stored Data is the user's
/// raw secret bytes; we never transform or encode them.
///
/// **When items are written.** By `ProjectTemplateInstaller` after the
/// install preview is confirmed and the user has filled in the
/// configure sheet. By `TemplateConfigSheet` when the user edits a
/// secret field post-install.
///
/// **When items are removed.** By `ProjectTemplateUninstaller`,
/// iterating the lock file's `configKeychainItems` list. The login
/// Keychain is never swept for stray entries — if the lock is out of
/// sync we log + skip rather than guess which items are ours.
///
/// **What shows to the user.** macOS prompts "Scarf wants to access
/// the Keychain" the first time we read a secret in a given session.
/// User approves; subsequent reads in that session are silent. We
/// never bypass this — the prompt is the user's trust boundary.
struct ProjectConfigKeychain: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectConfigKeychain")

    /// Which Keychain to target. The default is the login Keychain
    /// (`nil` uses the user's default chain). Tests pass an explicit
    /// namespace suffix via `testServiceSuffix` — see `TemplateConfigTests` —
    /// so integration tests can roundtrip without polluting real
    /// user state.
    let testServiceSuffix: String?

    nonisolated init(testServiceSuffix: String? = nil) {
        self.testServiceSuffix = testServiceSuffix
    }

    /// Write or overwrite the secret for (service, account). Tests
    /// route their items through a distinct service prefix via
    /// `testServiceSuffix` so they can't leak into the user's real
    /// Keychain.
    nonisolated func set(service: String, account: String, secret: Data) throws {
        let svc = resolved(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
        ]
        // Try update first — cheaper than delete-then-add and doesn't
        // trip macOS's "item already exists" if another thread raced us.
        let update: [String: Any] = [
            kSecValueData as String: secret,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw Self.error(status: updateStatus, op: "update")
        }
        var insert = query
        insert[kSecValueData as String] = secret
        // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly — stays in
        // this device's Keychain, not synced via iCloud, usable after
        // first unlock (so background cron triggers can read).
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw Self.error(status: addStatus, op: "add")
        }
    }

    /// Retrieve the secret for (service, account). Returns `nil` when
    /// the item simply doesn't exist (user never set it, or an
    /// uninstall already removed it). Throws on every other Keychain
    /// error so callers don't silently treat "access denied" or
    /// "corrupt keychain" as "no value."
    nonisolated func get(service: String, account: String) throws -> Data? {
        let svc = resolved(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            throw Self.error(status: status, op: "get")
        }
        return result as? Data
    }

    /// Delete the secret for (service, account). Absent item is a
    /// no-op; any other failure throws. Called by
    /// `ProjectTemplateUninstaller` for every item in
    /// `TemplateLock.configKeychainItems`.
    nonisolated func delete(service: String, account: String) throws {
        let svc = resolved(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess { return }
        throw Self.error(status: status, op: "delete")
    }

    /// Convenience: apply the test suffix when in test mode.
    nonisolated private func resolved(service: String) -> String {
        guard let suffix = testServiceSuffix, !suffix.isEmpty else { return service }
        return "\(service).\(suffix)"
    }

    /// Build a useful NSError from a Keychain OSStatus. Logs at warning
    /// — callers decide whether the failure is fatal.
    nonisolated private static func error(status: OSStatus, op: String) -> NSError {
        let description = (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error"
        logger.warning("Keychain \(op, privacy: .public) failed: \(status) \(description, privacy: .public)")
        return NSError(
            domain: "com.scarf.keychain",
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Keychain \(op) failed (\(status)): \(description)"
            ]
        )
    }
}

// MARK: - Ref-shaped convenience layer

extension ProjectConfigKeychain {
    /// Set a secret using a pre-built `TemplateKeychainRef`. Mirrors the
    /// service/account plumbing every caller would otherwise repeat.
    nonisolated func set(ref: TemplateKeychainRef, secret: Data) throws {
        try set(service: ref.service, account: ref.account, secret: secret)
    }

    nonisolated func get(ref: TemplateKeychainRef) throws -> Data? {
        try get(service: ref.service, account: ref.account)
    }

    nonisolated func delete(ref: TemplateKeychainRef) throws {
        try delete(service: ref.service, account: ref.account)
    }
}
