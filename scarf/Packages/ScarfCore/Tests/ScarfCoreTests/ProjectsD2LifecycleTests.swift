import Testing
import Foundation
@testable import ScarfCore

/// D2 (t-a2c169f0): lifecycle integrity — the transitions that used to
/// update one store and leave the other four describing a project that no
/// longer exists in that shape.
///
/// Real `ProjectsViewModel` / `ProjectStore` / `ProjectDoctorService`
/// against a real temp Hermes home. Nothing is stubbed, so a regression in
/// the service surfaces here instead of passing against a mock.
@MainActor
@Suite struct ProjectsD2LifecycleTests {

    // MARK: - Harness

    static func withTempHome(
        _ body: (ServerContext, _ projectsRoot: String) throws -> Void
    ) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-d2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        let projectsRoot = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: ctx.paths.scarfDir, withIntermediateDirectories: true
        )
        try body(ctx, projectsRoot.path)
    }

    @discardableResult
    static func makeProject(
        _ ctx: ServerContext, root: String, slug: String, name: String
    ) throws -> ScarfProject {
        let dir = root + "/" + slug
        try FileManager.default.createDirectory(
            atPath: dir + "/.scarf", withIntermediateDirectories: true
        )
        let project = ScarfProject(name: name, rootPath: dir)
        try ProjectStore(context: ctx).save(project)
        return project
    }

    static func loadedVM(_ ctx: ServerContext) -> ProjectsViewModel {
        let vm = ProjectsViewModel(context: ctx)
        vm.load()
        return vm
    }

    // MARK: - H6: rename propagates to the canonical record

    /// The record's `name` is what `renderAgentContextBlock` injects into
    /// every chat opened in the project. A rename that only touched the
    /// registry meant the agent was told the OLD name forever.
    @Test func renamePropagatesIntoTheProjectRecord() throws {
        try Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let vm = Self.loadedVM(ctx)
            let row = try #require(vm.projects.first)

            #expect(vm.renameProject(row, to: "Renamed"))

            let record = try #require(ProjectStore(context: ctx).load(projectPath: project.rootPath))
            #expect(record.name == "Renamed")
            // The identity must NOT move with the label.
            #expect(record.id == project.id)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.first?.name == "Renamed")
        }
    }

    /// A rename whose record can't be written still succeeds — the registry
    /// write is the one the user sees. The doctor is the backstop, and the
    /// next test proves it fires.
    @Test func renameStillSucceedsWhenThereIsNoRecordToPropagateInto() throws {
        try Self.withTempHome { ctx, root in
            let dir = root + "/bare"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try ProjectDashboardService(context: ctx).saveRegistry(
                ProjectRegistry(projects: [ProjectEntry(name: "Bare", path: dir)])
            )
            let vm = Self.loadedVM(ctx)
            #expect(vm.renameProject(try #require(vm.projects.first), to: "Still Fine"))
            #expect(vm.mutationError == nil)
        }
    }

    // MARK: - H7: the doctor can see divergence

    @Test func doctorReportsAndRepairsANameDivergence() throws {
        try Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            // The pre-propagation state: registry renamed, record stale.
            var registry = ProjectDashboardService(context: ctx).loadRegistry()
            registry.projects[0] = ProjectEntry(
                name: "New Name", path: project.rootPath, uuid: project.id
            )
            try ProjectDashboardService(context: ctx).saveRegistry(registry)

            let doctor = ProjectDoctorService(context: ctx)
            let found = doctor.diagnose().findings.filter { $0.kind == .recordNameMismatch }
            #expect(found.count == 1)
            #expect(found.first?.repair == .renameRecordFromRegistry(path: project.rootPath))
            #expect(found.first?.repair?.isSafe == true)

            try doctor.repair(try #require(found.first))
            #expect(ProjectStore(context: ctx).load(projectPath: project.rootPath)?.name == "New Name")
            #expect(doctor.diagnose().findings.filter { $0.kind == .recordNameMismatch }.isEmpty)
        }
    }

    /// The move case: a record found at X declaring it belongs at Y. Every
    /// writer underneath addresses the project by `record.rootPath`, so
    /// this is reported and never auto-repaired.
    @Test func doctorReportsAMovedProjectAndOffersNoRepair() throws {
        try Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "moved", name: "Moved")
            // Simulate the hand-move: the record still names the old home.
            var record = try #require(ProjectStore(context: ctx).load(projectPath: project.rootPath))
            let oldPath = root + "/before-the-move"
            record.rootPath = oldPath
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(
                to: URL(fileURLWithPath: ProjectStore.recordPath(forProjectPath: project.rootPath))
            )

            let found = ProjectDoctorService(context: ctx).diagnose()
                .findings.filter { $0.kind == .recordPathDivergence }
            #expect(found.count == 1)
            #expect(found.first?.severity == .high)
            #expect(found.first?.repair == nil)
            #expect(found.first?.detail.contains(oldPath) == true)
        }
    }

    @Test func aHealthyProjectProducesNeitherDivergenceFinding() throws {
        try Self.withTempHome { ctx, root in
            try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let report = ProjectDoctorService(context: ctx).diagnose()
            #expect(report.findings.filter { $0.kind == .recordNameMismatch }.isEmpty)
            #expect(report.findings.filter { $0.kind == .recordPathDivergence }.isEmpty)
            #expect(report.isHealthy)
        }
    }

    // MARK: - Removal is keyed by identity, not by display name

    /// The registry can hold two rows with one name — the doctor reports it
    /// as a `duplicateName` finding the user is meant to be able to resolve
    /// row by row. Name-keyed removal made that impossible: removing either
    /// one removed both.
    @Test func removingOneOfTwoRowsSharingANameLeavesTheOther() throws {
        try Self.withTempHome { ctx, root in
            let a = try Self.makeProject(ctx, root: root, slug: "a", name: "Twin")
            let b = try Self.makeProject(ctx, root: root, slug: "b", name: "Other")
            // Force the name collision behind the store's back.
            var registry = ProjectDashboardService(context: ctx).loadRegistry()
            for i in registry.projects.indices {
                registry.projects[i] = ProjectEntry(
                    name: "Twin",
                    path: registry.projects[i].path,
                    uuid: registry.projects[i].uuid
                )
            }
            try ProjectDashboardService(context: ctx).saveRegistry(registry)

            let vm = Self.loadedVM(ctx)
            let target = try #require(vm.projects.first { $0.uuid == a.id })
            #expect(vm.removeProject(target))

            let rows = ProjectDashboardService(context: ctx).loadRegistry().projects
            #expect(rows.count == 1)
            #expect(rows.first?.uuid == b.id)
        }
    }

    // MARK: - Removal cleans up what lives outside the registry

    @Test func removalRevokesGrantsAndStripsTheAgentsBlock() throws {
        try Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let grants = MiniAppGrantStore(context: ctx)
            try grants.setGrant(
                projectId: project.id.uuidString, miniAppId: "dash", permissions: [.store]
            )
            let agentsPath = project.rootPath + "/AGENTS.md"
            let block = ProjectStore(context: ctx).renderAgentContextBlock(for: project)
            try Data((block + "\n\nUser's own notes.\n").utf8)
                .write(to: URL(fileURLWithPath: agentsPath))

            let vm = Self.loadedVM(ctx)
            #expect(vm.removeProject(try #require(vm.projects.first)))

            // Grants gone — otherwise re-using this folder resurrects them,
            // ids being derived from (host, path).
            #expect(grants.hasDecision(projectId: project.id.uuidString, miniAppId: "dash") == false)
            // Block gone, user's prose intact.
            let after = try String(contentsOfFile: agentsPath, encoding: .utf8)
            #expect(!after.contains(ProjectContextBlock.beginMarker))
            #expect(after.contains("User's own notes."))
        }
    }

    @Test func removalOfAProjectWhoseFolderIsGoneStillSucceeds() throws {
        try Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            try FileManager.default.removeItem(atPath: project.rootPath)
            let vm = Self.loadedVM(ctx)
            #expect(vm.removeProject(try #require(vm.projects.first)))
            #expect(vm.mutationError == nil)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.isEmpty)
        }
    }

    // MARK: - Archive is no longer inert

    @Test func archivingStopsTheProjectBeingWatched() throws {
        try Self.withTempHome { ctx, root in
            try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            try Self.makeProject(ctx, root: root, slug: "beta", name: "Beta")
            let vm = Self.loadedVM(ctx)
            #expect(vm.dashboardPaths.count == 2)
            #expect(vm.projectScarfDirs.count == 2)

            let alpha = try #require(vm.projects.first { $0.name == "Alpha" })
            #expect(vm.archiveProject(alpha))

            #expect(vm.dashboardPaths.count == 1)
            #expect(vm.projectScarfDirs.count == 1)
            #expect(vm.dashboardPaths.allSatisfy { $0.contains("/beta/") })
        }
    }

    @Test func unarchivingPutsTheProjectBackUnderWatch() throws {
        try Self.withTempHome { ctx, root in
            try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let vm = Self.loadedVM(ctx)
            let alpha = try #require(vm.projects.first)
            #expect(vm.archiveProject(alpha))
            #expect(vm.dashboardPaths.isEmpty)
            let archived = try #require(vm.projects.first)
            #expect(vm.unarchiveProject(archived))
            #expect(vm.dashboardPaths.count == 1)
        }
    }

    /// `setCronPaused` resolves the jobs it will act on from the SAME tags
    /// `ProjectStore.derive` uses. With no cron file there is nothing to
    /// pause and nothing to fail — archiving a project on a host without
    /// Hermes running must not report an error.
    @Test func archivingWithNoCronJobsIsANoOp() throws {
        try Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let lifecycle = ProjectLifecycleService(context: ctx)
            #expect(lifecycle.cronJobIDs(for: ProjectEntry(
                name: "Alpha", path: project.rootPath, uuid: project.id
            )).isEmpty)
            #expect(lifecycle.setCronPaused(true, for: ProjectEntry(
                name: "Alpha", path: project.rootPath, uuid: project.id
            )).isEmpty)
        }
    }

    // MARK: - Root policy at the app's own door

    @Test func theSidebarRefusesAnAbsurdProjectRoot() throws {
        try Self.withTempHome { ctx, _ in
            let vm = Self.loadedVM(ctx)
            #expect(vm.addProject(name: "Everything", path: "/") == false)
            #expect(vm.mutationError != nil)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.isEmpty)
        }
    }

    // MARK: - AGENTS.md block removal is surgical

    @Test func removingTheContextBlockPreservesEverythingAroundIt() {
        let block = ProjectContextBlock.beginMarker + "\nmanaged\n" + ProjectContextBlock.endMarker
        let before = "# Title\n\nProse above.\n\n" + block + "\n\nProse below.\n"
        let after = ProjectContextBlock.removeBlock(from: before)
        #expect(!after.contains(ProjectContextBlock.beginMarker))
        #expect(after.contains("Prose above."))
        #expect(after.contains("Prose below."))
        #expect(after.contains("# Title"))
    }

    @Test func removingTheContextBlockIsANoOpWhenThereIsNone() {
        let text = "# Just a file\n\nNothing managed here.\n"
        #expect(ProjectContextBlock.removeBlock(from: text) == text)
    }

    /// A file with only an opening marker cannot be bounded — guessing
    /// where the block ends would eat the user's text.
    @Test func removingTheContextBlockRefusesAnUnboundedRegion() {
        let text = ProjectContextBlock.beginMarker + "\nhalf a block\nuser text\n"
        #expect(ProjectContextBlock.removeBlock(from: text) == text)
    }

    @Test func applyThenRemoveReturnsToTheOriginalShape() {
        let original = "# Notes\n\nMine.\n"
        let block = ProjectContextBlock.beginMarker + "\nx\n" + ProjectContextBlock.endMarker
        let withBlock = ProjectContextBlock.applyBlock(block, to: original)
        #expect(withBlock.contains(ProjectContextBlock.beginMarker))
        let removed = ProjectContextBlock.removeBlock(from: withBlock)
        #expect(removed.contains("# Notes"))
        #expect(removed.contains("Mine."))
        #expect(!removed.contains(ProjectContextBlock.beginMarker))
    }

    // MARK: - Normalization uniformity

    /// `loadOrDerive` looked its row up with a raw `==`, so a registry that
    /// spelled the folder with a trailing slash missed the row and derived
    /// from a uuid-less entry — keying the AGENTS.md block on the interim
    /// path-derived id instead of the registry's.
    @Test func loadOrDeriveFindsTheRowThroughADifferentPathSpelling() throws {
        try Self.withTempHome { ctx, root in
            let dir = root + "/alpha"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let asserted = UUID()
            try ProjectDashboardService(context: ctx).saveRegistry(
                ProjectRegistry(projects: [
                    ProjectEntry(name: "Alpha", path: dir + "/", uuid: asserted)
                ])
            )
            let derived = ProjectStore(context: ctx).loadOrDerive(projectPath: dir, name: "Alpha")
            #expect(derived.id == asserted)
        }
    }
}
