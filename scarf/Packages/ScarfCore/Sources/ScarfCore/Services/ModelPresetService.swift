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
    /// Reachable from `ModelPresetStoreReader`, which is a struct outside
    /// the actor and cannot see the private one.
    static let readerLogger = Logger(subsystem: "com.scarf", category: "ModelPresetStoreReader")
    #endif

    private let context: ServerContext

    public init(context: ServerContext = .local) {
        self.context = context
    }

    /// The instance every call site must use for a given host.
    ///
    /// **The actor was serializing nothing.** Six call sites each built
    /// their OWN `ModelPresetService(context:)` (chat, the model badge,
    /// the project preset sheet, the cockpit, the presets list, iOS's
    /// project detail) — and an `actor` serializes calls to ONE instance,
    /// so six instances over one file is six unserialized read-modify-write
    /// cycles. Two overlapping upserts and the later full-file write drops
    /// the earlier preset. Sharing the instance per context makes the
    /// serialization the doc comment always claimed.
    ///
    /// Keyed by `ServerContext` (its `Hashable` covers id + kind + home
    /// override), so each window's host gets its own serialization domain
    /// and tests with temp homes never share one with production.
    public static func shared(for context: ServerContext) -> ModelPresetService {
        instancesLock.lock()
        defer { instancesLock.unlock() }
        if let existing = instances[context] { return existing }
        let created = ModelPresetService(context: context)
        instances[context] = created
        return created
    }

    private static let instancesLock = NSLock()
    nonisolated(unsafe) private static var instances: [ServerContext: ModelPresetService] = [:]

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
        var copy = preset
        copy.updatedAt = Date()
        let inserted = copy
        try await mutate { store in
            if let idx = store.presets.firstIndex(where: { $0.id == inserted.id }) {
                store.presets[idx] = inserted
            } else {
                store.presets.append(inserted)
            }
            return true
        }
        #if canImport(os)
        Self.logger.info("upsert preset \(preset.id.uuidString, privacy: .public) name=\(preset.name, privacy: .public)")
        #endif
    }

    /// Remove the preset with the given id. No-op (no error) when the id
    /// isn't present — matches `Set.remove` semantics so callers can
    /// idempotently retry a delete.
    public func delete(id: UUID) async throws {
        let removed = try await mutate { store in
            let before = store.presets.count
            store.presets.removeAll(where: { $0.id == id })
            return store.presets.count != before
        }
        guard removed else { return }
        #if canImport(os)
        Self.logger.info("deleted preset \(id.uuidString, privacy: .public)")
        #endif
    }

    // MARK: - Private I/O

    /// Presets are a handful of small records; anything past this cap is
    /// not a preset store we should try to decode on a phone.
    static let maxBytes = 1 * 1024 * 1024

    /// ONE inspection serving both the decode and the write.
    ///
    /// **Why this replaced `fileExists`.** `loadStore` used to open with
    /// `guard transport.fileExists(path) else { return ModelPresetStore() }`
    /// — the same absent-vs-unreadable INFERENCE the guarded stores exist
    /// to forbid, spelled differently. One dropped SSH round-trip made
    /// `fileExists` false, the load returned an EMPTY store, and the next
    /// `upsert` published a one-preset file over the user's full one, with
    /// no `.bak` behind it. `GuardedJSONStore` takes proof instead
    /// (stat-confirm + retried read), so a stat-confirmed unreadable file
    /// REFUSES the write.
    ///
    /// Undecodable bytes are NOT quarantined-and-rebuilt the way
    /// `miniapp_grants.json` is: a preset is user-authored and exists
    /// nowhere else, so — like `projects.json` — the store refuses until a
    /// human looks at it.
    private nonisolated static func inspect(
        _ context: ServerContext
    ) throws -> (store: ModelPresetStore, inspection: GuardedJSONStore.Inspection, guarded: GuardedJSONStore, path: String) {
        let path = context.paths.modelPresetsJSON
        let guarded = GuardedJSONStore(transport: context.makeTransport(), label: "model_presets.json")
        let inspection = guarded.inspect(path, maxBytes: maxBytes)
        switch inspection.state {
        case .absent:
            return (ModelPresetStore(), inspection, guarded, path)
        case .unreadable(let damaged):
            throw ModelPresetServiceError.unreadableStore(path: damaged)
        case .quarantined(let copy):
            throw ModelPresetServiceError.corruptStore(
                underlying: "store was past the \(maxBytes)-byte cap; copied aside to \(copy)"
            )
        case .present:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let store = try decoder.decode(ModelPresetStore.self, from: inspection.bytes ?? Data())
                return (store, inspection, guarded, path)
            } catch {
                throw ModelPresetServiceError.corruptStore(underlying: error.localizedDescription)
            }
        }
    }

    private func loadStore() async throws -> ModelPresetStore {
        let context = self.context
        return try await Task.detached(priority: .utility) { () throws -> ModelPresetStore in
            try Self.inspect(context).store
        }.value
    }

    /// Read-modify-write in ONE detached pass, so the write is checked
    /// against the very read it was computed from. Reverting to
    /// `loadStore()` + `persist()` would reopen the hole even with the
    /// guard in place.
    ///
    /// - Parameter body: mutates the store and returns whether anything
    ///   actually changed. `false` writes nothing.
    @discardableResult
    private func mutate(_ body: @Sendable @escaping (inout ModelPresetStore) -> Bool) async throws -> Bool {
        let context = self.context
        return try await Task.detached(priority: .utility) { () throws -> Bool in
            let probe = try Self.inspect(context)
            var store = probe.store
            guard body(&store) else { return false }
            store.version = ModelPresetStore.currentVersion
            store.updatedAt = ModelPresetStore.nowISO8601()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(store)
            try probe.guarded.write(data, to: probe.path, after: probe.inspection)
            return true
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

    /// What a probe of this host's preset store actually found. The
    /// distinction matters to the fleet diagnosis: "this host has no such
    /// preset" and "we could not read this host's presets" produce the same
    /// skip but are not the same fact, and reporting the second as the
    /// first sends the user looking for a preset that is right there.
    public enum Probe: Sendable, Equatable {
        case presets(Set<UUID>)
        /// No store on this host yet — a fresh install has none.
        case absent
        /// The store is there and could not be read or decoded.
        case unreadable(path: String)

        /// The ids, with both failure modes collapsed to empty — the safe
        /// direction for a WRITE decision (skip, never dangle).
        public var ids: Set<UUID> {
            if case .presets(let ids) = self { return ids }
            return []
        }
    }

    /// Probe this host's store, keeping absent and unreadable apart.
    ///
    /// Proof-based, like the writer: `fileExists` false on a dropped
    /// round-trip used to report `.absent` — "this host has no presets" —
    /// about a host whose store is right there.
    public nonisolated func probe() -> Probe {
        let path = context.paths.modelPresetsJSON
        let guarded = GuardedJSONStore(transport: context.makeTransport(), label: "model_presets.json")
        let inspection = guarded.inspect(path, maxBytes: ModelPresetService.maxBytes)
        switch inspection.state {
        case .absent: return .absent
        case .unreadable, .quarantined: return .unreadable(path: path)
        case .present:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = inspection.bytes,
                  let store = try? decoder.decode(ModelPresetStore.self, from: data) else {
                return .unreadable(path: path)
            }
            return .presets(Set(store.presets.map(\.id)))
        }
    }

    /// Every preset id present on this host. Empty on a missing/corrupt
    /// store — the caller treats "not listed" as "not available", which is
    /// the safe direction (skip, don't dangle). A failure is LOGGED rather
    /// than swallowed silently: the fleet's "preset not on this host"
    /// explanation used to be the only trace an unreadable store left, and
    /// it named the wrong cause. Callers that need to tell the two apart
    /// ask ``probe()``.
    public nonisolated func presetIDs() -> Set<UUID> {
        let probed = probe()
        #if canImport(os)
        if case .unreadable(let path) = probed {
            ModelPresetService.readerLogger.error(
                "model_presets.json at \(path, privacy: .public) exists but could not be read/decoded; reporting no presets for this host"
            )
        }
        #endif
        return probed.ids
    }

    /// Whether `id` resolves to a preset on this host.
    public nonisolated func contains(_ id: UUID) -> Bool { presetIDs().contains(id) }
}

/// Errors raised by `ModelPresetService`. Missing file is *not* an error
/// — see `list()`. Only conditions that need user attention surface here.
public enum ModelPresetServiceError: LocalizedError, Sendable, Equatable {
    /// The file exists but couldn't be decoded as `ModelPresetStore`.
    /// `underlying` carries the JSON decoder's message for diagnostics.
    case corruptStore(underlying: String)
    /// The file is stat-confirmed (or zero bytes) and two reads of it
    /// failed. Reads report it rather than lying "no presets", and writes
    /// never get far enough to replace bytes nobody has seen.
    case unreadableStore(path: String)

    public var errorDescription: String? {
        switch self {
        case let .corruptStore(underlying):
            return "The model preset store couldn't be read: \(underlying)"
        case let .unreadableStore(path):
            return "model_presets.json at \(path) exists but couldn't be read; refusing to replace it."
        }
    }
}
