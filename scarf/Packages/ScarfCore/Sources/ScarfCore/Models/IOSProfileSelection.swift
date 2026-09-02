import Foundation

/// Per-server selected Hermes profile for ScarfGo (issue #120, Design B).
///
/// Stores only a profile *name* per `ServerID` (or nothing = the default /
/// root profile). The name is combined with the server's base home by
/// `HermesProfileScope.resolveHome` to scope every read/write, and passed
/// to `hermes -p <name>` to scope chat/CLI — WITHOUT mutating the host's
/// `active_profile`.
///
/// Sync (not async) on purpose: reads happen while building the view tree,
/// the payload is a tiny string map, and there is no migration to perform —
/// the same low-ceremony shape as SwiftUI's `@AppStorage`. The protocol, the
/// in-memory implementation, and the `UserDefaults` implementation all live
/// in ScarfCore so BOTH platforms share them: iOS (ScarfGo, #120) and the Mac
/// app's per-window "viewing profile" scoping (#126). Each app has its own
/// `UserDefaults` suite, so a per-platform `key:` keeps the two selections
/// independent.
public protocol IOSProfileSelectionStore: Sendable {
    /// Selected profile name for a server, or `nil` for the default
    /// (root) profile. Always returns a normalized value.
    func selectedProfile(for id: ServerID) -> String?

    /// Set (a valid name) or clear (`nil`/`"default"`/invalid → default)
    /// the selected profile for a server.
    func setSelectedProfile(_ name: String?, for id: ServerID)
}

/// In-memory store for tests and previews. Thread-safe via a lock so it
/// satisfies `Sendable` and matches production call patterns.
public final class InMemoryProfileSelectionStore: IOSProfileSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ServerID: String] = [:]

    public init() {}

    public func selectedProfile(for id: ServerID) -> String? {
        lock.withLock { HermesProfileScope.normalize(storage[id]) }
    }

    public func setSelectedProfile(_ name: String?, for id: ServerID) {
        lock.withLock {
            if let normalized = HermesProfileScope.normalize(name) {
                storage[id] = normalized
            } else {
                storage.removeValue(forKey: id)
            }
        }
    }
}

/// `UserDefaults`-backed `IOSProfileSelectionStore` shared by both apps
/// (iOS Design B #120, Mac per-window viewing profile #126).
///
/// The selection is not sensitive (SSH keys live in the Keychain), so
/// `UserDefaults` is the right home — same low-ceremony call as
/// `UserDefaultsIOSServerConfigStore`.
///
/// Data shape: JSON `[ServerID.uuidString: String]` under `key`. An absent
/// key, an absent entry, or an entry that fails normalization all read back
/// as `nil` (default profile). Writing `nil`/`"default"`/an invalid name
/// removes the entry. The iOS app and the Mac app each pass their own `key`
/// (and run in separate `UserDefaults` suites), so their selections never
/// collide.
///
/// **Threading.** `setSelectedProfile` is a read-modify-write over a single
/// JSON blob, which is NOT atomic across concurrent writers. Production drives
/// this only through `@MainActor` owners (`ScarfGoCoordinator` on iOS,
/// `WindowProfileScope` on Mac), so writes are serialized; if a future caller
/// writes off the main actor, add synchronization here.
public struct UserDefaultsProfileSelectionStore: IOSProfileSelectionStore {
    /// Default key for the iOS app (kept stable for backward compatibility —
    /// the Mac app passes its own key).
    public static let defaultDefaultsKey = "com.scarf.ios.profile-selections.v1"

    /// `UserDefaults` is thread-safe but not formally `Sendable`; this store
    /// only ever reads/writes through it, so the unchecked hop is stated here
    /// rather than dropping the struct's `Sendable` conformance.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = defaultDefaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func selectedProfile(for id: ServerID) -> String? {
        HermesProfileScope.normalize(read()[id.uuidString])
    }

    public func setSelectedProfile(_ name: String?, for id: ServerID) {
        var all = read()
        if let normalized = HermesProfileScope.normalize(name) {
            all[id.uuidString] = normalized
        } else {
            all.removeValue(forKey: id.uuidString)
        }
        write(all)
    }

    private func read() -> [String: String] {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return raw
    }

    private func write(_ all: [String: String]) {
        guard !all.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }
}
