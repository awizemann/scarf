import Testing
import Foundation
import ScarfCore
@testable import scarf

/// The watcher has to survive atomic replacement, because that is how
/// nearly every file it watches gets written.
///
/// A vnode source watches an INODE. `LocalTransport.writeFile` uses
/// `Data.write(.atomic)` — temp file plus `rename(2)` over the
/// destination — so the watched inode is unlinked rather than modified,
/// delivering `.delete`. Before the re-arm, the FIRST atomic replace of
/// any watched path killed that watch permanently and silently: measured
/// as 0 events for 2 atomic writes.
///
/// It went unnoticed for as long as Scarf was the only writer (each view
/// model reloads after its own save). The bundled `scarf-projects` MCP
/// server writes `projects.json` from a SEPARATE PROCESS, where a dead
/// watch means an agent registers a project and the sidebar never shows
/// it.
@MainActor
struct HermesFileWatcherAtomicReplaceTests {

    /// Waits for `lastChangeDate` to move past `baseline`. The watcher
    /// coalesces (0.5s window), so this polls rather than sleeping a
    /// fixed amount.
    private func waitForTick(
        _ watcher: HermesFileWatcher,
        after baseline: Date,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if watcher.lastChangeDate > baseline { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    @Test("a SECOND atomic replace of projects.json still ticks the watcher")
    func survivesRepeatedAtomicReplacement() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let context = home.context
        try FileManager.default.createDirectory(
            atPath: context.paths.scarfDir, withIntermediateDirectories: true
        )
        let registry = context.paths.projectsRegistry
        let service = ProjectDashboardService(context: context)
        // The file has to exist before the watch is armed — that is the
        // situation the bug lived in.
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "One", path: home.path + "/one"),
        ]))

        let watcher = HermesFileWatcher(context: context)
        watcher.startWatching()
        defer { watcher.stopWatching() }
        // Let the source arm before writing.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // First replace. Before the fix this fired NOTHING either: the old
        // `[.write, .extend, .rename]` mask never saw it, because an atomic
        // replace unlinks the watched inode (`.delete`) rather than renaming
        // or writing it. Both replaces below were invisible; this one is
        // asserted so a regression that breaks arming is told apart from one
        // that breaks only the re-arm.
        var baseline = watcher.lastChangeDate
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "One", path: home.path + "/one"),
            ProjectEntry(name: "Two", path: home.path + "/two"),
        ]))
        #expect(await waitForTick(watcher, after: baseline), "first atomic replace was not seen")

        // Second replace — 0 events before the re-arm landed. This is the
        // assertion that actually pins the fix.
        baseline = watcher.lastChangeDate
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "One", path: home.path + "/one"),
            ProjectEntry(name: "Two", path: home.path + "/two"),
            ProjectEntry(name: "Three", path: home.path + "/three"),
        ]))
        #expect(
            await waitForTick(watcher, after: baseline),
            "second atomic replace was not seen — the watch died on the first one"
        )
    }

    /// Used to assert nothing at all — it deleted a file, slept, and
    /// stopped, so it passed identically whether the watcher dropped the
    /// path, span on a re-arm loop, or quietly kept a dead source. Now it
    /// pins both halves of the real behaviour: the path drops out, and it is
    /// REMEMBERED so it can be picked up again.
    @Test("a deleted core path drops out and is re-established when it returns")
    func deletedPathDropsOutAndComesBack() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let context = home.context
        try FileManager.default.createDirectory(
            atPath: context.paths.scarfDir, withIntermediateDirectories: true
        )
        let registry = context.paths.projectsRegistry
        try Data(#"{"projects":[]}"#.utf8).write(to: URL(fileURLWithPath: registry))

        let watcher = HermesFileWatcher(context: context)
        watcher.startWatching()
        defer { watcher.stopWatching() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let unarmedAtStart = watcher.unarmedCorePathCount

        // Deleted with a GAP — nothing takes its place, so the re-arm has
        // no inode to open and the source is dropped.
        try FileManager.default.removeItem(atPath: registry)
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(
            watcher.unarmedCorePathCount == unarmedAtStart + 1,
            "the deleted core path was forgotten rather than remembered"
        )

        // It comes back — an agent rewriting the file, a restore from .bak,
        // a git checkout. Before the retry, this path stayed unwatched for
        // the rest of the process's life.
        try Data(#"{"projects":[]}"#.utf8).write(to: URL(fileURLWithPath: registry))
        // Nothing else in this temp home exists to tick, which is exactly
        // the case the retry timer is the floor for.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, watcher.unarmedCorePathCount > unarmedAtStart {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(
            watcher.unarmedCorePathCount == unarmedAtStart,
            "the core path never got its watch back"
        )

        // And the re-established watch actually fires.
        let baseline = watcher.lastChangeDate
        try ProjectDashboardService(context: context).saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "Back", path: home.path + "/back"),
        ]))
        #expect(
            await waitForTick(watcher, after: baseline),
            "a write to the re-established path was not seen"
        )
    }

    /// The arm-time race: a replace landing between `open(2)` and the
    /// source going live unlinks the inode before anything is listening, so
    /// no `.delete` is ever delivered and the watch is dead on arrival.
    ///
    /// Honest about what this proves. The race is a microsecond window that
    /// no test can schedule on demand, so this is a LIVENESS stress: it arms
    /// watches in the middle of a replace storm and asserts the watcher is
    /// still alive afterwards. It will pass with the inode comparison
    /// reverted whenever the window doesn't happen to land — it is here to
    /// catch a re-arm that spins, deadlocks, or drops the watch under churn,
    /// which is the failure mode a user would actually see.
    @Test("a watch armed during a replace storm is still alive afterwards")
    func armingRacesAreDetected() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let context = home.context
        try FileManager.default.createDirectory(
            atPath: context.paths.scarfDir, withIntermediateDirectories: true
        )
        let service = ProjectDashboardService(context: context)
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "One", path: home.path + "/one"),
        ]))

        let watcher = HermesFileWatcher(context: context)
        let churn = Task.detached {
            for index in 0..<200 {
                try? service.saveRegistry(ProjectRegistry(projects: [
                    ProjectEntry(name: "One", path: home.path + "/one-\(index)"),
                ]))
            }
        }
        watcher.startWatching()
        defer { watcher.stopWatching() }
        await churn.value
        try? await Task.sleep(nanoseconds: 700_000_000)

        // Whatever happened during arming, the watch must be live now.
        let baseline = watcher.lastChangeDate
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "Two", path: home.path + "/two"),
        ]))
        #expect(
            await waitForTick(watcher, after: baseline),
            "the watch did not survive being armed during a replace storm"
        )
    }
}
