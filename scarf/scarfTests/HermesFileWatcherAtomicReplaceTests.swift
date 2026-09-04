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

        // First replace — this one fired even before the fix, because it
        // is the one that kills the watch.
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

    @Test("a watched file that is deleted for good stops watching rather than looping")
    func deletedPathDropsOut() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let context = home.context
        try FileManager.default.createDirectory(
            atPath: context.paths.scarfDir, withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: URL(fileURLWithPath: context.paths.projectsRegistry))

        let watcher = HermesFileWatcher(context: context)
        watcher.startWatching()
        defer { watcher.stopWatching() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        try FileManager.default.removeItem(atPath: context.paths.projectsRegistry)
        // The re-arm can't re-open a path that is gone; the source drops
        // out quietly. Nothing to assert but "we're still alive and not
        // spinning" — a re-arm loop would hang or peg a core here.
        try? await Task.sleep(nanoseconds: 500_000_000)
        watcher.stopWatching()
    }
}
