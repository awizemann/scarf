import Foundation
import os

/// Persisted entry for a user-added server. `ServerContext` itself is a value
/// type we rebuild from these fields at runtime — we persist the minimum that
/// uniquely identifies a connection, not the whole context struct, so future
/// fields we add to `ServerContext` don't force a migration.
struct ServerEntry: Identifiable, Codable, Hashable, Sendable {
    var id: ServerID
    var displayName: String
    var kind: ServerKind
    /// User preference: this server is the one Scarf opens into when a
    /// fresh window has no prior binding (first launch or File → New).
    /// At most one entry should have this set — `ServerRegistry` enforces
    /// mutual exclusivity. If none do, Local is the implicit default.
    var openOnLaunch: Bool = false

    var context: ServerContext {
        ServerContext(id: id, displayName: displayName, kind: kind)
    }
}

/// On-disk envelope for `servers.json`. Schema-versioned so future changes
/// can migrate without losing data.
private struct RegistryFile: Codable {
    var schemaVersion: Int
    var entries: [ServerEntry]
}

/// App-scoped store for user-added servers. `local` is synthesized (not
/// persisted) and always appears first in `allContexts`. Remote entries are
/// loaded from `~/Library/Application Support/scarf/servers.json`.
///
/// Observable so SwiftUI views binding to `entries` redraw when a server is
/// added, renamed, or removed.
@Observable
@MainActor
final class ServerRegistry {
    private static let logger = Logger(subsystem: "com.scarf", category: "ServerRegistry")
    private static let currentSchemaVersion = 1

    /// Remote (user-added) entries. Observable: views redraw on mutation.
    private(set) var entries: [ServerEntry] = []

    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = support.appendingPathComponent("scarf", isDirectory: true)
        self.storeURL = dir.appendingPathComponent("servers.json")
        load()
    }

    // MARK: - Lookup

    /// The implicit local server plus every persisted remote entry, in list
    /// order. Use this when populating UI like the toolbar switcher.
    var allContexts: [ServerContext] {
        [.local] + entries.map { $0.context }
    }

    /// Resolve an ID to a context, or `nil` if the entry no longer exists.
    /// Used by the multi-window root to detect "this window points at a
    /// server you've since removed" and show a dedicated empty state.
    func context(for id: ServerID) -> ServerContext? {
        if id == ServerContext.local.id { return .local }
        if let entry = entries.first(where: { $0.id == id }) {
            return entry.context
        }
        return nil
    }

    /// The server a fresh window should open into. Returns the ID of the
    /// remote entry flagged `openOnLaunch`, or Local's ID if none is
    /// flagged (or if the flagged entry was removed out from under us).
    /// Consumed by the `WindowGroup`'s `defaultValue` closure.
    var defaultServerID: ServerID {
        entries.first(where: { $0.openOnLaunch })?.id ?? ServerContext.local.id
    }

    /// Flip the default server to `id`. Passing `ServerContext.local.id`
    /// clears the flag on every remote entry, making Local the implicit
    /// default. Passing an unknown ID is a no-op. Persisted on return.
    func setDefaultServer(_ id: ServerID) {
        var changed = false
        for idx in entries.indices {
            let shouldBeDefault = (entries[idx].id == id)
            if entries[idx].openOnLaunch != shouldBeDefault {
                entries[idx].openOnLaunch = shouldBeDefault
                changed = true
            }
        }
        if changed {
            save()
            onEntriesChanged?()
        }
    }

    // MARK: - Mutations

    /// Optional callback fired whenever `entries` changes. The app wires
    /// this to `ServerLiveStatusRegistry.rebuild()` so the menu-bar fanout
    /// stays in sync without polling the entries array.
    var onEntriesChanged: (() -> Void)?

    @discardableResult
    func addServer(displayName: String, config: SSHConfig) -> ServerEntry {
        let entry = ServerEntry(
            id: ServerID(),
            displayName: displayName,
            kind: .ssh(config)
        )
        entries.append(entry)
        save()
        onEntriesChanged?()
        return entry
    }

    func updateServer(_ id: ServerID, displayName: String?, config: SSHConfig?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if let name = displayName { entries[idx].displayName = name }
        if let cfg = config { entries[idx].kind = .ssh(cfg) }
        save()
        onEntriesChanged?()
    }

    func removeServer(_ id: ServerID) {
        // Grab the entry BEFORE removing it so we can tear down its transport
        // state. Without this the user would leak a ControlMaster socket
        // (~10min TTL) and a snapshot cache dir (indefinite) per removed
        // server — harmless individually, ugly at scale.
        let removed = entries.first { $0.id == id }
        entries.removeAll { $0.id == id }
        save()

        if let removed, case .ssh(let config) = removed.kind {
            let transport = SSHTransport(contextID: id, config: config, displayName: removed.displayName)
            transport.closeControlMaster()
        }
        SSHTransport.pruneSnapshotCache(for: id)
        // Drop process-wide cache entries keyed on this ServerID so a future
        // re-add with a colliding ID (theoretical — UUIDs are random, but be
        // defensive) doesn't serve stale data.
        Task.detached { await ServerContext.invalidateCaches(for: id) }

        onEntriesChanged?()
    }

    // MARK: - App-launch sweep

    /// Remove snapshot cache directories whose UUID isn't in the current
    /// registry. Handles the case where the user removed a server while the
    /// app was closed — we want the cache to converge to the registry's
    /// state at launch rather than carrying forever.
    func sweepOrphanCaches() {
        var keep: Set<ServerID> = [ServerContext.local.id]
        for entry in entries { keep.insert(entry.id) }
        SSHTransport.sweepOrphanSnapshots(keeping: keep)
        SSHTransport.sweepStaleControlSockets()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            entries = []
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let file = try JSONDecoder().decode(RegistryFile.self, from: data)
            entries = file.entries
        } catch {
            Self.logger.error("Failed to load servers.json: \(error.localizedDescription)")
            entries = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let file = RegistryFile(schemaVersion: Self.currentSchemaVersion, entries: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save servers.json: \(error.localizedDescription)")
        }
    }
}
