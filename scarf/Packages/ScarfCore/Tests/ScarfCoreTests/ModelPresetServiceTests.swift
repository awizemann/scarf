import Testing
import Foundation
@testable import ScarfCore

/// Tests for `ModelPreset` Codable round-trip and `ModelPresetService`
/// CRUD semantics.
///
/// Pure-data tests are pure JSON round-trips — no disk. The actor's
/// disk-integration paths are exercised by a single test that writes
/// under a per-test scratch home so we don't clobber the developer's
/// real `~/.hermes/scarf/model_presets.json`.
@Suite struct ModelPresetCodableTests {

    @Test func roundTripPreservesAllFields() throws {
        let preset = ModelPreset(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
            name: "Sonnet 4.6",
            modelID: "claude-sonnet-4.6",
            providerID: "anthropic",
            notes: "Daily driver",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelPreset.self, from: data)
        #expect(decoded.id == preset.id)
        #expect(decoded.name == preset.name)
        #expect(decoded.modelID == preset.modelID)
        #expect(decoded.providerID == preset.providerID)
        #expect(decoded.notes == preset.notes)
        #expect(decoded.createdAt == preset.createdAt)
        #expect(decoded.updatedAt == preset.updatedAt)
    }

    @Test func nilNotesRoundTrips() throws {
        let preset = ModelPreset(name: "Haiku", modelID: "claude-haiku-4-5", providerID: "anthropic")
        #expect(preset.notes == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelPreset.self, from: data)
        #expect(decoded.notes == nil)
    }

    @Test func storeDefaultsToCurrentVersion() {
        let store = ModelPresetStore()
        #expect(store.version == ModelPresetStore.currentVersion)
        #expect(store.presets.isEmpty)
    }

    @Test func storeIsCodable() throws {
        let store = ModelPresetStore(
            version: 1,
            presets: [
                ModelPreset(name: "A", modelID: "a", providerID: "p1"),
                ModelPreset(name: "B", modelID: "b", providerID: "p2"),
            ],
            updatedAt: "2026-05-15T12:00:00Z"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelPresetStore.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.presets.count == 2)
        #expect(decoded.updatedAt == "2026-05-15T12:00:00Z")
    }
}

/// Disk-integration tests for `ModelPresetService`. Each test runs against
/// a fresh per-test temp Hermes home injected via `ServerContext.local(home:)`
/// (t-aud25), so the service's reads/writes land in an isolated tmpdir and
/// NEVER touch the developer's real `~/.hermes/scarf/model_presets.json`.
///
/// This replaces the earlier back-up-and-restore-the-real-file compromise,
/// which forced the suite to be `.serialized`. Per-instance home injection
/// gives each test its own home, so they run in parallel with no shared state.
@Suite struct ModelPresetServiceDiskTests {

    /// Run `body` against a `.local` context rooted at a unique temp home,
    /// removing the directory afterwards. The home starts empty, so
    /// `model_presets.json` is absent until a test writes it.
    static func withTempHome(_ body: (ServerContext) async throws -> Void) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-modelpreset-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try await body(ServerContext.local(home: home))
    }

    @Test func listReturnsEmptyWhenFileMissing() async throws {
        try await Self.withTempHome { ctx in
            let svc = ModelPresetService(context: ctx)
            let presets = try await svc.list()
            #expect(presets.isEmpty)
        }
    }

    @Test func upsertThenListRoundTrips() async throws {
        try await Self.withTempHome { ctx in
            let svc = ModelPresetService(context: ctx)
            let preset = ModelPreset(name: "Sonnet", modelID: "claude-sonnet-4.6", providerID: "anthropic")
            try await svc.upsert(preset)
            let presets = try await svc.list()
            try #require(presets.count == 1)
            #expect(presets[0].id == preset.id)
            #expect(presets[0].name == "Sonnet")
            #expect(presets[0].modelID == "claude-sonnet-4.6")
        }
    }

    @Test func upsertExistingIdUpdatesInPlace() async throws {
        try await Self.withTempHome { ctx in
            let svc = ModelPresetService(context: ctx)
            let id = UUID()
            try await svc.upsert(
                ModelPreset(id: id, name: "Sonnet", modelID: "claude-sonnet-4.6", providerID: "anthropic")
            )
            // Same id, different fields.
            try await svc.upsert(
                ModelPreset(id: id, name: "Sonnet (renamed)", modelID: "claude-sonnet-4.6", providerID: "anthropic", notes: "now with notes")
            )
            let presets = try await svc.list()
            try #require(presets.count == 1)
            #expect(presets[0].name == "Sonnet (renamed)")
            #expect(presets[0].notes == "now with notes")
        }
    }

    @Test func deleteRemovesPreset() async throws {
        try await Self.withTempHome { ctx in
            let svc = ModelPresetService(context: ctx)
            let id = UUID()
            try await svc.upsert(
                ModelPreset(id: id, name: "Sonnet", modelID: "claude-sonnet-4.6", providerID: "anthropic")
            )
            try await svc.delete(id: id)
            let presets = try await svc.list()
            #expect(presets.isEmpty)
        }
    }

    @Test func deleteMissingIdIsNoOp() async throws {
        try await Self.withTempHome { ctx in
            let svc = ModelPresetService(context: ctx)
            try await svc.delete(id: UUID())  // Should not throw.
            let presets = try await svc.list()
            #expect(presets.isEmpty)
        }
    }

    @Test func getById() async throws {
        try await Self.withTempHome { ctx in
            let svc = ModelPresetService(context: ctx)
            let id = UUID()
            try await svc.upsert(
                ModelPreset(id: id, name: "Sonnet", modelID: "claude-sonnet-4.6", providerID: "anthropic")
            )
            let found = try await svc.get(id: id)
            #expect(found != nil)
            #expect(found?.name == "Sonnet")
            let missing = try await svc.get(id: UUID())
            #expect(missing == nil)
        }
    }

    @Test func listSortsByNameCaseInsensitive() async throws {
        try await Self.withTempHome { ctx in
            let svc = ModelPresetService(context: ctx)
            try await svc.upsert(ModelPreset(name: "zeta", modelID: "z", providerID: "p"))
            try await svc.upsert(ModelPreset(name: "Alpha", modelID: "a", providerID: "p"))
            try await svc.upsert(ModelPreset(name: "beta", modelID: "b", providerID: "p"))
            let presets = try await svc.list()
            #expect(presets.map(\.name) == ["Alpha", "beta", "zeta"])
        }
    }

    @Test func corruptStoreThrows() async throws {
        try await Self.withTempHome { ctx in
            let path = ctx.paths.modelPresetsJSON
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try "not json".write(toFile: path, atomically: true, encoding: .utf8)
            let svc = ModelPresetService(context: ctx)
            await #expect(throws: ModelPresetServiceError.self) {
                _ = try await svc.list()
            }
        }
    }
}
