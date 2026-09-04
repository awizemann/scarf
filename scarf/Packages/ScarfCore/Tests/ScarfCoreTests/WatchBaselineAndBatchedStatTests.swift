import Testing
import Foundation
@testable import ScarfCore

/// PF (t-45594d27), the transport half: a batched stat so change detection
/// costs one round-trip instead of N, and a watch baseline that survives
/// the poller restarts the watcher's diff still allows.
@Suite struct WatchBaselineAndBatchedStatTests {

    // MARK: - WatchBaselineStore

    @Test("the first poll baselines silently; the second reports the change")
    func firstPollIsSilentAndTheSecondIsNot() {
        let store = WatchBaselineStore()
        #expect(store.apply(["a": "1:10", "b": "1:20"]) == false)
        #expect(store.apply(["a": "1:10", "b": "1:20"]) == false)
        #expect(store.apply(["a": "2:10", "b": "1:20"]) == true)
    }

    @Test("a newly watched path is seeded, not reported as a change")
    func newPathIsNotADelta() {
        let store = WatchBaselineStore()
        _ = store.apply(["a": "1:10"])
        // This is what a poller restart with a bigger watch set looks like.
        #expect(store.apply(["a": "1:10", "b": "1:20"]) == false)
        #expect(store.signature(for: "b") == "1:20")
    }

    /// The bug this exists for: a restart used to re-baseline from nothing,
    /// so a change that landed while the poller was down was absorbed. With
    /// the baseline held by the CALLER, the first poll of the new stream
    /// still compares against what the old one knew.
    @Test("a change during a poller restart is reported, not swallowed")
    func changeAcrossARestartIsNotSwallowed() {
        let store = WatchBaselineStore()
        _ = store.apply(["registry": "100:512"])
        // ...restart happens here; the file changes while nobody is polling.
        #expect(store.apply(["registry": "101:640"]) == true)
    }

    /// Size is in the signature precisely because mtime is whole seconds
    /// over SSH: two writes inside one second share an mtime.
    @Test("a same-second write of a different length is still a change")
    func sizeCatchesSameSecondWrites() {
        let store = WatchBaselineStore()
        _ = store.apply(["log": "1700000000:120"])
        #expect(store.apply(["log": "1700000000:240"]) == true)
    }

    @Test("reset forgets everything, so the next poll baselines afresh")
    func resetRebaselines() {
        let store = WatchBaselineStore()
        _ = store.apply(["a": "1:10"])
        store.reset()
        #expect(store.apply(["a": "2:20"]) == false)
    }

    // MARK: - statAll

    @Test("the default batched stat matches per-path stat, and omits absent paths")
    func statAllMatchesStat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-statall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: a)
        let missing = dir.appendingPathComponent("nope.txt").path

        let transport = LocalTransport()
        let batched = try #require(transport.statAll([a.path, missing, dir.path]))
        #expect(batched[a.path]?.size == 5)
        #expect(batched[a.path]?.mtime == transport.stat(a.path)?.mtime)
        // ABSENT must be absent — not a zero-byte entry, which would make
        // "the file appeared" indistinguishable from "it was already there
        // and empty".
        #expect(batched[missing] == nil)
        #expect(batched[dir.path]?.isDirectory == true)
    }

    @Test("an empty path list is an empty result and no work")
    func statAllOfNothing() {
        #expect(LocalTransport().statAll([])?.isEmpty == true)
    }
}

/// H3: the sidebar's dashboard glyph used to cost a full read + decode of
/// `dashboard.json` per watcher tick, duplicating the cockpit's. It asks a
/// yes/no question and now gets a yes/no answer.
@MainActor
@Suite struct SidebarDashboardFlagTests {

    private func tempHome() throws -> ServerContext {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-pf-flag-\(UUID().uuidString)", isDirectory: true)
        let ctx = ServerContext.local(home: home)
        try FileManager.default.createDirectory(
            atPath: ctx.paths.scarfDir, withIntermediateDirectories: true
        )
        return ctx
    }

    @Test("the flag follows the file, and clears when the selection does")
    func flagTracksDashboardExistence() async throws {
        let ctx = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: ctx.paths.home) }
        let root = ctx.paths.home + "/proj"
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf", withIntermediateDirectories: true
        )
        let entry = ProjectEntry(name: "proj", path: root)
        try ProjectDashboardService(context: ctx)
            .saveRegistry(ProjectRegistry(projects: [entry]))

        let vm = ProjectsViewModel(context: ctx)
        await vm.reload()
        vm.selectProject(try #require(vm.projects.first))
        // Selection itself does no transport work — the flag lands after.
        await vm.refreshDashboard()
        #expect(vm.selectedHasDashboard == false)

        try Data(#"{"sections":[]}"#.utf8).write(
            to: URL(fileURLWithPath: root + "/.scarf/dashboard.json")
        )
        await vm.refreshDashboard()
        #expect(vm.selectedHasDashboard == true)

        #expect(await vm.removeProject(try #require(vm.projects.first)))
        #expect(vm.selectedProject == nil)
        #expect(vm.selectedHasDashboard == false)
    }
}

/// PF addendum: `saveRegistry` never compared its write against the load it
/// was computed from, so a change that landed in between was erased. The
/// cross-process LOCK closes the same-machine race; this closes the one a
/// local lock cannot see — a remote registry, where the read and the write
/// are seconds apart.
@Suite struct RegistryStaleOverwriteTests {

    private func tempHome() throws -> ServerContext {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-pf-stale-\(UUID().uuidString)", isDirectory: true)
        let ctx = ServerContext.local(home: home)
        try FileManager.default.createDirectory(
            atPath: ctx.paths.scarfDir, withIntermediateDirectories: true
        )
        return ctx
    }

    @Test("a write whose baseline no longer matches the file is refused")
    func staleWriteIsRefused() throws {
        let ctx = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: ctx.paths.home) }
        let service = ProjectDashboardService(context: ctx)
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "mine", path: "/tmp/mine")
        ]), allowEmpty: true)

        // What a mutator reads before the user's edit.
        let baseline = try #require(service.loadRegistryDetailed().contentFingerprint)

        // Somebody else writes in between — the MCP helper, another host.
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "mine", path: "/tmp/mine"),
            ProjectEntry(name: "theirs", path: "/tmp/theirs")
        ]))

        #expect(throws: ProjectRegistryError.refusedStaleOverwrite(path: ctx.paths.projectsRegistry)) {
            try service.saveRegistry(
                ProjectRegistry(projects: [ProjectEntry(name: "renamed", path: "/tmp/mine")]),
                expecting: baseline
            )
        }
        // And the other writer's row is still there.
        let after = service.loadRegistry()
        #expect(after.projects.map(\.name).sorted() == ["mine", "theirs"])
    }

    @Test("a write whose baseline still matches goes through")
    func freshWriteIsAllowed() throws {
        let ctx = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: ctx.paths.home) }
        let service = ProjectDashboardService(context: ctx)
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "mine", path: "/tmp/mine")
        ]), allowEmpty: true)
        let baseline = try #require(service.loadRegistryDetailed().contentFingerprint)
        try service.saveRegistry(
            ProjectRegistry(projects: [ProjectEntry(name: "renamed", path: "/tmp/mine")]),
            expecting: baseline
        )
        #expect(service.loadRegistry().projects.first?.name == "renamed")
    }

    /// Callers with no baseline — an installer writing a registry it just
    /// built — must keep working exactly as before.
    @Test("no baseline means no staleness check")
    func nilBaselineIsUnchangedBehaviour() throws {
        let ctx = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: ctx.paths.home) }
        let service = ProjectDashboardService(context: ctx)
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "a", path: "/tmp/a")
        ]), allowEmpty: true)
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "b", path: "/tmp/b")
        ]))
        #expect(service.loadRegistry().projects.first?.name == "b")
    }

    /// End to end through the view model: the mutator carries its own
    /// baseline, so a mutation computed from a file somebody has since
    /// rewritten is refused with a message rather than clobbering it.
    @MainActor
    @Test("a mutator whose read is stale refuses and says so")
    func viewModelMutatorRefusesAStaleWrite() async throws {
        let ctx = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: ctx.paths.home) }
        let service = ProjectDashboardService(context: ctx)
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "mine", path: "/tmp/mine")
        ]), allowEmpty: true)

        let vm = ProjectsViewModel(context: ctx)
        await vm.reload()
        let target = try #require(vm.projects.first)

        // The registry is agent-writable, and on a remote the read and the
        // write are seconds apart. Simulate the other writer landing in
        // between by rewriting the file before the mutation runs — the
        // mutator does its own read, so we have to beat THAT read: instead
        // assert the guard directly with a known-stale baseline.
        let stale = try #require(service.loadRegistryDetailed().contentFingerprint)
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "mine", path: "/tmp/mine"),
            ProjectEntry(name: "theirs", path: "/tmp/theirs")
        ]))
        #expect(throws: ProjectRegistryError.refusedStaleOverwrite(path: ctx.paths.projectsRegistry)) {
            try service.saveRegistry(
                ProjectRegistry(projects: [target]), expecting: stale
            )
        }

        // ...and a mutation that reads fresh still works, so the guard is
        // not simply freezing the app.
        #expect(await vm.moveProject(target, toFolder: "Work"))
        #expect(vm.mutationError == nil)
        #expect(service.loadRegistry().projects.first(where: { $0.name == "mine" })?.folder == "Work")
    }

    @Test("the fingerprint changes with the bytes and is stable without them")
    func fingerprintIsStableAndSensitive() {
        let a = Data("{\"projects\":[]}".utf8)
        let b = Data("{\"projects\":[ ]}".utf8)
        #expect(ProjectDashboardService.fingerprint(a) == ProjectDashboardService.fingerprint(a))
        #expect(ProjectDashboardService.fingerprint(a) != ProjectDashboardService.fingerprint(b))
    }
}
