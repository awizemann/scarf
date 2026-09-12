import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Integration coverage for the Mac-target apply-to-fleet write path
/// (`FleetApplyExecutor`) and the new `KanbanTenantResolver.setTenant`
/// primitive it relies on. Each test runs against an isolated temp Hermes
/// home via `ServerContext.local(home:)` so the registry write
/// (`ProjectStore.save`) never touches the developer's real `~/.hermes`.
///
/// Scope: the **model preset + board** write effect and the additive
/// board guard, end-to-end (manifest write → record re-derive). The
/// serverId→context routing is exercised because `.local(home:)` keeps the
/// well-known local id, so a target keyed on that id resolves to the
/// temp-home context. Cron apply needs the `hermes` CLI and a distinct
/// remote id, so it stays build-verified (its prompt-rewriting core is
/// unit-tested in `FleetApplyPlanTests`).
@Suite struct FleetApplyExecutorTests {

    // MARK: - Temp home / fixtures

    static func withTempHome(
        _ body: (ServerContext, _ projectsRoot: String) async throws -> Void
    ) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-fleetapply-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let projectsRoot = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try await body(ServerContext.local(home: home), projectsRoot.path)
    }

    static func makeProjectDir(_ projectsRoot: String, slug: String) throws -> String {
        let dir = projectsRoot + "/" + slug
        try FileManager.default.createDirectory(atPath: dir + "/.scarf", withIntermediateDirectories: true)
        return dir
    }

    /// A source materialization on a (fake) other host carrying the config
    /// to push. The serverId is deliberately not the local id — the
    /// executor only uses it to read source cron jobs, which these tests
    /// don't exercise.
    static func source(id: UUID, modelPresetId: String?, board: String?) -> FleetMaterialization {
        FleetMaterialization(
            serverId: "fake-source-host",
            serverDisplayName: "Source",
            project: ScarfProject(
                id: id, name: "Repo", rootPath: "/source/repo",
                modelPresetId: modelPresetId, board: board
            )
        )
    }

    /// A target materialization on the local temp-home host, rooted at a
    /// real on-disk dir, with the given pre-existing config.
    static func target(id: UUID, rootPath: String, board: String? = nil) -> FleetMaterialization {
        FleetMaterialization(
            serverId: ServerContext.local.id.uuidString,
            serverDisplayName: "Local",
            project: ScarfProject(id: id, name: "Repo", rootPath: rootPath, board: board)
        )
    }

    // MARK: - Executor: model + board

    @Test func appliesModelAndBoardToBareTarget() async throws {
        try await Self.withTempHome { ctx, projectsRoot in
            let id = UUID()
            let dir = try Self.makeProjectDir(projectsRoot, slug: "target")
            let src = Self.source(id: id, modelPresetId: "preset-x", board: "scarf:src")
            let tgt = Self.target(id: id, rootPath: dir)

            let plan = FleetApplyPlan.make(source: src, targets: [tgt], fields: [.modelPreset, .board])
            let results = await FleetApplyExecutor(contexts: [ctx]).execute(plan, source: src.project)

            try #require(results.count == 1)
            #expect(results[0].hadFailure == false)
            #expect(results[0].appliedCount == 2)

            // Manifest is the runtime source of truth.
            #expect(ProjectModelPresetReader(context: ctx).presetID(forProjectPath: dir) == "preset-x")
            #expect(KanbanTenantReader(context: ctx).tenant(forProjectPath: dir) == "scarf:src")

            // project.json record was re-derived to match — keeping the
            // stable id and reflecting the new config in the Fleet panel.
            let record = try #require(ProjectStore(context: ctx).load(projectPath: dir))
            #expect(record.id == id)
            #expect(record.modelPresetId == "preset-x")
            #expect(record.board == "scarf:src")
        }
    }

    @Test func boardNotClobberedWhenTargetAlreadyHasOne() async throws {
        try await Self.withTempHome { ctx, projectsRoot in
            let id = UUID()
            let dir = try Self.makeProjectDir(projectsRoot, slug: "hasboard")
            // Seed the target with an existing board (and persist it to the
            // manifest so the read-back is authoritative).
            try KanbanTenantResolver(context: ctx).setTenant("scarf:existing", for: ProjectEntry(name: "Repo", path: dir))

            let src = Self.source(id: id, modelPresetId: nil, board: "scarf:src")
            let tgt = Self.target(id: id, rootPath: dir, board: "scarf:existing")

            let plan = FleetApplyPlan.make(source: src, targets: [tgt], fields: [.board])
            let results = await FleetApplyExecutor(contexts: [ctx]).execute(plan, source: src.project)

            // Board action was skipped (additive: protect existing tasks).
            let boardField = results[0].fields.first { $0.field == .board }
            #expect(boardField?.status == .skipped)
            // ...and the target's existing board is untouched.
            #expect(KanbanTenantReader(context: ctx).tenant(forProjectPath: dir) == "scarf:existing")
        }
    }

    @Test func unregisteredServerYieldsFailureNotCrash() async throws {
        let id = UUID()
        let src = Self.source(id: id, modelPresetId: "preset-x", board: nil)
        // Target on a server id that isn't in `contexts` at all.
        let ghost = FleetMaterialization(
            serverId: UUID().uuidString,
            serverDisplayName: "Ghost",
            project: ScarfProject(id: id, name: "Repo", rootPath: "/ghost/repo")
        )
        let plan = FleetApplyPlan.make(source: src, targets: [ghost], fields: [.modelPreset])
        let results = await FleetApplyExecutor(contexts: []).execute(plan, source: src.project)

        try #require(results.count == 1)
        #expect(results[0].hadFailure == true)
    }
}

/// Disk-integration coverage for the explicit-slug `setTenant` setter
/// added for fleet apply. (The pure slug logic lives in
/// `KanbanTenantResolverSlugTests`.)
@Suite struct KanbanTenantResolverSetTenantTests {

    nonisolated static func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-settenant-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func setsExactSlugOnBareProject() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = ProjectEntry(name: "Bare", path: dir)
        let resolver = KanbanTenantResolver(context: .local)

        try resolver.setTenant("scarf:exact", for: project)
        #expect(try resolver.tenant(for: project) == "scarf:exact")
        // Sentinel manifest written.
        #expect(FileManager.default.fileExists(atPath: dir + "/.scarf/manifest.json"))
    }

    @Test func setTenantIsIdempotent() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = ProjectEntry(name: "Bare", path: dir)
        let resolver = KanbanTenantResolver(context: .local)

        try resolver.setTenant("scarf:x", for: project)
        let path = dir + "/.scarf/manifest.json"
        let firstMtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        try resolver.setTenant("scarf:x", for: project)  // no-op
        let secondMtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(firstMtime == secondMtime)
    }

    @Test func setTenantPreservesSiblingManifestFields() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let scarfDir = dir + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)
        try """
        {
          "schemaVersion": 3,
          "id": "author/example",
          "name": "Templated",
          "version": "1.0.0",
          "description": "demo",
          "contents": { "dashboard": true, "agentsMd": true },
          "modelPresetID": "keep-me"
        }
        """.data(using: .utf8)!.write(to: URL(fileURLWithPath: scarfDir + "/manifest.json"))

        let project = ProjectEntry(name: "Templated", path: dir)
        try KanbanTenantResolver(context: .local).setTenant("scarf:new", for: project)

        // Verify via the projection readers, not raw substring matching —
        // JSONEncoder escapes "/" as "\/" by default, so the slashed
        // template id wouldn't match a naive `contains("author/example")`.
        let data = try Data(contentsOf: URL(fileURLWithPath: scarfDir + "/manifest.json"))
        #expect(KanbanTenantReader.tenant(fromManifestData: data) == "scarf:new")
        // The pre-existing modelPresetID sibling survives the tenant write.
        #expect(ProjectModelPresetReader.presetID(fromManifestData: data) == "keep-me")
    }

    // MARK: - Cron field verdict

    /// A pass that created nothing because every job was script-only
    /// (`no_agent`, whose `pre_run_script` fleet-apply does not replicate)
    /// used to report `.applied` — a green "applied" row, and a bump to
    /// `TargetResult.appliedCount`, for a target where not one job was
    /// written. It is `.skipped`.
    @Test func cronFieldIsSkippedWhenEveryJobWasScriptOnly() {
        #expect(FleetApplyExecutor.cronFieldStatus(created: 0, failed: 0, scriptOnlySkipped: 3) == .skipped)
        #expect(FleetApplyExecutor.cronFieldStatus(created: 0, failed: 0, scriptOnlySkipped: 1) == .skipped)
    }

    @Test func cronFieldStatusKeepsItsOtherVerdicts() {
        // Nothing landed and something errored → failed, script-only or not.
        #expect(FleetApplyExecutor.cronFieldStatus(created: 0, failed: 2, scriptOnlySkipped: 0) == .failed)
        #expect(FleetApplyExecutor.cronFieldStatus(created: 0, failed: 1, scriptOnlySkipped: 1) == .failed)
        // Something landed and nothing errored → applied, even alongside a skip.
        #expect(FleetApplyExecutor.cronFieldStatus(created: 1, failed: 0, scriptOnlySkipped: 2) == .applied)
        // Nothing to do at all, and nothing declined: the target is already
        // in the desired state, which is applied — not skipped.
        #expect(FleetApplyExecutor.cronFieldStatus(created: 0, failed: 0, scriptOnlySkipped: 0) == .applied)
    }

    // MARK: - P18: the two verdicts the `scriptOnlySkipped` fix didn't reach

    /// A PARTLY failed pass is not `.applied`. This assertion used to read
    /// `created: 2, failed: 1 == .applied` — the same lie P17 removed for
    /// script-only skips, one arm over: `status` is what
    /// `TargetResult.appliedCount` counts and what the row badge paints, so
    /// a green "applied" for a field where a `cron create` errored hides the
    /// failure behind a count in the message text.
    @Test func cronFieldIsFailedWhenAnyCreateErroredEvenIfOthersLanded() {
        #expect(FleetApplyExecutor.cronFieldStatus(created: 2, failed: 1, scriptOnlySkipped: 0) == .failed)
        #expect(FleetApplyExecutor.cronFieldStatus(created: 5, failed: 1, scriptOnlySkipped: 1) == .failed)
    }

    /// A pass CANCELLED before it wrote anything is `.skipped`, not
    /// `.applied`. `cancelledRemaining` was simply not an input to the
    /// verdict, so cancelling a fleet apply mid-run reported every
    /// untouched target's cron field as applied. Cancellation landing
    /// BETWEEN targets already reports `.skipped` "cancelled before apply"
    /// (`FleetApplyExecutor.swift:153`); landing between cron creates must
    /// not read differently.
    @Test func cronFieldIsSkippedWhenCancelledWithNothingWritten() {
        #expect(FleetApplyExecutor.cronFieldStatus(
            created: 0, failed: 0, scriptOnlySkipped: 0, cancelledRemaining: 4) == .skipped)
        // …but a cancel AFTER something landed is a real partial apply: the
        // created jobs are live on the host and the message says how many
        // were cancelled.
        #expect(FleetApplyExecutor.cronFieldStatus(
            created: 1, failed: 0, scriptOnlySkipped: 0, cancelledRemaining: 3) == .applied)
    }

}
