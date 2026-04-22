import Foundation
import ScarfCore

/// `UserDefaults`-backed implementation of `IOSServerConfigStore`. The
/// server config (hostname, user, display name, etc.) is not itself
/// sensitive — the SSH private key lives in the Keychain separately —
/// so `UserDefaults` is the right low-ceremony store for it.
///
/// The record serializes as JSON under a single key. A future schema
/// migration can bump the key name (`.v2` suffix) if the shape
/// changes; today there's nothing to migrate.
public struct UserDefaultsIOSServerConfigStore: IOSServerConfigStore {
    public static let defaultDefaultsKey = "com.scarf.ios.primary-server-config.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = defaultDefaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() async throws -> IOSServerConfig? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(IOSServerConfig.self, from: data)
    }

    public func save(_ config: IOSServerConfig) async throws {
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: key)
    }

    public func delete() async throws {
        defaults.removeObject(forKey: key)
    }
}
