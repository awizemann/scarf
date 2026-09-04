import Testing
import Foundation
@testable import ScarfCore

/// Disk-integration coverage for the hardened projects registry: per-row
/// salvage decode, quarantine of an unreadable file, the empty-overwrite
/// refusal, atomic writes + rolling `.bak`, and legacy round-trips.
///
/// Every test drives the REAL `ProjectDashboardService` against a fresh
/// per-test temp Hermes home injected via `ServerContext.local(home:)`,
/// so the local transport does actual file I/O and nothing touches the
/// developer's `~/.hermes`.
@Suite struct ProjectRegistryResilienceTests {

    static func withTempHome(_ body: (ServerContext, _ registryPath: String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-registry-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        try FileManager.default.createDirectory(
            atPath: ctx.paths.scarfDir, withIntermediateDirectories: true
        )
        try body(ctx, ctx.paths.projectsRegistry)
    }

    static func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    static func quarantineFiles(in dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix("projects.json.corrupt-") }
            .sorted()
    }

    // MARK: - Per-entry salvage

    /// The live 2026-09-02 corruption: an agent wrote a non-UUID string
    /// into `uuid`. Before Phase 1 this emptied every project surface.
    @Test func invalidUUIDRowIsSalvagedNotDropped() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("""
            {
              "projects": [
                { "name": "healthy", "path": "/tmp/healthy", "uuid": "9E2A1B44-0000-4000-8000-000000000001" },
                { "name": "shabubox-seo-tracker", "path": "/tmp/shabubox", "uuid": "SHABUBOX-SEO-TRACKER-2026-09-03" }
              ]
            }
            """, to: path)

            // Fixture honesty: that string really is undecodable as a
            // UUID, so this test can't pass vacuously.
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(UUID.self, from: Data("\"SHABUBOX-SEO-TRACKER-2026-09-03\"".utf8))
            }

            let result = ProjectDashboardService(context: ctx).loadRegistryDetailed()
            #expect(result.registry.projects.count == 2)
            let bad = result.registry.projects.first { $0.name == "shabubox-seo-tracker" }
            #expect(bad != nil)
            #expect(bad?.path == "/tmp/shabubox")
            // The row survives; only the unreadable field is gone.
            #expect(bad?.uuid == nil)
            #expect(result.registry.projects.first { $0.name == "healthy" }?.uuid != nil)
            // …and the damage is observable to callers (Phase 2 banner).
            #expect(result.salvaged)
            #expect(result.droppedCount == 0)
            #expect(result.salvage.salvagedFields == ["shabubox-seo-tracker.uuid"])
            // No quarantine: the file was readable, just imperfect.
            #expect(result.quarantinePath == nil)
            #expect(Self.quarantineFiles(in: ctx.paths.scarfDir).isEmpty)
        }
    }

    @Test func malformedOptionalFieldsFallBackToDefaults() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("""
            {
              "projects": [
                { "name": "a", "path": "/tmp/a", "folder": 17, "archived": "yes" }
              ]
            }
            """, to: path)

            let result = ProjectDashboardService(context: ctx).loadRegistryDetailed()
            let row = try #require(result.registry.projects.first)
            #expect(row.folder == nil)
            #expect(row.archived == false)
            #expect(Set(result.salvage.salvagedFields) == ["a.folder", "a.archived"])
        }
    }

    @Test func rowMissingIdentityIsSkippedAndTheRestSurvive() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("""
            {
              "projects": [
                { "name": "keep-me", "path": "/tmp/keep" },
                { "path": "/tmp/nameless" },
                "not-even-an-object",
                { "name": "keep-me-too", "path": "/tmp/keep2", "folder": "work" }
              ]
            }
            """, to: path)

            let result = ProjectDashboardService(context: ctx).loadRegistryDetailed()
            #expect(result.registry.projects.map(\.name) == ["keep-me", "keep-me-too"])
            #expect(result.registry.projects.last?.folder == "work")
            #expect(result.droppedCount == 2)
            #expect(result.salvaged)
        }
    }

    /// A clean file must report clean — otherwise a Phase 2 banner would
    /// cry wolf on every load.
    @Test func healthyRegistryReportsNoSalvage() throws {
        try Self.withTempHome { ctx, _ in
            let service = ProjectDashboardService(context: ctx)
            try service.saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "a", path: "/tmp/a", folder: "work", archived: true, uuid: UUID()),
                ProjectEntry(name: "b", path: "/tmp/b"),
            ]))
            let result = service.loadRegistryDetailed()
            #expect(result.registry.projects.count == 2)
            #expect(!result.salvaged)
            #expect(result.salvage == .clean)
        }
    }

    /// `"uuid": null` / absent keys are normal, not damage.
    @Test func explicitNullsAndLegacyRowsAreNotFlagged() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("""
            {
              "projects": [
                { "name": "legacy", "path": "/tmp/legacy" },
                { "name": "nulled", "path": "/tmp/nulled", "uuid": null, "folder": null }
              ]
            }
            """, to: path)
            let result = ProjectDashboardService(context: ctx).loadRegistryDetailed()
            #expect(result.registry.projects.count == 2)
            #expect(!result.salvaged)
        }
    }

    // MARK: - Legacy round-trip

    /// A v2.2-era file (no `folder`/`archived`/`uuid`) loads, saves, and
    /// reloads without losing or inventing anything.
    @Test func legacyRegistryRoundTrips() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("""
            {
              "projects": [
                { "name": "old-one", "path": "/tmp/old-one" },
                { "name": "old-two", "path": "/tmp/old-two" }
              ]
            }
            """, to: path)

            let service = ProjectDashboardService(context: ctx)
            let loaded = service.loadRegistry()
            #expect(loaded.projects.map(\.name) == ["old-one", "old-two"])
            #expect(loaded.projects.allSatisfy { $0.uuid == nil && $0.folder == nil && !$0.archived })

            try service.saveRegistry(loaded)
            let reloaded = service.loadRegistry()
            #expect(reloaded.projects == loaded.projects)

            // Output contract for the agents that hand-read this file:
            // pretty-printed, sorted keys, absent optionals stay absent.
            let text = try Self.read(path)
            #expect(text.contains("\n  \"projects\" : ["))
            #expect(!text.contains("uuid"))
            #expect(!text.contains("archived"))
        }
    }

    // MARK: - Quarantine

    @Test func garbageFileIsQuarantinedAndNeverClobbered() throws {
        try Self.withTempHome { ctx, path in
            let garbage = "{ this is not json at all ][ "
            try Self.write(garbage, to: path)

            let service = ProjectDashboardService(context: ctx)
            let result = service.loadRegistryDetailed()
            #expect(result.registry.projects.isEmpty)
            let quarantine = try #require(result.quarantinePath)
            #expect(result.salvaged)
            #expect(try Self.read(quarantine) == garbage)
            #expect((quarantine as NSString).lastPathComponent.hasPrefix("projects.json.corrupt-"))

            // The corrupt bytes survive a later save (the exact
            // load-empty → save-empty sequence that erased projects).
            #expect(throws: ProjectRegistryError.self) {
                try service.saveRegistry(result.registry)
            }
            // A NON-empty save over the same file is refused too, as of the
            // chokepoint guard: the quarantine copy means the bytes are not
            // lost, but the live list would silently become "just this one"
            // while the user's real projects sat in a `.corrupt-` file they
            // never asked for. Every write is paused until the file is
            // repaired or removed — the same rule the sidebar, the doctor
            // and the MCP tools state.
            #expect(throws: ProjectRegistryError.self) {
                try service.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "new", path: "/tmp/new")]))
            }
            #expect(try Self.read(quarantine) == garbage)
            #expect(try Self.read(path) == garbage)
        }
    }

    /// `loadRegistry` runs on every watcher tick; a corrupt file must not
    /// spawn one quarantine copy per load.
    @Test func repeatedLoadsOfTheSameCorruptFileQuarantineOnce() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("<<not json>>", to: path)
            let service = ProjectDashboardService(context: ctx)
            let first = service.loadRegistryDetailed().quarantinePath
            let second = service.loadRegistryDetailed().quarantinePath
            let third = service.loadRegistryDetailed().quarantinePath
            #expect(first != nil)
            #expect(second == first)
            #expect(third == first)
            #expect(Self.quarantineFiles(in: ctx.paths.scarfDir).count == 1)
        }
    }

    @Test func differentCorruptionGetsItsOwnQuarantineCopy() throws {
        try Self.withTempHome { ctx, path in
            let service = ProjectDashboardService(context: ctx)
            try Self.write("<<garbage one>>", to: path)
            _ = service.loadRegistryDetailed()
            // Same-second writes must not collide on the timestamp
            // alone — distinct content gets a distinct copy.
            try Self.write("<<garbage two>>", to: path)
            _ = service.loadRegistryDetailed()
            let copies = Self.quarantineFiles(in: ctx.paths.scarfDir)
            #expect(copies.count == 2)
            let contents = Set(try copies.map { try Self.read(ctx.paths.scarfDir + "/" + $0) })
            #expect(contents == ["<<garbage one>>", "<<garbage two>>"])
        }
    }

    @Test func missingRegistryIsNotCorruption() throws {
        try Self.withTempHome { ctx, _ in
            let result = ProjectDashboardService(context: ctx).loadRegistryDetailed()
            #expect(result.registry.projects.isEmpty)
            #expect(!result.salvaged)
            #expect(result.quarantinePath == nil)
            #expect(Self.quarantineFiles(in: ctx.paths.scarfDir).isEmpty)
        }
    }

    // MARK: - Empty-overwrite refusal

    @Test func emptySaveOverNonEmptyRegistryIsRefused() throws {
        try Self.withTempHome { ctx, path in
            let service = ProjectDashboardService(context: ctx)
            try service.saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "keep", path: "/tmp/keep"),
            ]))
            let before = try Self.read(path)

            #expect(throws: ProjectRegistryError.refusedEmptyOverwrite(path: path, existingCount: 1)) {
                try service.saveRegistry(ProjectRegistry(projects: []))
            }
            // Untouched on disk.
            #expect(try Self.read(path) == before)
            #expect(service.loadRegistry().projects.map(\.name) == ["keep"])
        }
    }

    @Test func deliberateEmptySaveIsAllowedWithOptIn() throws {
        try Self.withTempHome { ctx, _ in
            let service = ProjectDashboardService(context: ctx)
            try service.saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "last", path: "/tmp/last"),
            ]))
            try service.saveRegistry(ProjectRegistry(projects: []), allowEmpty: true)
            #expect(service.loadRegistry().projects.isEmpty)
        }
    }

    @Test func emptySaveOverEmptyRegistryIsFine() throws {
        try Self.withTempHome { ctx, _ in
            let service = ProjectDashboardService(context: ctx)
            try service.saveRegistry(ProjectRegistry(projects: []), allowEmpty: true)
            // Now a plain (non-opt-in) empty save has nothing to destroy.
            try service.saveRegistry(ProjectRegistry(projects: []))
            #expect(service.loadRegistry().projects.isEmpty)
        }
    }

    @Test func nonEmptySaveOverNonEmptyRegistryStillWorks() throws {
        try Self.withTempHome { ctx, _ in
            let service = ProjectDashboardService(context: ctx)
            try service.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "a", path: "/tmp/a")]))
            try service.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "b", path: "/tmp/b")]))
            #expect(service.loadRegistry().projects.map(\.name) == ["b"])
        }
    }

    // MARK: - Atomic write + rolling backup

    @Test func saveKeepsRollingBackupOfPreviousContents() throws {
        try Self.withTempHome { ctx, path in
            let service = ProjectDashboardService(context: ctx)
            let bak = path + ".bak"
            try service.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "v1", path: "/tmp/v1")]))
            // First write has nothing to back up.
            #expect(!FileManager.default.fileExists(atPath: bak))
            let v1 = try Self.read(path)

            try service.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "v2", path: "/tmp/v2")]))
            #expect(try Self.read(bak) == v1)

            let v2 = try Self.read(path)
            try service.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "v3", path: "/tmp/v3")]))
            // Rolling — one deep, always the immediately previous file.
            #expect(try Self.read(bak) == v2)
            #expect(service.loadRegistry().projects.map(\.name) == ["v3"])
        }
    }

    /// The backup must capture agent-written bytes too, not just what
    /// Scarf itself last wrote.
    @Test func backupCapturesForeignWrites() throws {
        try Self.withTempHome { ctx, path in
            let agentWritten = """
            {"projects":[{"name":"agent-added","path":"/tmp/agent"}]}
            """
            try Self.write(agentWritten, to: path)
            try ProjectDashboardService(context: ctx).saveRegistry(
                ProjectRegistry(projects: [ProjectEntry(name: "agent-added", path: "/tmp/agent")])
            )
            #expect(try Self.read(path + ".bak") == agentWritten)
        }
    }

    /// The write goes through the transport's atomic path: the registry
    /// is never observable as a partial file and no temp artefact is
    /// left beside it.
    @Test func saveLeavesNoPartialOrTempFiles() throws {
        try Self.withTempHome { ctx, path in
            let service = ProjectDashboardService(context: ctx)
            let many = (0..<200).map { ProjectEntry(name: "p\($0)", path: "/tmp/p\($0)", uuid: UUID()) }
            try service.saveRegistry(ProjectRegistry(projects: many))
            try service.saveRegistry(ProjectRegistry(projects: Array(many.dropLast())))

            let siblings = try FileManager.default.contentsOfDirectory(atPath: ctx.paths.scarfDir)
            #expect(!siblings.contains { $0.hasSuffix(".tmp") || $0.hasSuffix(".scarf.tmp") })
            #expect(Set(siblings).isSuperset(of: ["projects.json", "projects.json.bak"]))
            // Every byte of the last write is present and parses.
            #expect(service.loadRegistry().projects.count == 199)
            let onDisk = try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: path))
            ) as? [String: Any]
            #expect((onDisk?["projects"] as? [Any])?.count == 199)
        }
    }

    /// Concurrent savers must never leave a half-written or unparseable
    /// registry — a torn write here is exactly the corruption class this
    /// phase exists to eliminate.
    @Test func concurrentSavesAlwaysLeaveAParseableRegistry() async throws {
        try Self.withTempHome { ctx, path in
            let service = ProjectDashboardService(context: ctx)
            try service.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "seed", path: "/tmp/seed")]))

            DispatchQueue.concurrentPerform(iterations: 16) { i in
                let entries = (0...i).map { ProjectEntry(name: "c\($0)", path: "/tmp/c\($0)", uuid: UUID()) }
                try? service.saveRegistry(ProjectRegistry(projects: entries))
                _ = service.loadRegistryDetailed()
            }

            let final = ProjectDashboardService(context: ctx).loadRegistryDetailed()
            #expect(!final.registry.projects.isEmpty)
            #expect(!final.salvaged)
            #expect(Self.quarantineFiles(in: ctx.paths.scarfDir).isEmpty)
            #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) is [String: Any])
        }
    }
}
