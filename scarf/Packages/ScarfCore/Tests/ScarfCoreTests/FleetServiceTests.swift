import Testing
import Foundation
@testable import ScarfCore

/// Coverage for the Fleet/Portfolio dimension (Phase-1 item #4): the pure
/// `ProjectPortfolio.build(from:)` grouping + `FleetDrift.compute`, and the
/// disk-backed `FleetService.portfolio()` gather wiring.
///
/// Multi-host scenarios are exercised through the pure builder with
/// synthetic distinct `serverId`s — `ServerContext.local(home:)` always
/// reuses the fixed local id, so it can't stand in for two servers. The
/// disk gather is verified once against a single temp home (the per-host
/// I/O is a thin `ProjectStore.list()` map; the grouping is what carries
/// the logic).
@Suite struct FleetServiceTests {

    // MARK: - Fixtures

    /// A `ScarfProject` with a fixed id and the policy-relevant fields
    /// overridable, so a group can be assembled with controlled drift.
    static func project(
        id: UUID,
        name: String = "Proj",
        rootPath: String = "/p",
        updatedAt: Date = Date(timeIntervalSince1970: 1_000),
        modelPresetId: String? = nil,
        board: String? = nil,
        cronJobIds: [String] = [],
        memoryNamespace: String? = nil,
        miniApps: [ScarfProject.MiniAppRef] = []
    ) -> ScarfProject {
        ScarfProject(
            id: id,
            name: name,
            rootPath: rootPath,
            updatedAt: updatedAt,
            modelPresetId: modelPresetId,
            board: board,
            cronJobIds: cronJobIds,
            memoryNamespace: memoryNamespace,
            miniApps: miniApps
        )
    }

    static func host(_ serverId: String, _ name: String?, _ projects: [ScarfProject]) -> ProjectPortfolio.HostProjects {
        ProjectPortfolio.HostProjects(serverId: serverId, serverDisplayName: name, projects: projects)
    }

    // MARK: - Grouping

    @Test func groupsSameIdAcrossHosts() throws {
        let id = UUID()
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv-a", "Alpha host", [Self.project(id: id, name: "Repo", rootPath: "/a/repo")]),
            Self.host("srv-b", "Beta host", [Self.project(id: id, name: "Repo", rootPath: "/b/repo")]),
        ])

        #expect(portfolio.projects.count == 1)
        let fleet = try #require(portfolio.project(id: id))
        #expect(fleet.isMultiHost)
        #expect(fleet.materializations.count == 2)
        // Sorted by serverId.
        #expect(fleet.materializations.map(\.serverId) == ["srv-a", "srv-b"])
        // Each host keeps its own root path.
        #expect(fleet.materialization(serverId: "srv-a")?.project.rootPath == "/a/repo")
        #expect(fleet.materialization(serverId: "srv-b")?.project.rootPath == "/b/repo")
        #expect(fleet.materialization(serverId: "srv-a")?.serverDisplayName == "Alpha host")
    }

    @Test func distinctIdsStaySeparate() {
        let a = UUID(), b = UUID()
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv-a", "A", [
                Self.project(id: a, name: "Apple"),
                Self.project(id: b, name: "Banana"),
            ]),
        ])
        #expect(portfolio.projects.count == 2)
        #expect(portfolio.project(id: a)?.isMultiHost == false)
        #expect(portfolio.multiHostProjects.isEmpty)
    }

    @Test func portfolioSortedByNameThenId() {
        let z = UUID(), a = UUID()
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv", "S", [
                Self.project(id: z, name: "Zebra"),
                Self.project(id: a, name: "apple"),  // lowercase — case-insensitive sort
            ]),
        ])
        #expect(portfolio.projects.map(\.name) == ["apple", "Zebra"])
    }

    @Test func duplicateIdOnSameHostFirstWins() throws {
        let id = UUID()
        // Defensive: one host listing the same id twice (shouldn't happen
        // — one record per path) collapses to a single materialization.
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv", "S", [
                Self.project(id: id, name: "First", rootPath: "/first"),
                Self.project(id: id, name: "Second", rootPath: "/second"),
            ]),
        ])
        let fleet = try #require(portfolio.project(id: id))
        #expect(fleet.materializations.count == 1)
        #expect(fleet.materializations.first?.project.rootPath == "/first")
    }

    // MARK: - Canonical name

    @Test func canonicalNameFromMostRecentlyUpdatedHost() throws {
        let id = UUID()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv-a", "A", [Self.project(id: id, name: "Old Name", updatedAt: older)]),
            Self.host("srv-b", "B", [Self.project(id: id, name: "New Name", updatedAt: newer)]),
        ])
        let fleet = try #require(portfolio.project(id: id))
        #expect(fleet.name == "New Name")
        // ...but the name disagreement is surfaced as drift.
        #expect(fleet.drift.has(.name))
    }

    // MARK: - Drift

    @Test func singleHostNeverDrifts() {
        let id = UUID()
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv", "S", [Self.project(id: id, modelPresetId: "x", board: "scarf:y")]),
        ])
        #expect(portfolio.project(id: id)?.drift.isEmpty == true)
    }

    @Test func agreeingHostsHaveNoDrift() {
        let id = UUID()
        let p1 = Self.project(id: id, name: "Same", rootPath: "/a", modelPresetId: "m1", board: "scarf:b", cronJobIds: ["j1"])
        let p2 = Self.project(id: id, name: "Same", rootPath: "/b", modelPresetId: "m1", board: "scarf:b", cronJobIds: ["j9"])
        // Note cron job *ids* differ (host-local) but the COUNT matches → no cron drift.
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv-a", "A", [p1]),
            Self.host("srv-b", "B", [p2]),
        ])
        #expect(portfolio.project(id: id)?.drift.isEmpty == true)
    }

    @Test func modelPresetDriftDetected() throws {
        let id = UUID()
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv-a", "A", [Self.project(id: id, modelPresetId: "fast")]),
            Self.host("srv-b", "B", [Self.project(id: id, modelPresetId: nil)]),  // bound vs default
        ])
        let drift = try #require(portfolio.project(id: id)?.drift)
        #expect(drift.has(.modelPreset))
        #expect(!drift.has(.board))
    }

    @Test func boardAndCronCountDriftDetected() throws {
        let id = UUID()
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv-a", "A", [Self.project(id: id, board: "scarf:a", cronJobIds: ["j1", "j2"])]),
            Self.host("srv-b", "B", [Self.project(id: id, board: "scarf:b", cronJobIds: ["j1"])]),
        ])
        let drift = try #require(portfolio.project(id: id)?.drift)
        #expect(drift.has(.board))
        #expect(drift.has(.cron))
    }

    @Test func memoryAndMiniAppDriftDetected() throws {
        let id = UUID()
        let portfolio = ProjectPortfolio.build(from: [
            Self.host("srv-a", "A", [Self.project(id: id, memoryNamespace: "ns1",
                miniApps: [ScarfProject.MiniAppRef(id: "viz")])]),
            Self.host("srv-b", "B", [Self.project(id: id, memoryNamespace: "ns2", miniApps: [])]),
        ])
        let drift = try #require(portfolio.project(id: id)?.drift)
        #expect(drift.has(.memoryNamespace))
        #expect(drift.has(.miniApps))
        // Sorted fields are deterministic for display.
        #expect(drift.sortedFields == drift.sortedFields.sorted())
    }

    // MARK: - Disk-backed gather

    @Test func portfolioGathersFromProjectStore() throws {
        try ProjectStoreTests.withTempHome { ctx, projectsRoot in
            let dirA = try ProjectStoreTests.makeProjectDir(projectsRoot, slug: "alpha")
            let dirB = try ProjectStoreTests.makeProjectDir(projectsRoot, slug: "beta")
            let store = ProjectStore(context: ctx)
            try store.save(ScarfProject(name: "Alpha", rootPath: dirA, board: "scarf:alpha"))
            try store.save(ScarfProject(name: "Beta", rootPath: dirB))

            let portfolio = FleetService(contexts: [ctx]).portfolio()

            #expect(portfolio.projects.count == 2)
            // Single registered server → every project is single-host on
            // the well-known local id.
            for fleet in portfolio.projects {
                #expect(fleet.materializations.count == 1)
                #expect(fleet.materializations.first?.serverId == ServerContext.local.id.uuidString)
                #expect(fleet.drift.isEmpty)
            }
            #expect(portfolio.projects.contains { $0.name == "Alpha" })
            #expect(portfolio.projects.contains { $0.name == "Beta" })
        }
    }

    @Test func gatherSkipsRowsWithoutStableID() throws {
        try ProjectStoreTests.withTempHome { ctx, projectsRoot in
            let dirSaved = try ProjectStoreTests.makeProjectDir(projectsRoot, slug: "saved")
            let dirUUID = try ProjectStoreTests.makeProjectDir(projectsRoot, slug: "uuidonly")
            let dirBare = try ProjectStoreTests.makeProjectDir(projectsRoot, slug: "bare")
            let store = ProjectStore(context: ctx)

            // (1) record on disk → stable id from the record.
            let saved = ScarfProject(name: "Saved", rootPath: dirSaved)
            try store.save(saved)

            // Registry with three rows: a record-backed one, one with a
            // registry uuid but NO record, and a bare one with neither.
            let uuidOnly = UUID()
            try ProjectDashboardService(context: ctx).saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "Saved", path: dirSaved, uuid: saved.id),
                ProjectEntry(name: "UUIDOnly", path: dirUUID, uuid: uuidOnly),
                ProjectEntry(name: "Bare", path: dirBare),  // no uuid, no record
            ]))

            let portfolio = FleetService(contexts: [ctx]).portfolio()

            // The bare row is EXCLUDED — minting a transient id for it would
            // create a flickering phantom that never groups across hosts.
            #expect(portfolio.projects.count == 2)
            #expect(portfolio.project(id: saved.id) != nil)
            #expect(portfolio.project(id: uuidOnly) != nil)   // stable via registry uuid
            #expect(!portfolio.projects.contains { $0.name == "Bare" })
        }
    }

    @Test func fleetProjectLookupByID() throws {
        try ProjectStoreTests.withTempHome { ctx, projectsRoot in
            let dir = try ProjectStoreTests.makeProjectDir(projectsRoot, slug: "gamma")
            let store = ProjectStore(context: ctx)
            let project = ScarfProject(name: "Gamma", rootPath: dir, modelPresetId: "preset-1")
            try store.save(project)

            let fleet = FleetService(contexts: [ctx]).fleetProject(id: project.id)
            #expect(fleet?.id == project.id)
            #expect(fleet?.materializations.first?.project.modelPresetId == "preset-1")
            #expect(FleetService(contexts: [ctx]).fleetProject(id: UUID()) == nil)
        }
    }
}
