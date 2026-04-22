// KeychainSSHKeyStore is Apple-only — iOS Keychain APIs (kSec*) live
// in Security.framework which ships in the Apple SDKs. On Linux the
// whole file is skipped; tests use ScarfCore's InMemorySSHKeyStore.
#if canImport(Security)

import Foundation
import Security
import ScarfCore

/// iOS Keychain-backed implementation of `SSHKeyStore`. Stores the
/// JSON-encoded `SSHKeyBundle` as a generic password item tagged
/// with a Scarf-specific service + account.
///
/// **Accessibility**: We use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// so the key:
///   - is readable any time after the user unlocks the device once
///     (so background tasks can reach it),
///   - does not sync to iCloud Keychain (keys are per-device; the
///     user would explicitly enrol a new iPhone with its own key).
///
/// **Thread safety**: Each Keychain call allocates its own `CFDictionary`,
/// so no shared state. The methods are marked `nonisolated` to allow
/// calling from any actor context.
public struct KeychainSSHKeyStore: SSHKeyStore {
    public static let defaultService = "com.scarf.ssh-key"
    public static let defaultAccount = "primary"

    private let service: String
    private let account: String

    public init(service: String = defaultService, account: String = defaultAccount) {
        self.service = service
        self.account = account
    }

    public func load() async throws -> SSHKeyBundle? {
        var query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
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
        // swiftlint:disable:previous cyclomatic_complexity — accepted; single SecItem read
        _ = query // silence "never mutated" in older Swift 5 modes
    }

    public func save(_ bundle: SSHKeyBundle) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(bundle)
        } catch {
            throw SSHKeyStoreError.backendFailure(
                message: "Encode failed: \(error.localizedDescription)", osStatus: nil
            )
        }

        // Delete any existing entry first — SecItemUpdate is finicky
        // across OS versions; delete-and-insert is the simpler pattern
        // for single-entry storage.
        let baseQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SSHKeyStoreError.backendFailure(
                message: "Keychain write failed", osStatus: addStatus
            )
        }
    }

    public func delete() async throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is fine — delete() is idempotent by contract.
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SSHKeyStoreError.backendFailure(
                message: "Keychain delete failed", osStatus: status
            )
        }
    }
}

#endif // canImport(Security)
