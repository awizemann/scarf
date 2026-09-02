import Foundation
#if canImport(os)
import os
#endif

/// Persisted-file CRUD for user-saved model presets. Reads and writes
/// `~/.hermes/scarf/model_presets.json`. Scarf-owned — Hermes never
/// touches this file.
///
/// **Concurrency.** Pure-I/O `actor`. Mirrors `KanbanService` and the
/// other ScarfCore services — every public method serializes through
/// the actor, and the underlying read/write is wrapped in a detached
/// task to keep MainActor off the hot path. The file is small (a
/// handful of records per user) so we re-read on every call rather
/// than holding an in-memory cache that could drift from disk when
/// multiple windows / processes touch it.
///
/// **Missing-file semantics.** `list()` returns `[]` rather than
/// throwing when the file is absent — first-run, no-presets-yet is
/// the common case, not an error. Corrupt JSON throws so the UI can
/// show a real diagnostic instead of silently dropping presets.
public actor ModelPresetService {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "ModelPresetService")
    #endif

    private let context: ServerContext

    public init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Public surface

    /// Returns every preset on disk, sorted by `name` (case-insensitive).
    /// Empty array when the file doesn't exist.
    public func list() async throws -> [ModelPreset] {
        let store = try await loadStore()
        return store.presets.sorted { a, b in
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Returns the preset with the given id, or nil if not found.
    public func get(id: UUID) async throws -> ModelPreset? {
        let store = try await loadStore()
        return store.presets.first(where: { $0.id == id })
    }

    /// Insert (if id is new) or update (if id matches an existing record).
    /// `updatedAt` is overwritten to now on every upsert so the JSON
    /// reflects last-write time.
    public func upsert(_ preset: ModelPreset) async throws {
        var store = try await loadStore()
        var copy = preset
        copy.updatedAt = Date()
        if let idx = store.presets.firstIndex(where: { $0.id == preset.id }) {
            store.presets[idx] = copy
        } else {
            store.presets.append(copy)
        }
        try await persist(store)
        #if canImport(os)
        Self.logger.info("upsert preset \(preset.id.uuidString, privacy: .public) name=\(preset.name, privacy: .public)")
        #endif
    }

    /// Remove the preset with the given id. No-op (no error) when the id
    /// isn't present — matches `Set.remove` semantics so callers can
    /// idempotently retry a delete.
    public func delete(id: UUID) async throws {
        var store = try await loadStore()
        let before = store.presets.count
        store.presets.removeAll(where: { $0.id == id })
        guard store.presets.count != before else { return }
        try await persist(store)
        #if canImport(os)
        Self.logger.info("deleted preset \(id.uuidString, privacy: .public)")
        #endif
    }

    // MARK: - Private I/O

    private func loadStore() async throws -> ModelPresetStore {
        let context = self.context
        return try await Task.detached(priority: .utility) { () throws -> ModelPresetStore in
            let transport = context.makeTransport()
            let path = context.paths.modelPresetsJSON
            guard transport.fileExists(path) else {
                return ModelPresetStore()
            }
            let data = try transport.readFile(path)
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(ModelPresetStore.self, from: data)
            } catch {
                throw ModelPresetServiceError.corruptStore(underlying: error.localizedDescription)
            }
        }.value
    }

    private func persist(_ store: ModelPresetStore) async throws {
        let context = self.context
        var updated = store
        updated.version = ModelPresetStore.currentVersion
        updated.updatedAt = ModelPresetStore.nowISO8601()
        try await Task.detached(priority: .utility) { [updated] in
            let transport = context.makeTransport()
            let path = context.paths.modelPresetsJSON
            let scarfDir = context.paths.scarfDir
            if !transport.fileExists(scarfDir) {
                try transport.createDirectory(scarfDir)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(updated)
            try transport.writeFile(path, data: data)
        }.value
    }
}

/// Blocking, read-only view of one host's preset store — for callers that
/// are already off the main actor inside a synchronous fan-out (the fleet
/// gather / apply path) and can't await an actor per host.
///
/// **Why the fleet needs this.** A `modelPresetId` is a UUID minted into
/// ONE host's `~/.hermes/scarf/model_presets.json`; it is meaningless on
/// another host. Before "apply to fleet" pushes that id onto a target, it
/// asks this reader whether the id resolves there — an id that doesn't is
/// skipped and explained, never written as a dangling binding.
public struct ModelPresetStoreReader: Sendable {
    public let context: ServerContext

    public nonisolated init(context: ServerContext) {
        self.context = context
    }

    /// Every preset id present on this host. Empty on a missing/corrupt
    /// store — the caller treats "not listed" as "not available", which is
    /// the safe direction (skip, don't dangle).
    public nonisolated func presetIDs() -> Set<UUID> {
        let transport = context.makeTransport()
        let path = context.paths.modelPresetsJSON
        guard transport.fileExists(path), let data = try? transport.readFile(path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let store = try? decoder.decode(ModelPresetStore.self, from: data) else { return [] }
        return Set(store.presets.map(\.id))
    }

    /// Whether `id` resolves to a preset on this host.
    public nonisolated func contains(_ id: UUID) -> Bool { presetIDs().contains(id) }
}

/// Errors raised by `ModelPresetService`. Missing file is *not* an error
/// — see `list()`. Only conditions that need user attention surface here.
public enum ModelPresetServiceError: Error, Sendable, Equatable {
    /// The file exists but couldn't be decoded as `ModelPresetStore`.
    /// `underlying` carries the JSON decoder's message for diagnostics.
    case corruptStore(underlying: String)
}
