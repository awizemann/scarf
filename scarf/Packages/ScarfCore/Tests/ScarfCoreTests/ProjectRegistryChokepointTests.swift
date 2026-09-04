import Testing
import Foundation
@testable import ScarfCore

/// The registry write CHOKEPOINT: `ProjectDashboardService.saveRegistry`
/// and `ProjectStore.indexInRegistry` refuse a lossy rewrite themselves,
/// so a writer that never heard of the rule cannot destroy anything.
///
/// The rule these pin (one definition, app-wide — `RegistryLoss`):
/// **losing whole ROWS blocks a write; losing a FIELD does not.** Plus the
/// zero-byte / unreadable case, which used to read as a healthy empty list.
///
/// Every test drives the REAL services against a per-test temp Hermes home,
/// so the local transport does actual file I/O.
@Suite struct ProjectRegistryChokepointTests {

    static func withTempHome(_ body: (ServerContext, _ registryPath: String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-chokepoint-test-\(UUID().uuidString)", isDirectory: true)
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

    /// A registry whose second row is undecodable: the row is DROPPED, so
    /// any rewrite deletes that project from the file for good.
    static let rowLossJSON = """
    {
      "projects": [
        { "name": "keep", "path": "/tmp/keep" },
        { "path": "/tmp/nameless" }
      ]
    }
    """

    /// A registry whose rows all survive, one having lost a FIELD.
    static let fieldLossJSON = """
    {
      "projects": [
        { "name": "keep", "path": "/tmp/keep", "folder": 17, "archived": "yes" }
      ]
    }
    """

    // MARK: - H1: the chokepoint refuses, whoever is calling

    /// The guard the five unguarded writers (cockpit, upgrade, installer
    /// ×2, fleet apply) were missing. It is not their job any more.
    @Test func saveRefusesWhenTheFileOnDiskLostRows() throws {
        try Self.withTempHome { ctx, path in
            try Self.write(Self.rowLossJSON, to: path)
            let service = ProjectDashboardService(context: ctx)
            let loaded = service.loadRegistryDetailed()
            #expect(loaded.registry.projects.map(\.name) == ["keep"])
            #expect(loaded.loss == .rowsDropped(count: 1, path: path))

            // Exactly what an unguarded writer does: save back what it read.
            #expect(throws: ProjectRegistryError.refusedLossyOverwrite(
                path: path, loss: .rowsDropped(count: 1, path: path)
            )) {
                try service.saveRegistry(loaded.registry)
            }
            // The unreadable row is still in the file.
            #expect(try Self.read(path).contains("/tmp/nameless"))
            // And no backup was minted from a write that never happened.
            #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
        }
    }

    /// `ProjectStore.indexInRegistry` is the second chokepoint: it refuses
    /// BEFORE appending its row, so `ProjectStore.save` — the call behind
    /// the cockpit's `try? save`, the installer and `FleetApplyExecutor` —
    /// cannot index into a salvaged list.
    @Test func indexInRegistryRefusesOverALossyRegistry() throws {
        try Self.withTempHome { ctx, path in
            let dir = (path as NSString).deletingLastPathComponent + "/proj"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Self.write(Self.rowLossJSON, to: path)
            let before = try Self.read(path)

            let store = ProjectStore(context: ctx)
            let record = store.derive(from: ProjectEntry(name: "newcomer", path: dir))
            #expect(throws: ProjectRegistryError.self) {
                try store.indexInRegistry(record)
            }
            #expect(try Self.read(path) == before)

            // `save` goes through the same chokepoint, so the registry half
            // fails too — the record half is allowed to have landed.
            #expect(throws: ProjectRegistryError.self) {
                try store.save(record)
            }
            #expect(try Self.read(path) == before)
        }
    }

    /// The counterpart, and the whole point of M1: FIELD salvage must NOT
    /// block. A row that lost its folder still saves — otherwise one
    /// hand-typed value freezes every project mutation in the app.
    @Test func saveIsAllowedWhenOnlyFieldsWereSalvaged() throws {
        try Self.withTempHome { ctx, path in
            try Self.write(Self.fieldLossJSON, to: path)
            let service = ProjectDashboardService(context: ctx)
            var loaded = service.loadRegistryDetailed()
            #expect(loaded.salvaged)          // the banner still says so
            #expect(loaded.loss == nil)       // the write guard does not

            loaded.registry.projects.append(ProjectEntry(name: "second", path: "/tmp/second"))
            try service.saveRegistry(loaded.registry)
            #expect(service.loadRegistry().projects.map(\.name) == ["keep", "second"])
        }
    }

    /// A quarantined file is unwritable-over too: the live list is not the
    /// file's contents, and replacing it would leave the user's projects
    /// only in a `.corrupt-` copy they never asked for.
    @Test func saveRefusesOverAQuarantinedRegistry() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("{ not json at all ][", to: path)
            let service = ProjectDashboardService(context: ctx)
            let quarantine = try #require(service.loadRegistryDetailed().quarantinePath)

            #expect(throws: ProjectRegistryError.refusedLossyOverwrite(
                path: path, loss: .quarantined(path: quarantine)
            )) {
                try service.saveRegistry(ProjectRegistry(projects: [
                    ProjectEntry(name: "new", path: "/tmp/new"),
                ]))
            }
            #expect(try Self.read(path) == "{ not json at all ][")
        }
    }

    // MARK: - M8: zero-byte / unreadable is damage, not an empty list

    @Test func zeroByteRegistryIsLossyRatherThanCleanEmpty() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("", to: path)
            let service = ProjectDashboardService(context: ctx)
            let loaded = service.loadRegistryDetailed()
            #expect(loaded.registry.projects.isEmpty)
            #expect(loaded.salvaged)
            #expect(loaded.loss == .unreadable(path: path))

            #expect(throws: ProjectRegistryError.refusedLossyOverwrite(
                path: path, loss: .unreadable(path: path)
            )) {
                try service.saveRegistry(ProjectRegistry(projects: [
                    ProjectEntry(name: "new", path: "/tmp/new"),
                ]))
            }
            // Even the DELIBERATE emptying opt-in doesn't get past it: the
            // opt-in says "I meant to empty it", not "I read it".
            #expect(throws: ProjectRegistryError.self) {
                try service.saveRegistry(ProjectRegistry(projects: []), allowEmpty: true)
            }
        }
    }

    /// The escape hatch has to exist, or a truncated file bricks projects
    /// forever: deleting it is a fresh start, and a MISSING registry stays
    /// clean and writable (first launch is the same state).
    @Test func deletingAnUnreadableRegistryRestoresWrites() throws {
        try Self.withTempHome { ctx, path in
            try Self.write("", to: path)
            let service = ProjectDashboardService(context: ctx)
            #expect(service.loadRegistryDetailed().loss != nil)

            try FileManager.default.removeItem(atPath: path)
            let fresh = service.loadRegistryDetailed()
            #expect(fresh.loss == nil)
            #expect(!fresh.salvaged)
            try service.saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "new", path: "/tmp/new"),
            ]))
            #expect(service.loadRegistry().projects.map(\.name) == ["new"])
        }
    }

    /// A registry that is a DIRECTORY reads as "exists but unreadable" —
    /// the shape of every I/O failure over a live transport. It must block
    /// rather than look like an empty list.
    @Test func unreadableRegistryBlocksWrites() throws {
        try Self.withTempHome { ctx, path in
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let service = ProjectDashboardService(context: ctx)
            let loaded = service.loadRegistryDetailed()
            #expect(loaded.loss == .unreadable(path: path))
            #expect(throws: ProjectRegistryError.self) {
                try service.saveRegistry(ProjectRegistry(projects: [
                    ProjectEntry(name: "new", path: "/tmp/new"),
                ]))
            }
        }
    }

    // MARK: - H3: the dashboard column count cannot crash a renderer

    /// `dashboard.json` is agent-written and both renderers feed
    /// `columnCount` straight to a `LazyVGrid`, which TRAPS on a
    /// non-positive column count (confirmed SIGTRAP) and grinds on an
    /// absurd one. Clamped on the READ path, so a bad section renders
    /// wrong instead of taking the app down — and so the two renderers
    /// cannot disagree about the bound.
    @Test func sectionColumnCountIsClampedForTheRenderers() throws {
        func section(_ columns: Int?) -> DashboardSection {
            DashboardSection(title: "s", columns: columns, widgets: [])
        }
        #expect(section(nil).columnCount == 3)      // unchanged default
        #expect(section(2).columnCount == 2)
        #expect(section(0).columnCount == 1)        // was a trap
        #expect(section(-4).columnCount == 1)       // was a trap
        #expect(section(9_999).columnCount == 12)
        // The clamp agrees with what the write-side validator accepts, so
        // a dashboard Scarf itself wrote is never altered by it.
        #expect(section(1).columnCount == 1)
        #expect(section(12).columnCount == 12)
    }

    /// The clamp has to survive the JSON path too — that is the only way
    /// these values ever arrive.
    @Test func negativeColumnCountFromJSONIsClamped() throws {
        let json = """
        {
          "version": 1, "title": "t",
          "sections": [ { "title": "s", "columns": -3, "widgets": [] } ]
        }
        """
        let dash = try JSONDecoder().decode(ProjectDashboard.self, from: Data(json.utf8))
        #expect(dash.sections.first?.columns == -3)      // preserved as written
        #expect(dash.sections.first?.columnCount == 1)   // never handed on as-is
    }

    // MARK: - The refusal is legible

    /// Every refusal message names the file the user has to go and fix.
    @Test func refusalMessagesNameTheFile() throws {
        try Self.withTempHome { ctx, path in
            try Self.write(Self.rowLossJSON, to: path)
            let service = ProjectDashboardService(context: ctx)
            do {
                try service.saveRegistry(service.loadRegistryDetailed().registry)
                Issue.record("expected a refusal")
            } catch let error as ProjectRegistryError {
                let message = try #require(error.errorDescription)
                #expect(message.contains(path))
                #expect(message.contains("1 project"))
            }
        }
    }
}
