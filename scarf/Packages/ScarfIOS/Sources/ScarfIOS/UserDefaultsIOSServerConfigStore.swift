import Foundation
import ScarfCore

/// `UserDefaults`-backed implementation of `IOSServerConfigStore`.
///
/// Data shape:
/// - v1 (single-server): JSON-encoded IOSServerConfig stored under
///   `com.scarf.ios.primary-server-config.v1`. Shipped in M2.
/// - v2 (multi-server, M9): JSON-encoded `[ServerID: IOSServerConfig]`
///   stored under `com.scarf.ios.servers.v2`. Written by new onboardings.
///
/// Migration: on first access after the M9 update, if a v1 record
/// exists AND v2 is empty, load the v1 config and insert it into v2
/// under a fresh ServerID, then delete the v1 key. Pure one-shot —
/// on every subsequent launch the v1 key is gone and we read v2
/// directly.
///
/// The server config itself is not sensitive (SSH private keys live in
/// the Keychain separately), so `UserDefaults` is the right low-
/// ceremony store.
public struct UserDefaultsIOSServerConfigStore: IOSServerConfigStore {
    public static let legacyV1Key = "com.scarf.ios.primary-server-config.v1"
    public static let defaultDefaultsKey = "com.scarf.ios.servers.v2"

    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = defaultDefaultsKey,
        legacyKey: String = legacyV1Key
    ) {
        self.defaults = defaults
        self.key = key
        self.legacyKey = legacyKey
    }

    // MARK: - Singleton API (compat)

    public func load() async throws -> IOSServerConfig? {
        let all = try await listAll()
        guard let first = primaryEntry(from: all) else { return nil }
        return first.config
    }

    public func save(_ config: IOSServerConfig) async throws {
        var all = try await listAll()
        if let primaryID = primaryEntry(from: all)?.id {
            all[primaryID] = config
        } else {
            all[ServerID()] = config
        }
        try writeAll(all)
    }

    public func delete() async throws {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    // MARK: - Multi-server API

    public func listAll() async throws -> [ServerID: IOSServerConfig] {
        // Migrate v1 first so the v2 read below sees the latest data.
        migrateLegacyIfNeeded()
        guard let data = defaults.data(forKey: key) else { return [:] }
        let raw = try JSONDecoder().decode([String: IOSServerConfig].self, from: data)
        var result: [ServerID: IOSServerConfig] = [:]
        for (idString, config) in raw {
            guard let uuid = UUID(uuidString: idString) else { continue }
            result[uuid] = config
        }
        return result
    }

    public func load(id: ServerID) async throws -> IOSServerConfig? {
        try await listAll()[id]
    }

    public func save(_ config: IOSServerConfig, id: ServerID) async throws {
        var all = try await listAll()
        all[id] = config
        try writeAll(all)
    }

    public func delete(id: ServerID) async throws {
        var all = try await listAll()
        guard all.removeValue(forKey: id) != nil else { return }
        try writeAll(all)
    }

    // MARK: - Helpers

    /// Pick the "primary" entry from a list using a stable order —
    /// lowest UUID string wins. Guarantees deterministic behaviour
    /// when the singleton API is called on a multi-server store.
    private func primaryEntry(
        from all: [ServerID: IOSServerConfig]
    ) -> (id: ServerID, config: IOSServerConfig)? {
        guard let id = all.keys.sorted(by: { $0.uuidString < $1.uuidString }).first,
              let config = all[id]
        else { return nil }
        return (id, config)
    }

    private func writeAll(_ all: [ServerID: IOSServerConfig]) throws {
        var raw: [String: IOSServerConfig] = [:]
        for (id, config) in all {
            raw[id.uuidString] = config
        }
        let data = try JSONEncoder().encode(raw)
        defaults.set(data, forKey: key)
    }

    /// One-shot v1 → v2 migration. If a v1 singleton exists and v2 is
    /// empty, insert the v1 entry under a fresh ServerID and delete
    /// v1. Safe to call on every `listAll()` — becomes a no-op once
    /// v1 is gone.
    private func migrateLegacyIfNeeded() {
        guard defaults.data(forKey: key) == nil,
              let legacyData = defaults.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode(IOSServerConfig.self, from: legacyData)
        else { return }
        let migrated: [String: IOSServerConfig] = [
            ServerID().uuidString: legacy
        ]
        if let out = try? JSONEncoder().encode(migrated) {
            defaults.set(out, forKey: key)
            defaults.removeObject(forKey: legacyKey)
        }
    }
}
