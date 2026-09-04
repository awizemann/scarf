import Testing
import Foundation
import ScarfCore
@testable import scarf

/// PF (t-45594d27): the project surfaces must stop hanging off the watcher
/// tick.
///
/// Every test here is about a SHORT-CIRCUIT, and the failure mode of a
/// short-circuit is staleness, not slowness — so each one asserts both
/// halves: that the skip happens when nothing changed, AND that a real
/// change still gets through it.
@MainActor
@Suite(.serialized)
struct ProjectsPFTickDecouplingTests {

    // MARK: - H4: the watcher diffs its project set

    @Test("an unchanged project set arms nothing and cancels nothing")
    func updateProjectWatchesIsANoOpForAnUnchangedSet() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let root = home.path + "/proj"
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf", withIntermediateDirectories: true
        )
        let dashboard = root + "/.scarf/dashboard.json"
        try Data(#"{"sections":[]}"#.utf8).write(to: URL(fileURLWithPath: dashboard))

        let watcher = HermesFileWatcher(context: home.context)
        defer { watcher.stopWatching() }

        watcher.updateProjectWatches(dashboardPaths: [dashboard], scarfDirs: [root + "/.scarf"])
        let armedAfterFirst = watcher.projectArmCount
        #expect(armedAfterFirst == 2)
        #expect(watcher.projectSourceCount == 2)

        // The tick calls this with an identical set every 0.5-1.5s. Before
        // the diff, each of those cancelled and reopened both watches.
        for _ in 0..<5 {
            watcher.updateProjectWatches(
                dashboardPaths: [dashboard], scarfDirs: [root + "/.scarf"]
            )
        }
        #expect(
            watcher.projectArmCount == armedAfterFirst,
            "an unchanged set rebuilt the watches anyway"
        )
        #expect(watcher.projectSourceCount == 2)
    }

    @Test("a changed project set adds and removes only the difference")
    func updateProjectWatchesDiffsAddsAndRemoves() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        var dirs: [String] = []
        for name in ["a", "b", "c"] {
            let dir = home.path + "/\(name)/.scarf"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            dirs.append(dir)
        }
        let watcher = HermesFileWatcher(context: home.context)
        defer { watcher.stopWatching() }

        watcher.updateProjectWatches(dashboardPaths: [], scarfDirs: [dirs[0], dirs[1]])
        #expect(watcher.projectSourceCount == 2)
        let armed = watcher.projectArmCount

        // Swap one out for one in: exactly one new arm, and the set stays 2.
        watcher.updateProjectWatches(dashboardPaths: [], scarfDirs: [dirs[0], dirs[2]])
        #expect(watcher.projectSourceCount == 2)
        #expect(
            watcher.projectArmCount == armed + 1,
            "a one-project change re-armed more than the one project"
        )
    }

    /// The diff must not cost us the property the vnode-re-arm work bought:
    /// a watched project file survives being atomically replaced. This is
    /// the regression the `.delete`-mask note warns about, re-checked
    /// against the new keyed storage.
    @Test("a project dashboard still ticks after two atomic replaces")
    func projectWatchSurvivesAtomicReplacementAfterTheDiff() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let root = home.path + "/proj"
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf", withIntermediateDirectories: true
        )
        let dashboard = root + "/.scarf/dashboard.json"
        let url = URL(fileURLWithPath: dashboard)
        try Data(#"{"sections":[]}"#.utf8).write(to: url, options: .atomic)

        let watcher = HermesFileWatcher(context: home.context)
        defer { watcher.stopWatching() }
        watcher.updateProjectWatches(dashboardPaths: [dashboard], scarfDirs: [])
        try? await Task.sleep(nanoseconds: 200_000_000)

        for attempt in 1...2 {
            let baseline = watcher.lastChangeDate
            try Data(#"{"sections":[{"title":"x","widgets":[]}]}"#.utf8)
                .write(to: url, options: .atomic)
            var seen = false
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if watcher.lastChangeDate > baseline { seen = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(seen, "atomic replace #\(attempt) of a project path was not seen")
        }
    }

    @Test("a project path that doesn't exist yet is remembered and armed later")
    func absentProjectPathIsRetried() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let root = home.path + "/late"
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf", withIntermediateDirectories: true
        )
        let dashboard = root + "/.scarf/dashboard.json"

        let watcher = HermesFileWatcher(context: home.context)
        defer { watcher.stopWatching() }
        watcher.updateProjectWatches(dashboardPaths: [dashboard], scarfDirs: [root + "/.scarf"])
        // The dir armed; the not-yet-written dashboard did not, and must be
        // remembered — the diff would otherwise never look at it again.
        #expect(watcher.projectSourceCount == 1)
        #expect(watcher.unarmedProjectPathCount == 1)

        // Writing it fires the DIRECTORY watch, whose tick retries the
        // remembered path for free.
        try Data(#"{"sections":[]}"#.utf8).write(
            to: URL(fileURLWithPath: dashboard), options: .atomic
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, watcher.unarmedProjectPathCount > 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(
            watcher.unarmedProjectPathCount == 0,
            "a project path that appeared later never got a watch"
        )
        #expect(watcher.projectSourceCount == 2)
    }

    // MARK: - H2: the menu probe cache is not a per-tick probe

    @Test("an unchanged project set does not re-probe; an install invalidates")
    func menuProbeCacheSkipsUnchangedSets() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let cache = ProjectMenuProbeCache()
        let projects = [
            ProjectEntry(name: "a", path: home.path + "/a"),
            ProjectEntry(name: "b", path: home.path + "/b")
        ]

        cache.refresh(projects: projects, context: home.context)
        #expect(cache.probeCount == 1)

        // The tick's ~40 round-trips per fire, gone.
        for _ in 0..<10 { cache.refresh(projects: projects, context: home.context) }
        #expect(cache.probeCount == 1, "an unchanged project set re-probed")

        // A new project is a new question.
        cache.refresh(
            projects: projects + [ProjectEntry(name: "c", path: home.path + "/c")],
            context: home.context
        )
        #expect(cache.probeCount == 2)

        // And an install/uninstall says so explicitly rather than waiting
        // out the revalidation window.
        let after = cache.probeCount
        cache.invalidate()
        cache.refresh(
            projects: projects + [ProjectEntry(name: "c", path: home.path + "/c")],
            context: home.context
        )
        #expect(cache.probeCount == after + 1, "invalidate() did not force a probe")
    }

    // MARK: - H1 / M4: the cockpit short-circuits on an unchanged signature

    @Test("a watcher-driven load with nothing changed commits nothing; a real edit lands")
    func cockpitShortCircuitsOnUnchangedFacets() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let context = home.context
        let root = home.path + "/proj"
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: context.paths.scarfDir, withIntermediateDirectories: true
        )
        let begin = ProjectContextBlock.beginMarker
        let end = ProjectContextBlock.endMarker
        let agents = root + "/AGENTS.md"
        try Data("\(begin)\nfirst\n\(end)\n".utf8).write(to: URL(fileURLWithPath: agents))

        let entry = ProjectEntry(name: "proj", path: root)
        let vm = ProjectCockpitViewModel(context: context, project: entry)
        await vm.load()
        #expect(vm.contextBlock?.contains("first") == true)

        // Change the file BEHIND the view model without touching mtime
        // granularity concerns — a different length is a different
        // signature.
        try Data("\(begin)\nsecond and longer\n\(end)\n".utf8)
            .write(to: URL(fileURLWithPath: agents), options: .atomic)
        await vm.load(force: true, reason: .watcher)
        #expect(
            vm.contextBlock?.contains("second") == true,
            "the short-circuit swallowed a real edit"
        )

        // Now the unchanged case: a tick with nothing new must not blank or
        // churn the facets.
        let before = vm.contextBlock
        let loadsBefore = vm.facetLoadCount
        for _ in 0..<5 { await vm.load(force: true, reason: .watcher) }
        #expect(vm.contextBlock == before)
        #expect(
            vm.facetLoadCount == loadsBefore,
            "five ticks with nothing changed still re-read every facet"
        )
    }

    /// M4. The doctor is ~110 transport ops; a tick must never trigger it,
    /// however stale the cache window claims the verdict is.
    @Test("a watcher-driven load never runs the doctor scan")
    func watcherLoadDoesNotDiagnose() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let context = home.context
        let root = home.path + "/proj"
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: context.paths.scarfDir, withIntermediateDirectories: true
        )
        let entry = ProjectEntry(name: "proj", path: root)

        // Nothing cached and nothing claimed: a user-initiated load is the
        // only kind allowed to take the claim.
        ProjectHealthCache.shared.invalidate(context.id)
        let vm = ProjectCockpitViewModel(context: context, project: entry)
        await vm.load(force: true, reason: .watcher)
        #expect(
            ProjectHealthCache.shared.report(context.id) == nil,
            "a watcher tick ran the registry-wide doctor scan"
        )

        // ...and the surface that IS allowed to scan still does. Asserted
        // on the view model rather than the shared cache: `ServerContext`
        // gives every local context the same id, so the cache is shared
        // across suites and only this instance's own verdict is ours.
        ProjectHealthCache.shared.invalidate(context.id)
        let opened = ProjectCockpitViewModel(context: context, project: entry)
        await opened.load(reason: .userInitiated)
        #expect(
            opened.health != nil,
            "a user-initiated open no longer produces a health verdict"
        )
        ProjectHealthCache.shared.invalidate(context.id)
    }
}
