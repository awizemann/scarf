import Testing
import Foundation
@testable import ScarfCore

/// Phase 2 of projects-first-class: no user-initiated project mutation
/// may fail silently, and registry damage has to be visible.
///
/// These drive the REAL `ProjectsViewModel` against a real
/// `ProjectDashboardService` on a real temp Hermes home, and produce
/// real failures — a chmod'd 0555 directory the local transport
/// genuinely cannot write into, and the Phase-1 empty-overwrite
/// refusal. Nothing here mocks Scarf's own code, so a regression in
/// the service surfaces here rather than passing against a stub.
@MainActor
@Suite struct ProjectsViewModelErrorSurfacingTests {

    // MARK: - Harness

    static func withTempHome(_ body: (ServerContext, _ registryPath: String) async throws -> Void) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-projects-vm-\(UUID().uuidString)", isDirectory: true)
        let ctx = ServerContext.local(home: home)
        try FileManager.default.createDirectory(
            atPath: ctx.paths.scarfDir, withIntermediateDirectories: true
        )
        defer {
            // Undo any read-only mode a test left behind, or the temp
            // dir leaks (and a leaked 0555 dir is a landmine for the
            // next run of the suite).
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: ctx.paths.scarfDir
            )
            try? FileManager.default.removeItem(at: home)
        }
        try await body(ctx, ctx.paths.projectsRegistry)
    }

    static func seed(_ projects: [ProjectEntry], context: ServerContext) throws {
        try ProjectDashboardService(context: context)
            .saveRegistry(ProjectRegistry(projects: projects), allowEmpty: true)
    }

    static func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    /// Make the registry's directory unwritable, so every
    /// `transport.writeFile` into it genuinely fails.
    static func makeReadOnly(_ context: ServerContext) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: context.paths.scarfDir
        )
    }

    // MARK: - Fixture honesty

    /// The read-only directory really does defeat a write, so the
    /// failure tests below can't pass vacuously.
    @Test func readOnlyDirectoryActuallyBlocksWrites() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.seed([ProjectEntry(name: "a", path: "/tmp/a")], context: ctx)
            try Self.makeReadOnly(ctx)
            #expect(throws: (any Error).self) {
                try ProjectDashboardService(context: ctx)
                    .saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "b", path: "/tmp/b")]))
            }
            // ...and the original survives the refused write.
            #expect(try Self.read(path).contains("\"a\""))
        }
    }

    // MARK: - Mutations surface their failures

    @Test func addProjectSurfacesWriteFailureAndDoesNotFakeSuccess() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "existing", path: "/tmp/existing")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            try Self.makeReadOnly(ctx)

            let ok = await vm.addProject(name: "brand-new", path: "/tmp/brand-new")

            #expect(ok == false)
            #expect(vm.mutationError?.title == "Couldn't add “brand-new”")
            #expect(vm.mutationError?.message.isEmpty == false)
            // The critical half: the phantom project must NOT appear.
            // The old code committed it in memory regardless, so the
            // user saw it work all session and lost it at relaunch.
            #expect(vm.projects.map(\.name) == ["existing"])
            #expect(vm.selectedProject == nil)
        }
    }

    @Test func addProjectSurfacesDuplicateNameInsteadOfNoOp() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "site", path: "/tmp/site")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()

            #expect(await vm.addProject(name: "site", path: "/tmp/other") == false)
            #expect(vm.mutationError?.title == "Couldn't add “site”")
            #expect(vm.mutationError?.message.contains("already in the list") == true)
        }
    }

    @Test func removeProjectSurfacesWriteFailureAndKeepsTheProject() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed(
                [ProjectEntry(name: "keep", path: "/tmp/keep"), ProjectEntry(name: "drop", path: "/tmp/drop")],
                context: ctx
            )
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first { $0.name == "drop" })
            vm.selectProject(target)
            try Self.makeReadOnly(ctx)

            #expect(await vm.removeProject(target) == false)
            #expect(vm.mutationError?.title == "Couldn't remove “drop”")
            // Still on disk, so still on screen — and still selected.
            #expect(vm.projects.map(\.name).sorted() == ["drop", "keep"])
            #expect(vm.selectedProject?.name == "drop")
        }
    }

    @Test func renameProjectSurfacesWriteFailure() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "old", path: "/tmp/old")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first)
            try Self.makeReadOnly(ctx)

            #expect(await vm.renameProject(target, to: "new") == false)
            #expect(vm.mutationError?.title == "Couldn't rename “old”")
            #expect(vm.projects.map(\.name) == ["old"])
        }
    }

    @Test func renameProjectSurfacesNameCollision() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed(
                [ProjectEntry(name: "a", path: "/tmp/a"), ProjectEntry(name: "b", path: "/tmp/b")],
                context: ctx
            )
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first { $0.name == "a" })

            #expect(await vm.renameProject(target, to: "b") == false)
            #expect(vm.mutationError?.message.contains("already in the list") == true)
        }
    }

    @Test func archiveSurfacesFailureAndKeepsSelection() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "site", path: "/tmp/site")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first)
            vm.selectProject(target)
            try Self.makeReadOnly(ctx)

            #expect(await vm.archiveProject(target) == false)
            #expect(vm.mutationError?.title == "Couldn't archive “site”")
            // A failed archive must not steal the user's place.
            #expect(vm.selectedProject?.name == "site")
        }
    }

    @Test func moveToFolderSurfacesFailure() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "site", path: "/tmp/site")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first)
            try Self.makeReadOnly(ctx)

            #expect(await vm.moveProject(target, toFolder: "Work") == false)
            #expect(vm.mutationError?.title == "Couldn't move “site”")
        }
    }

    /// A mutation whose registry went corrupt underneath it reports
    /// BOTH: the mutation didn't happen (alert) and the file is damaged
    /// (banner).
    @Test func mutationOnACorruptedRegistryFailsLoudlyAndFlagsTheDamage() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.seed([ProjectEntry(name: "real", path: "/tmp/real")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first)
            // The registry becomes unreadable underneath us — exactly
            // the agent-write scenario this phase exists for.
            try Self.write("{ not json at all", to: path)

            #expect(await vm.moveProject(target, toFolder: "Work") == false)
            let failure = try #require(vm.mutationError)
            #expect(failure.title == "Couldn't move “real”")
            // The message is the app-wide `RegistryLoss` wording now, so
            // the alert, the doctor's block and the MCP refusal all say the
            // same thing about the same file.
            #expect(failure.message.contains("couldn't be read at all and was set aside"))
            let quarantine = try #require(vm.registryDamage?.quarantinePath)
            #expect(failure.message.contains(quarantine))
        }
    }

    /// THE data-loss case, and the reason a mutation refuses a lossy
    /// load: a salvaged decode returns only the SURVIVING rows, so
    /// saving it would erase the unreadable ones for good. The file
    /// must come through the attempted mutation byte-for-byte intact.
    @Test func mutationRefusesToWriteBackASalvagedRegistry() async throws {
        try await Self.withTempHome { ctx, path in
            // One good row, one row that cannot be decoded at all.
            let original = """
            {
              "projects": [
                { "name": "good", "path": "/tmp/good" },
                { "name": 42 }
              ]
            }
            """
            try Self.write(original, to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()

            // Fixture honesty: the load really is lossy.
            #expect(vm.projects.map(\.name) == ["good"])
            #expect(try #require(vm.registryDamage).droppedCount == 1)

            let target = try #require(vm.projects.first)
            #expect(await vm.moveProject(target, toFolder: "Work") == false)
            #expect(vm.mutationError?.title == "Couldn't move “good”")

            // The unreadable row is still on disk, untouched.
            #expect(try Self.read(path) == original)
        }
    }

    /// The M1 relaxation, and the other half of the rule above: a row that
    /// lost a FIELD is not a row that was lost. Refusing these froze every
    /// mutation in the app over one hand-typed uuid — while the doctor
    /// cheerfully repaired the same file — so the refusal now asks
    /// `RegistryLoss`, which field salvage does not produce.
    ///
    /// The damage is not swept under the rug by allowing the write: the
    /// banner still raises (asserted here), and the doctor raises a
    /// `registryFieldSalvaged` finding.
    @Test func mutationProceedsWhenOnlyAFieldWasSalvaged() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.write("""
            {
              "projects": [
                { "name": "good", "path": "/tmp/good", "uuid": "NOT-A-UUID" },
                { "name": "other", "path": "/tmp/other" }
              ]
            }
            """, to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()

            // Fixture honesty: damage that is NOT row loss.
            let damage = try #require(vm.registryDamage)
            #expect(damage.droppedCount == 0)
            #expect(damage.salvagedFields == ["good.uuid"])

            let target = try #require(vm.projects.first { $0.name == "good" })
            #expect(await vm.moveProject(target, toFolder: "Work"))
            #expect(vm.mutationError == nil)

            // Both rows survive the write; the unreadable uuid does not,
            // which is precisely what the doctor's finding warns about.
            let after = ProjectDashboardService(context: ctx).loadRegistry()
            #expect(after.projects.map(\.name) == ["good", "other"])
            #expect(after.projects.first?.folder == "Work")
        }
    }

    @Test func addAndRemoveAlsoRefuseALossyRegistry() async throws {
        try await Self.withTempHome { ctx, path in
            let original = """
            { "projects": [ { "name": "good", "path": "/tmp/good" }, { "name": 42 } ] }
            """
            try Self.write(original, to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first)

            #expect(await vm.addProject(name: "another", path: "/tmp/another") == false)
            #expect(await vm.removeProject(target) == false)
            #expect(await vm.renameProject(target, to: "renamed") == false)
            #expect(try Self.read(path) == original)
        }
    }

    /// `removeProject` passes `allowEmpty: true`, which deliberately
    /// bypasses Phase 1's empty-overwrite refusal. Without a
    /// "still present?" guard, removing something already gone would
    /// blank the file and report success.
    @Test func removingAProjectThatIsAlreadyGoneFailsInsteadOfBlankingTheFile() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.seed([ProjectEntry(name: "still-here", path: "/tmp/still-here")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let ghost = ProjectEntry(name: "already-gone", path: "/tmp/already-gone")

            #expect(await vm.removeProject(ghost) == false)
            #expect(vm.mutationError?.message.contains("no longer in the list") == true)
            // The real project is untouched.
            #expect(try Self.read(path).contains("still-here"))
            #expect(vm.projects.map(\.name) == ["still-here"])
        }
    }

    @Test func renameToAnEmptyNameSaysWhy() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "site", path: "/tmp/site")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first)

            #expect(await vm.renameProject(target, to: "   ") == false)
            #expect(vm.mutationError?.message.contains("needs a name") == true)
        }
    }

    @Test func dismissMutationErrorClearsTheAlert() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "site", path: "/tmp/site")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            #expect(await vm.addProject(name: "site", path: "/tmp/dupe") == false)
            #expect(vm.mutationError != nil)

            vm.dismissMutationError()
            #expect(vm.mutationError == nil)
        }
    }

    /// A retry that works must take the alert down with it.
    @Test func successfulMutationClearsThePriorError() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "site", path: "/tmp/site")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let target = try #require(vm.projects.first)
            try Self.makeReadOnly(ctx)
            #expect(await vm.moveProject(target, toFolder: "Work") == false)
            #expect(vm.mutationError != nil)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: ctx.paths.scarfDir
            )
            #expect(await vm.moveProject(target, toFolder: "Work") == true)
            #expect(vm.mutationError == nil)
            #expect(vm.projects.first?.folder == "Work")
        }
    }

    // MARK: - Registry damage banner

    @Test func cleanRegistryShowsNoDamage() async throws {
        try await Self.withTempHome { ctx, _ in
            try Self.seed([ProjectEntry(name: "site", path: "/tmp/site")], context: ctx)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            #expect(vm.registryDamage == nil)
        }
    }

    /// The live 2026-09-02 shape: a row with a non-UUID `uuid`. The row
    /// survives minus the field, and the user is told.
    @Test func salvagedFieldRaisesTheDamageNotice() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.write("""
            {
              "projects": [
                { "name": "shabubox", "path": "/tmp/shabubox", "uuid": "SHABUBOX-SEO-TRACKER-2026-09-03" }
              ]
            }
            """, to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()

            #expect(vm.projects.map(\.name) == ["shabubox"])
            let damage = try #require(vm.registryDamage)
            #expect(damage.quarantinePath == nil)
            #expect(damage.salvagedFields.contains("shabubox.uuid"))
            #expect(damage.summary.isEmpty == false)
        }
    }

    @Test func unparseableRegistryRaisesQuarantineNoticeWithARevealPath() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.write("this is not a registry", to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()

            let damage = try #require(vm.registryDamage)
            let quarantine = try #require(damage.quarantinePath)
            #expect(quarantine.contains("projects.json.corrupt-"))
            #expect(FileManager.default.fileExists(atPath: quarantine))
            // Reveal targets the quarantine copy — the file holding the
            // bytes we couldn't read.
            #expect(damage.revealPath == quarantine)
        }
    }

    @Test func damageNoticePicksUpTheRollingBackupWhenThereIsOne() async throws {
        try await Self.withTempHome { ctx, path in
            // A real save first, so `.bak` exists on disk...
            try Self.seed([ProjectEntry(name: "one", path: "/tmp/one")], context: ctx)
            try Self.seed([ProjectEntry(name: "two", path: "/tmp/two")], context: ctx)
            #expect(FileManager.default.fileExists(atPath: path + ".bak"))
            // ...then damage the live file.
            try Self.write("{ broken", to: path)

            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let damage = try #require(vm.registryDamage)
            #expect(damage.backupPath == path + ".bak")
        }
    }

    /// A watcher tick fires `reload()` repeatedly while the file stays
    /// broken. A dismissal has to survive that, or the banner is a
    /// popup the user can't get rid of.
    /// An agent flip-flopping the registry between two bad shapes must
    /// not defeat dismissal — with a single-slot signature each shape
    /// cleared the other's dismissal and the banner came back forever.
    @Test func dismissalHoldsWhenDamageAlternatesBetweenTwoShapes() async throws {
        try await Self.withTempHome { ctx, path in
            let shapeA = """
            { "projects": [ { "name": "a", "path": "/tmp/a", "uuid": "NOT-A-UUID" } ] }
            """
            let shapeB = """
            { "projects": [ { "name": "b", "path": "/tmp/b", "uuid": "ALSO-BAD" } ] }
            """
            let vm = ProjectsViewModel(context: ctx)

            try Self.write(shapeA, to: path)
            vm.load()
            vm.dismissRegistryDamage()

            try Self.write(shapeB, to: path)
            vm.load()
            vm.dismissRegistryDamage()

            // Back to A: already dismissed, so it must stay down.
            try Self.write(shapeA, to: path)
            vm.load()
            #expect(vm.registryDamage == nil)

            try Self.write(shapeB, to: path)
            vm.load()
            #expect(vm.registryDamage == nil)
        }
    }

    /// The headline must not promise a backup when none was made.
    @Test func headlineOnlyPromisesABackupWhenThereIsOne() async throws {
        try await Self.withTempHome { ctx, path in
            // Salvaged field only: nothing set aside, no `.bak` yet.
            try Self.write("""
            { "projects": [ { "name": "a", "path": "/tmp/a", "uuid": "NOT-A-UUID" } ] }
            """, to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let damage = try #require(vm.registryDamage)
            #expect(damage.revealPath == nil)
            #expect(damage.headline == "Part of your projects list couldn't be read")

            // Quarantined: there IS a copy to point at.
            try Self.write("not a registry", to: path)
            vm.load()
            let quarantined = try #require(vm.registryDamage)
            #expect(quarantined.revealPath != nil)
            #expect(quarantined.headline.contains("a backup was saved"))
        }
    }

    /// A `.bak` appearing later is not new damage: it must not reopen a
    /// banner the user already dismissed.
    @Test func aBackupAppearingDoesNotReopenADismissedBanner() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.write("""
            { "projects": [ { "name": "a", "path": "/tmp/a", "uuid": "NOT-A-UUID" } ] }
            """, to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            let before = try #require(vm.registryDamage)
            #expect(before.backupPath == nil)
            vm.dismissRegistryDamage()

            // Some other surface saves, creating projects.json.bak,
            // then the same damage is written back.
            try Self.seed([ProjectEntry(name: "a", path: "/tmp/a")], context: ctx)
            try Self.write("""
            { "projects": [ { "name": "a", "path": "/tmp/a", "uuid": "NOT-A-UUID" } ] }
            """, to: path)
            vm.load()
            #expect(vm.registryDamage == nil)
        }
    }

    @Test func dismissalSurvivesReloadsOfTheSameDamage() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.write("still not a registry", to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            #expect(vm.registryDamage != nil)

            vm.dismissRegistryDamage()
            #expect(vm.registryDamage == nil)

            // Two more loads, as a watcher would drive.
            vm.load()
            #expect(vm.registryDamage == nil)
            vm.load()
            #expect(vm.registryDamage == nil)
        }
    }

    /// A stray dismiss with no banner showing must not blank an
    /// earlier dismissal — otherwise the banner the user already dealt
    /// with reappears on the next watcher tick.
    @Test func dismissWithNoBannerShowingDoesNotUndoAnEarlierDismissal() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.write("not a registry", to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            vm.dismissRegistryDamage()
            #expect(vm.registryDamage == nil)

            vm.dismissRegistryDamage()   // no banner up
            vm.load()
            #expect(vm.registryDamage == nil)
        }
    }

    /// ...but NEW damage must reopen it, or the second corruption goes
    /// unreported because the user dismissed the first.
    @Test func newDamageReopensADismissedBanner() async throws {
        try await Self.withTempHome { ctx, path in
            try Self.write("""
            { "projects": [ { "name": "a", "path": "/tmp/a", "uuid": "NOT-A-UUID" } ] }
            """, to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            vm.dismissRegistryDamage()
            #expect(vm.registryDamage == nil)

            try Self.write("""
            { "projects": [ { "name": "a", "path": "/tmp/a", "uuid": "NOT-A-UUID" },
                            { "name": "b", "path": "/tmp/b", "uuid": "ALSO-NOT-A-UUID" } ] }
            """, to: path)
            vm.load()
            let damage = try #require(vm.registryDamage)
            #expect(damage.salvagedFields.count == 2)
        }
    }

    /// A repaired file clears both the banner and the dismissal, so a
    /// LATER corruption that happens to look identical is still shown.
    @Test func repairedRegistryClearsTheDamageAndTheDismissal() async throws {
        try await Self.withTempHome { ctx, path in
            let broken = """
            { "projects": [ { "name": "a", "path": "/tmp/a", "uuid": "NOT-A-UUID" } ] }
            """
            try Self.write(broken, to: path)
            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            vm.dismissRegistryDamage()

            try Self.seed([ProjectEntry(name: "a", path: "/tmp/a")], context: ctx)
            vm.load()
            #expect(vm.registryDamage == nil)

            try Self.write(broken, to: path)
            vm.load()
            #expect(vm.registryDamage != nil)
        }
    }

    // NOTE: the "a mutation outranks a reload already in flight"
    // guarantee (the `reloadGeneration` bump in `load()` and
    // `registryForMutation()`) is deliberately NOT tested here. On a
    // `@MainActor` suite the detached read cannot be made to land
    // between a synchronous mutation's read and its commit, so every
    // version of that test passed with the bump REMOVED — it proved
    // nothing. Testing it honestly needs an injectable read seam;
    // until then the guard stands on the reasoning in its comment
    // rather than on a green check that means nothing.

    /// The off-main path has to raise the banner too — `reload()` is
    /// the one a file-watcher tick actually uses, and it reaches the
    /// salvage seam through a detached read rather than the direct
    /// call `load()` makes.
    @Test func reloadRaisesTheDamageNoticeThroughTheOffMainPath() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-projects-vm-\(UUID().uuidString)", isDirectory: true)
        let ctx = ServerContext.local(home: home)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            atPath: ctx.paths.scarfDir, withIntermediateDirectories: true
        )
        try Self.write("not a registry either", to: ctx.paths.projectsRegistry)

        let vm = ProjectsViewModel(context: ctx)
        await vm.reload()

        let damage = try #require(vm.registryDamage)
        #expect(damage.quarantinePath != nil)
        #expect(vm.projects.isEmpty)

        // And a dismissal survives the next tick on this path too.
        vm.dismissRegistryDamage()
        await vm.reload()
        #expect(vm.registryDamage == nil)
    }
}
