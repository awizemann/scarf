import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises the v2.3 registry verbs added to ProjectsViewModel:
/// moveProject, renameProject, archiveProject, unarchiveProject,
/// + the derived `folders` list. All verbs write through to
/// `<home>/scarf/projects.json` via ProjectDashboardService. Each test
/// injects an isolated `ServerContext.local(home:)`, so the registry
/// lives in a per-instance temp dir — never the developer's real
/// `~/.hermes`. No shared mutable state, so no cross-suite lock and no
/// `.serialized` (the old `TestRegistryLock`, a main-thread-blocking
/// `NSLock`, deadlocked this `@MainActor` suite against parallel
/// suites — see the `testregistrylock-…-deadlocks` memory note).
@MainActor struct ProjectsViewModelTests {

    @Test func moveProjectSetsFolder() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try seedRegistry(.init(projects: [
            ProjectEntry(name: "Alpha", path: "/a"),
            ProjectEntry(name: "Beta", path: "/b")
        ]), context: home.context)

        let vm = ProjectsViewModel(context: home.context)
        vm.load()
        #expect(vm.projects.count == 2)

        await vm.moveProject(vm.projects[0], toFolder: "Clients")

        #expect(vm.projects.count == 2)
        #expect(vm.projects.first(where: { $0.name == "Alpha" })?.folder == "Clients")
        #expect(vm.projects.first(where: { $0.name == "Beta" })?.folder == nil)

        // Round-trip: reload from disk and confirm the move persisted.
        let fresh = ProjectDashboardService(context: home.context).loadRegistry()
        #expect(fresh.projects.first(where: { $0.name == "Alpha" })?.folder == "Clients")
    }

    @Test func moveProjectToNilReturnsToTopLevel() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try seedRegistry(.init(projects: [
            ProjectEntry(name: "Nested", path: "/n", folder: "Clients")
        ]), context: home.context)

        let vm = ProjectsViewModel(context: home.context)
        vm.load()
        await vm.moveProject(vm.projects[0], toFolder: nil)

        #expect(vm.projects[0].folder == nil)
        let fresh = ProjectDashboardService(context: home.context).loadRegistry()
        #expect(fresh.projects[0].folder == nil)
    }

    @Test func renameProjectUpdatesNameAndPreservesOtherFields() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try seedRegistry(.init(projects: [
            ProjectEntry(name: "OldName", path: "/p", folder: "Work", archived: false)
        ]), context: home.context)

        let vm = ProjectsViewModel(context: home.context)
        vm.load()
        vm.selectProject(vm.projects[0])

        let ok = await vm.renameProject(vm.projects[0], to: "NewName")
        #expect(ok == true)
        #expect(vm.projects.count == 1)
        #expect(vm.projects[0].name == "NewName")
        #expect(vm.projects[0].folder == "Work")
        #expect(vm.projects[0].archived == false)
        // Selection follows the rename — the user stays on the same
        // project they were on.
        #expect(vm.selectedProject?.name == "NewName")
    }

    @Test func renameProjectRejectsDuplicateName() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try seedRegistry(.init(projects: [
            ProjectEntry(name: "A", path: "/a"),
            ProjectEntry(name: "B", path: "/b")
        ]), context: home.context)

        let vm = ProjectsViewModel(context: home.context)
        vm.load()

        // Renaming A to B should be refused — B already exists.
        let ok = await vm.renameProject(vm.projects[0], to: "B")
        #expect(ok == false)
        // Registry unchanged.
        #expect(vm.projects.map(\.name) == ["A", "B"])
    }

    @Test func renameProjectRejectsEmptyName() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try seedRegistry(.init(projects: [
            ProjectEntry(name: "Foo", path: "/f")
        ]), context: home.context)

        let vm = ProjectsViewModel(context: home.context)
        vm.load()

        #expect(await vm.renameProject(vm.projects[0], to: "") == false)
        #expect(await vm.renameProject(vm.projects[0], to: "   ") == false)
        #expect(vm.projects[0].name == "Foo")
    }

    @Test func renameProjectToSameNameIsNoOpSuccess() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try seedRegistry(.init(projects: [
            ProjectEntry(name: "Foo", path: "/f")
        ]), context: home.context)

        let vm = ProjectsViewModel(context: home.context)
        vm.load()

        #expect(await vm.renameProject(vm.projects[0], to: "Foo") == true)
        // Whitespace around matching name also no-ops.
        #expect(await vm.renameProject(vm.projects[0], to: " Foo ") == true)
        #expect(vm.projects[0].name == "Foo")
    }

    @Test func archiveAndUnarchiveProject() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try seedRegistry(.init(projects: [
            ProjectEntry(name: "Target", path: "/t")
        ]), context: home.context)

        let vm = ProjectsViewModel(context: home.context)
        vm.load()
        vm.selectProject(vm.projects[0])
        #expect(vm.projects[0].archived == false)
        #expect(vm.selectedProject != nil)

        await vm.archiveProject(vm.projects[0])
        #expect(vm.projects[0].archived == true)
        // Archiving clears the selection so the dashboard doesn't
        // linger on a project the sidebar will hide.
        #expect(vm.selectedProject == nil)

        await vm.unarchiveProject(vm.projects[0])
        #expect(vm.projects[0].archived == false)
        // Unarchive doesn't re-select — the user chose to hide it,
        // surfacing it doesn't mean they want focus back.
        #expect(vm.selectedProject == nil)
    }

    @Test func foldersListIsSortedAndDeduped() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try seedRegistry(.init(projects: [
            ProjectEntry(name: "A", path: "/a", folder: "Work"),
            ProjectEntry(name: "B", path: "/b", folder: "Personal"),
            ProjectEntry(name: "C", path: "/c", folder: "Work"),
            ProjectEntry(name: "D", path: "/d"),   // top-level
            ProjectEntry(name: "E", path: "/e", folder: "")  // empty string treated as nil
        ]), context: home.context)

        let vm = ProjectsViewModel(context: home.context)
        vm.load()

        #expect(vm.folders == ["Personal", "Work"])
    }

    // MARK: - Helpers

    @MainActor
    private func seedRegistry(_ registry: ProjectRegistry, context: ServerContext) throws {
        try ProjectDashboardService(context: context).saveRegistry(registry)
    }
}
