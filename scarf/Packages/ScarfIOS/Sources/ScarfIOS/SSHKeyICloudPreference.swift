// Apple-only: Security.framework + UserDefaults are iOS/Mac only.
// On Linux this file is skipped; tests don't exercise it.
#if canImport(Security)

import Foundation

/// Device-local preference: should the SSH key bundle stored in the
/// iOS Keychain sync to iCloud Keychain (issue #52)?
///
/// **Default `false`.** Existing installs see no change on update; the
/// key remains pinned to the device with `kSecAttrAccessibleAfter
/// FirstUnlockThisDeviceOnly` + `kSecAttrSynchronizable=false`. Users
/// who opt in via Settings → Security trigger a one-shot migration
/// that re-saves all stored keys with `kSecAttrAccessibleAfterFirst
/// Unlock` + `kSecAttrSynchronizable=true` so iCloud Keychain picks
/// them up.
///
/// **Trade-off the UI must surface clearly.**
/// - On: convenient multi-device — iPhone + iPad + Mac all see the
///   same key. End-to-end encrypted by iCloud Keychain (Apple-managed
///   keys without ADP, user-managed keys with ADP). Requires iCloud
///   Keychain enabled on every device.
/// - Off (default): key never leaves this device. Each device must
///   onboard separately (generate its own key, append its pubkey to
///   `authorized_keys`).
public enum SSHKeyICloudPreference {

    /// UserDefaults key. Stable string so a v2 future fix can read
    /// existing values without migration.
    public static let key = "scarf.icloud.syncSSHKey"

    /// Read the current preference. Defaults to `false`.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

#endif // canImport(Security)
