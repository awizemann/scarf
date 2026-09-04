import Testing
import Foundation
import Observation
import ScarfCore
@testable import scarf

/// P2 (t-7d05e066): the second pass over "a watcher tick is a hint".
///
/// PF made an unchanged tick cheap in ROUND-TRIPS. This is about the two
/// things that survived: an unchanged tick still wrote `@Observable`
/// state (so SwiftUI re-evaluated the whole sidebar anyway), and a tick
/// whose stat FAILED was treated as a tick where everything changed.
@MainActor
@Suite(.serialized)
struct ProjectsP2TickCostTests {

    // MARK: - PERF H1 / M4: no stat data is not a change

    @Test("an untrusted batched stat keeps the cockpit's state instead of reloading")
    func untrustedSignatureSkipsTheTick() {
        let last = ["/a": "100:10"]
        // The fix. `nil` is "we learned nothing", and the previous code
        // turned it into an all-"-" map that could never match — a full
        // facet reload, and a derive-and-save of the project record, over
        // exactly the transport that had just failed.
        #expect(
            ProjectCockpitViewModel.shouldRead(
                reason: .watcher, recheckHealth: false, fresh: nil, last: last
            ) == false
        )
        // The two halves that must keep working.
        #expect(
            ProjectCockpitViewModel.shouldRead(
                reason: .watcher, recheckHealth: false, fresh: last, last: last
            ) == false
        )
        #expect(
            ProjectCockpitViewModel.shouldRead(
                reason: .watcher, recheckHealth: false, fresh: ["/a": "101:12"], last: last
            ) == true
        )
    }

    /// A user asking for a refresh is never short-circuited, even when the
    /// stat is untrustworthy: they may be asking about something the
    /// signature doesn't cover.
    @Test("a user-initiated load reads regardless of the signature")
    func userInitiatedAlwaysReads() {
        #expect(
            ProjectCockpitViewModel.shouldRead(
                reason: .userInitiated, recheckHealth: false, fresh: nil, last: nil
            ) == true
        )
        #expect(
            ProjectCockpitViewModel.shouldRead(
                reason: .watcher, recheckHealth: true, fresh: ["/a": "1:1"], last: ["/a": "1:1"]
            ) == true
        )
    }

    // MARK: - PERF H2: an unchanged tick writes nothing observable

    private func homeWithOneProject() throws -> (TempHermesHome, ProjectEntry) {
        let home = try TempHermesHome()
        let root = home.path + "/proj"
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: home.context.paths.scarfDir, withIntermediateDirectories: true
        )
        let entry = ProjectEntry(name: "proj", path: root)
        try ProjectDashboardService(context: home.context)
            .saveRegistry(ProjectRegistry(projects: [entry]))
        return (home, entry)
    }

    @Test("a tick that changed nothing does not touch observable state")
    func unchangedTickIsObservationSilent() async throws {
        let (home, _) = try homeWithOneProject()
        defer { home.cleanup() }
        let vm = ProjectsViewModel(context: home.context)
        await vm.reload()

        var wrote = false
        withObservationTracking {
            _ = vm.projects
            _ = vm.registryDamage
            _ = vm.selectedHasDashboard
        } onChange: {
            wrote = true
        }
        // The watcher fires this several times a second during a stream.
        await vm.reload()
        #expect(
            wrote == false,
            "an unchanged tick wrote @Observable state, re-evaluating the whole sidebar"
        )
    }

    /// The other half. A guard that never lets anything through is not a
    /// guard, it is a freeze.
    @Test("a tick that DID change something still writes it")
    func changedTickStillWrites() async throws {
        let (home, entry) = try homeWithOneProject()
        defer { home.cleanup() }
        let vm = ProjectsViewModel(context: home.context)
        await vm.reload()

        var wrote = false
        withObservationTracking {
            _ = vm.projects
        } onChange: {
            wrote = true
        }
        try ProjectDashboardService(context: home.context).saveRegistry(
            ProjectRegistry(projects: [entry, ProjectEntry(name: "other", path: home.path + "/o")])
        )
        await vm.reload()
        #expect(wrote == true, "a real registry change was swallowed by the equality guard")
        #expect(vm.projects.count == 2)
    }

    // MARK: - PERF H3: the dashboard glyph is not a per-tick stat

    @Test("an unchanged tick does not re-probe the dashboard glyph, but a refresh does")
    func dashboardGlyphIsGated() async throws {
        let (home, _) = try homeWithOneProject()
        defer { home.cleanup() }
        let vm = ProjectsViewModel(context: home.context)
        await vm.reload()
        vm.selectProject(try #require(vm.projects.first))
        await vm.refreshDashboard()
        #expect(vm.selectedHasDashboard == false)

        // The file appears behind the gate.
        try Data(#"{"sections":[]}"#.utf8).write(
            to: URL(fileURLWithPath: home.path + "/proj/.scarf/dashboard.json")
        )
        // A tick with an unchanged registry does not spend a round-trip.
        await vm.reload()
        #expect(vm.selectedHasDashboard == false)
        // The invalidation edges that DO exist: an explicit refresh, a
        // re-selection, or the revalidation window elapsing.
        await vm.refreshDashboard()
        #expect(vm.selectedHasDashboard == true)
    }
}
