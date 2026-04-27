// KeychainSSHKeyStore is Apple-only — iOS Keychain APIs (kSec*) live
// in Security.framework which ships in the Apple SDKs. On Linux the
// whole file is skipped; tests use ScarfCore's InMemorySSHKeyStore.
#if canImport(Security)

import Foundation
import Security
import ScarfCore

/// iOS Keychain-backed implementation of `SSHKeyStore`.
///
/// Storage shape:
/// - v1 (single-key): one generic-password item with `kSecAttrAccount = "primary"`.
///   Shipped in M2.
/// - v2 (multi-key, M9): one generic-password item per configured
///   server, with `kSecAttrAccount = "server-key:<UUID>"`. New saves
///   go here; v1 item is migrated into v2 on first `listAll()` after
///   the upgrade, then removed.
///
/// **Accessibility / sync attributes.** Default behavior pins items
/// to this device with `kSecAttrAccessibleAfterFirstUnlockThisDevice
/// Only` + `kSecAttrSynchronizable=false`. Users can opt into iCloud
/// Keychain sync via `SSHKeyICloudPreference` (issue #52); when
/// enabled, writes use `kSecAttrAccessibleAfterFirstUnlock` (no
/// `ThisDeviceOnly` suffix) + `kSecAttrSynchronizable=true` so the
/// key is picked up by iCloud Keychain on every signed-in device.
///
/// All read / list / delete queries pass `kSecAttrSynchronizable =
/// kSecAttrSynchronizableAny` so they match items regardless of
/// sync state — load-bearing during the migration window when
/// device-only and synced items can briefly coexist.
public struct KeychainSSHKeyStore: SSHKeyStore {
    public static let defaultService = "com.scarf.ssh-key"
    public static let legacyV1Account = "primary"
    public static let multiAccountPrefix = "server-key:"

    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    // MARK: - Singleton API (compat)

    public func load() async throws -> SSHKeyBundle? {
        // Migrate first so the post-migration listAll path sees the
        // single v1 entry, if any.
        migrateLegacyIfNeeded()
        let ids = try await listAll()
        guard let first = ids.sorted(by: { $0.uuidString < $1.uuidString }).first else {
            // No v2 entries; try legacy in case migration lost the race.
            return try readLegacy()
        }
        return try await load(for: first)
    }

    public func save(_ bundle: SSHKeyBundle) async throws {
        let ids = try await listAll()
        if let primaryID = ids.sorted(by: { $0.uuidString < $1.uuidString }).first {
            try await save(bundle, for: primaryID)
        } else {
            try await save(bundle, for: ServerID())
        }
    }

    public func delete() async throws {
        // Wipe every v2 entry + the legacy v1 entry. Single-query delete
        // that matches any account under our service. Pass `Any` so the
        // wipe catches synced + device-only items uniformly (issue #52).
        let query: [String: Any] = [
            kSecClass as String:                   kSecClassGenericPassword,
            kSecAttrService as String:             service,
            kSecAttrSynchronizable as String:      kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SSHKeyStoreError.backendFailure(
                message: "Keychain wipe failed", osStatus: status
            )
        }
    }

    // MARK: - Multi-server API

    public func listAll() async throws -> [ServerID] {
        migrateLegacyIfNeeded()
        let query: [String: Any] = [
            kSecClass as String:                   kSecClassGenericPassword,
            kSecAttrService as String:             service,
            kSecReturnAttributes as String:        true,
            kSecMatchLimit as String:              kSecMatchLimitAll,
            // Match items regardless of sync state (issue #52). Without
            // this the listing silently misses synced items.
            kSecAttrSynchronizable as String:      kSecAttrSynchronizableAny,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            guard let array = items as? [[String: Any]] else { return [] }
            var ids: [ServerID] = []
            for entry in array {
                guard let account = entry[kSecAttrAccount as String] as? String,
                      account.hasPrefix(Self.multiAccountPrefix) else { continue }
                let idString = String(account.dropFirst(Self.multiAccountPrefix.count))
                if let uuid = UUID(uuidString: idString) {
                    ids.append(uuid)
                }
            }
            return ids
        case errSecItemNotFound:
            return []
        default:
            throw SSHKeyStoreError.backendFailure(
                message: "Keychain list failed", osStatus: status
            )
        }
    }

    public func load(for id: ServerID) async throws -> SSHKeyBundle? {
        try readBundle(account: Self.multiAccountPrefix + id.uuidString)
    }

    public func save(_ bundle: SSHKeyBundle, for id: ServerID) async throws {
        try writeBundle(bundle, account: Self.multiAccountPrefix + id.uuidString)
    }

    public func delete(for id: ServerID) async throws {
        try deleteBundle(account: Self.multiAccountPrefix + id.uuidString)
    }

    // MARK: - iCloud sync migration (issue #52)

    /// Migrate every stored key bundle to the requested sync state and
    /// persist the user's preference for future writes.
    ///
    /// Idempotent: if the user enables sync twice in a row the second
    /// call simply re-saves with the same attributes. Safe to call
    /// from a UI toggle handler. Errors thrown by individual key
    /// re-writes propagate; partial migrations are tolerable because
    /// the read paths use `kSecAttrSynchronizableAny` and pick up
    /// either copy on the next read.
    ///
    /// Side effects:
    /// - Each stored key is read with `Any`, deleted with `Any`, then
    ///   re-saved with the target sync attributes via `writeBundle(_:account:syncToICloud:)`.
    /// - The legacy v1 entry (if present) is migrated to the v2 layout
    ///   with the new attributes in passing.
    /// - `SSHKeyICloudPreference.isEnabled` is set BEFORE the rewrite
    ///   loop so any concurrent `save(_:)` call from another path
    ///   already uses the right attributes.
    public func migrateAllItems(toICloudSync enabled: Bool) async throws {
        SSHKeyICloudPreference.isEnabled = enabled

        // Pull every v2 + v1 bundle into memory first. We can't iterate
        // and rewrite simultaneously: deleting an item we're about to
        // re-add would race with the listing query.
        var bundles: [(account: String, bundle: SSHKeyBundle)] = []
        for id in try await listAll() {
            if let bundle = try await load(for: id) {
                bundles.append((Self.multiAccountPrefix + id.uuidString, bundle))
            }
        }
        if let legacy = try? readLegacy() {
            bundles.append((Self.legacyV1Account, legacy))
        }

        for (account, bundle) in bundles {
            try writeBundle(bundle, account: account, syncToICloud: enabled)
        }
    }

    // MARK: - Private — Keychain plumbing per-account

    private func readBundle(account: String) throws -> SSHKeyBundle? {
        let query: [String: Any] = [
            kSecClass as String:                   kSecClassGenericPassword,
            kSecAttrService as String:             service,
            kSecAttrAccount as String:             account,
            kSecReturnData as String:              true,
            kSecMatchLimit as String:              kSecMatchLimitOne,
            // Match items regardless of sync state (issue #52). Without
            // this the query implicitly defaults to false and orphans
            // any items that have been migrated to iCloud sync.
            kSecAttrSynchronizable as String:      kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw SSHKeyStoreError.backendFailure(
                    message: "Keychain returned non-Data value", osStatus: status
                )
            }
            do {
                return try JSONDecoder().decode(SSHKeyBundle.self, from: data)
            } catch {
                throw SSHKeyStoreError.decodeFailed(error.localizedDescription)
            }
        case errSecItemNotFound:
            return nil
        default:
            throw SSHKeyStoreError.backendFailure(
                message: "Keychain read failed", osStatus: status
            )
        }
    }

    private func writeBundle(_ bundle: SSHKeyBundle, account: String) throws {
        try writeBundle(bundle, account: account, syncToICloud: SSHKeyICloudPreference.isEnabled)
    }

    /// Write path with explicit sync control. Used by the public
    /// migration helper to force a target sync state regardless of
    /// the current preference.
    private func writeBundle(_ bundle: SSHKeyBundle, account: String, syncToICloud: Bool) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(bundle)
        } catch {
            throw SSHKeyStoreError.backendFailure(
                message: "Encode failed: \(error.localizedDescription)", osStatus: nil
            )
        }
        // Delete with kSecAttrSynchronizableAny to clear out any prior
        // copy regardless of its sync state — without this a flip from
        // synced → device-only could leave the synced copy behind and
        // create two competing items at the same (service, account).
        let deleteQuery: [String: Any] = [
            kSecClass as String:                   kSecClassGenericPassword,
            kSecAttrService as String:             service,
            kSecAttrAccount as String:             account,
            kSecAttrSynchronizable as String:      kSecAttrSynchronizableAny,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var attributes: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        attributes[kSecValueData as String] = data
        if syncToICloud {
            // iCloud Keychain requires the non-`ThisDeviceOnly` accessible
            // class — items with the `ThisDeviceOnly` suffix are silently
            // skipped by the sync engine.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        }

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SSHKeyStoreError.backendFailure(
                message: "Keychain write failed", osStatus: addStatus
            )
        }
    }

    private func deleteBundle(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:                   kSecClassGenericPassword,
            kSecAttrService as String:             service,
            kSecAttrAccount as String:             account,
            kSecAttrSynchronizable as String:      kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SSHKeyStoreError.backendFailure(
                message: "Keychain delete failed", osStatus: status
            )
        }
    }

    /// Read the v1 legacy entry (if any). Separate from `readBundle`
    /// so we can call it at the bottom of `load()` as a belt-and-
    /// braces fallback when migration hasn't happened yet.
    private func readLegacy() throws -> SSHKeyBundle? {
        try readBundle(account: Self.legacyV1Account)
    }

    /// One-shot v1 → v2 migration. If the legacy `"primary"` account
    /// exists and no v2 accounts do, copy the legacy key to a fresh
    /// ServerID-keyed slot and delete the legacy item. Idempotent —
    /// once v1 is gone subsequent calls are no-ops.
    private func migrateLegacyIfNeeded() {
        let hasV2 = (try? listAllInternal(skipMigration: true)) ?? []
        guard hasV2.isEmpty,
              let legacy = try? readLegacy()
        else { return }
        let freshID = ServerID()
        try? writeBundle(legacy, account: Self.multiAccountPrefix + freshID.uuidString)
        try? deleteBundle(account: Self.legacyV1Account)
    }

    /// `listAll()` but without the migration call. Internal so the
    /// migration routine can check whether v2 is empty without
    /// triggering a recursive migration.
    private func listAllInternal(skipMigration: Bool) throws -> [ServerID] {
        let query: [String: Any] = [
            kSecClass as String:                   kSecClassGenericPassword,
            kSecAttrService as String:             service,
            kSecReturnAttributes as String:        true,
            kSecMatchLimit as String:              kSecMatchLimitAll,
            // Match items regardless of sync state (issue #52). Without
            // this the listing silently misses synced items.
            kSecAttrSynchronizable as String:      kSecAttrSynchronizableAny,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            guard let array = items as? [[String: Any]] else { return [] }
            var ids: [ServerID] = []
            for entry in array {
                guard let account = entry[kSecAttrAccount as String] as? String,
                      account.hasPrefix(Self.multiAccountPrefix) else { continue }
                let idString = String(account.dropFirst(Self.multiAccountPrefix.count))
                if let uuid = UUID(uuidString: idString) {
                    ids.append(uuid)
                }
            }
            return ids
        case errSecItemNotFound:
            return []
        default:
            return []
        }
    }
}

#endif // canImport(Security)
