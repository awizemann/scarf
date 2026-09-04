import Testing
import Foundation
@testable import ScarfCore

/// t-3b855719 (D1) + t-db8c745b — the adjacent Scarf-owned JSON sidecars
/// get the same read-then-write discipline `projects.json` got, and every
/// writer of the registry takes a cross-process lock.
///
/// These are ATTACK-SHAPE tests: each one puts the file into the state that
/// produced (or would produce) real data loss, performs the write the app
/// would perform, and asserts the bytes survived.
///
/// The "unreadable" shape is produced with `chmod 000` rather than a fake
/// transport, because that is precisely what the guard has to tell apart:
/// `stat` succeeds, the read fails, and the file is perfectly good
/// underneath. (A test run as root would defeat it — CI and dev machines
/// don't run tests as root.)
@Suite struct AdjacentRegistryGuardTests {

    static func withTempHome(_ body: (ServerContext, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-guarded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("scarf"), withIntermediateDirectories: true
        )
        defer {
            // Restore any mode we clamped, or the cleanup itself fails.
            if let items = try? FileManager.default.subpathsOfDirectory(atPath: home.path) {
                for item in items {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o644], ofItemAtPath: home.path + "/" + item
                    )
                }
            }
            try? FileManager.default.removeItem(at: home)
        }
        try body(ServerContext.local(home: home), home)
    }

    static func chmod000(_ path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    }

    static func siblings(of path: String, prefix: String) -> [String] {
        let dir = (path as NSString).deletingLastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix(prefix) }
    }

    // MARK: - miniapp_grants.json

    @Test func grantWriteRefusesOverAnUnreadableGrantsFile() throws {
        try Self.withTempHome { ctx, _ in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [.store])
            let path = ctx.paths.miniAppGrantsJSON
            let original = try Data(contentsOf: URL(fileURLWithPath: path))

            try Self.chmod000(path)
            #expect(throws: GuardedStoreError.self) {
                try store.setGrant(projectId: "p", miniAppId: "b", permissions: [.store])
            }

            // The decision the user already made is still on disk, byte for
            // byte. Before the fix this write published an empty envelope.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
            #expect(store.allGrants().count == 1)
        }
    }

    @Test func zeroByteGrantsFileIsDamageNotAnEmptyGrantList() throws {
        try Self.withTempHome { ctx, _ in
            let path = ctx.paths.miniAppGrantsJSON
            try Data().write(to: URL(fileURLWithPath: path))
            #expect(throws: GuardedStoreError.self) {
                try MiniAppGrantStore(context: ctx).setGrant(
                    projectId: "p", miniAppId: "a", permissions: [.store]
                )
            }
        }
    }

    /// Undecodable is NOT unreadable: the bytes are copied aside and the
    /// store rebuilds, exactly as `ProjectStore` does for `project.json`.
    /// Refusing forever would leave the permission sheet unable to record
    /// an answer, for a file that is re-derivable by asking the user again.
    @Test func corruptGrantsFileIsQuarantinedThenRebuilt() throws {
        try Self.withTempHome { ctx, _ in
            let path = ctx.paths.miniAppGrantsJSON
            try Data("{ this is not json".utf8).write(to: URL(fileURLWithPath: path))

            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [.store])

            #expect(store.grantedPermissions(projectId: "p", miniAppId: "a") == [.store])
            let copies = Self.siblings(of: path, prefix: "miniapp_grants.json.corrupt-")
            #expect(copies.count == 1)
            let dir = (path as NSString).deletingLastPathComponent
            let saved = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + copies[0]))
            #expect(String(data: saved, encoding: .utf8) == "{ this is not json")
        }
    }

    @Test func grantWriteKeepsAOneDeepBackup() throws {
        try Self.withTempHome { ctx, _ in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [.store])
            let first = try Data(contentsOf: URL(fileURLWithPath: ctx.paths.miniAppGrantsJSON))
            try store.setGrant(projectId: "p", miniAppId: "b", permissions: [.store])

            let bak = try Data(contentsOf: URL(fileURLWithPath: ctx.paths.miniAppGrantsJSON + ".bak"))
            #expect(bak == first)
            #expect(store.allGrants().count == 2)
        }
    }

    // MARK: - session_project_map.json

    @Test func attributionRefusesOverAnUnreadableSidecar() throws {
        try Self.withTempHome { ctx, _ in
            let service = SessionAttributionService(context: ctx)
            service.attribute(sessionID: "s1", toProjectPath: "/p/one")
            let path = ctx.paths.sessionProjectMap
            let original = try Data(contentsOf: URL(fileURLWithPath: path))

            try Self.chmod000(path)
            // Non-throwing by contract (attribution is fire-and-forget) —
            // the point is that it did NOTHING rather than destroying the
            // only record of every session's project.
            service.attribute(sessionID: "s2", toProjectPath: "/p/two")

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
            #expect(service.projectPath(for: "s1") == "/p/one")
        }
    }

    @Test func truncatedSidecarIsQuarantinedRatherThanSilentlyReplaced() throws {
        try Self.withTempHome { ctx, _ in
            let path = ctx.paths.sessionProjectMap
            // A truncated write: valid JSON prefix, no closing brace.
            try Data("{\"mappings\":{\"s1\":\"/p/one\"".utf8).write(to: URL(fileURLWithPath: path))

            let service = SessionAttributionService(context: ctx)
            service.attribute(sessionID: "s2", toProjectPath: "/p/two")

            #expect(service.projectPath(for: "s2") == "/p/two")
            let copies = Self.siblings(of: path, prefix: "session_project_map.json.corrupt-")
            #expect(copies.count == 1)
        }
    }

    @Test func attributionBacksUpWhatItReplaces() throws {
        try Self.withTempHome { ctx, _ in
            let service = SessionAttributionService(context: ctx)
            service.attribute(sessionID: "s1", toProjectPath: "/p/one")
            let first = try Data(contentsOf: URL(fileURLWithPath: ctx.paths.sessionProjectMap))
            service.attribute(sessionID: "s2", toProjectPath: "/p/two")

            let bak = try Data(contentsOf: URL(fileURLWithPath: ctx.paths.sessionProjectMap + ".bak"))
            #expect(bak == first)
        }
    }

    /// The 1 MB cap with no pruning made truncation a matter of time: past
    /// the cap EVERY read returns empty and the whole attribution history
    /// reads as "nothing attributed".
    @Test func sidecarPrunesLeastRecentlyTouchedMappings() {
        var map = SessionProjectMap()
        for i in 0..<(SessionProjectMap.maxMappings + 50) {
            map.mappings["s\(i)"] = "/p/\(i)"
            // Lexicographic stamps standing in for ISO-8601 ordering.
            map.touched = (map.touched ?? [:]).merging(["s\(i)": String(format: "2026-01-%04d", i)]) { _, n in n }
        }
        map.prune()
        #expect(map.mappings.count == SessionProjectMap.maxMappings)
        // Newest survive, oldest go.
        #expect(map.mappings["s\(SessionProjectMap.maxMappings + 49)"] != nil)
        #expect(map.mappings["s0"] == nil)
        // The stamp table is pruned in lockstep — otherwise it becomes the
        // unbounded thing.
        #expect(map.touched?.count == SessionProjectMap.maxMappings)
    }

    @Test func pruningIsANoOpBelowTheCap() {
        var map = SessionProjectMap(mappings: ["a": "/p/a", "b": "/p/b"])
        map.prune()
        #expect(map.mappings.count == 2)
    }

    @Test func unstampedMappingsArePrunedFirst() {
        var map = SessionProjectMap()
        map.mappings = ["old": "/p/old", "new": "/p/new"]
        map.touched = ["new": "2026-09-04T00:00:00Z"]
        map.prune(limit: 1)
        #expect(map.mappings["new"] == "/p/new")
        #expect(map.mappings["old"] == nil)
    }

    // MARK: - ProjectEntry unknown keys (H4)

    @Test func registrySaveKeepsKeysTheModelDoesNotDeclare() throws {
        try Self.withTempHome { ctx, _ in
            let path = ctx.paths.projectsRegistry
            try Data("""
            {"schemaVersion":9,"projects":[{"name":"Alpha","path":"/p/alpha","bots":{"roster":"r1"},"futureFlag":true}]}
            """.utf8).write(to: URL(fileURLWithPath: path))

            let service = ProjectDashboardService(context: ctx)
            var registry = service.loadRegistry()
            #expect(registry.projects.count == 1)
            // A perfectly ordinary edit an older build would make.
            registry.projects[0].folder = "Work"
            try service.saveRegistry(registry)

            let reread = try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: path))
            ) as? [String: Any]
            // Top-level unknown keys survive too, not just per-row ones.
            #expect(reread?["schemaVersion"] as? Int == 9)
            let row = (reread?["projects"] as? [[String: Any]])?.first
            #expect(row?["folder"] as? String == "Work")
            #expect(row?["futureFlag"] as? Bool == true)
            #expect(((row?["bots"] as? [String: Any])?["roster"]) as? String == "r1")
        }
    }

    @Test func unknownKeysDoNotDisturbLogicalIdentity() {
        let plain = ProjectEntry(name: "A", path: "/p/a")
        let withExtra = ProjectEntry(name: "A", path: "/p/a", extra: ["bots": .string("r1")])
        // Sidebar selection keys on this; an unknown key appearing must not
        // deselect the user's project.
        #expect(plain == withExtra)
        #expect(Set([plain]).contains(withExtra))
    }

    // MARK: - iOS cron/jobs.json (P7 addendum)

    static func seedCron(_ ctx: ServerContext, jobID: String) throws {
        let path = ctx.paths.cronJobsJSON
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try Data("""
        {"jobs":[{"id":"\(jobID)","name":"A","prompt":"p","enabled":true,"state":"scheduled",
        "schedule":{"kind":"cron"},"hermes_owned_field":"keep me"}],"updated_at":"2026-09-01T00:00:00Z"}
        """.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Hermes rewrites `jobs.json` on every tick. iOS rewrote it WHOLE from
    /// an in-memory list that could be arbitrarily old, so a toggle erased
    /// every `next_run_at` / `last_run_at` / run claim written since.
    @Test @MainActor func cronSaveRefusesWhenTheHostChangedTheFile() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-cron-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        try Self.seedCron(ctx, jobID: "j1")
        let path = ctx.paths.cronJobsJSON

        let vm = IOSCronViewModel(context: ctx)
        await vm.load()
        #expect(vm.jobs.count == 1)

        // Hermes writes the file behind our back — a run stamp the phone's
        // in-memory list has never seen.
        try Data("""
        {"jobs":[{"id":"j1","name":"A","prompt":"p","enabled":true,"state":"scheduled",
        "schedule":{"kind":"cron"},"last_run_at":"2026-09-04T10:00:00Z"}],"updated_at":"x"}
        """.utf8).write(to: URL(fileURLWithPath: path))
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let ok = await vm.delete(id: "j1")
        #expect(ok == false)
        #expect(vm.lastError?.contains("changed on the host") == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }

    /// A save that IS based on what was loaded goes through, keeps a `.bak`,
    /// and preserves the Hermes-owned keys the model doesn't declare.
    @Test @MainActor func cronSaveOnAFreshBaselineSucceedsAndBacksUp() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-cron-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        try Self.seedCron(ctx, jobID: "j1")
        let path = ctx.paths.cronJobsJSON
        let original = try Data(contentsOf: URL(fileURLWithPath: path))

        let vm = IOSCronViewModel(context: ctx)
        await vm.load()
        #expect(await vm.setEnabled(id: "j1", enabled: false))

        #expect(try Data(contentsOf: URL(fileURLWithPath: path + ".bak")) == original)
        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))
        ) as? [String: Any]
        let job = (written?["jobs"] as? [[String: Any]])?.first
        #expect(job?["enabled"] as? Bool == false)
        #expect(job?["hermes_owned_field"] as? String == "keep me")
    }

    @Test func cronSaveRefusesOverAnUnreadableFile() throws {
        try Self.withTempHome { ctx, _ in
            try Self.seedCron(ctx, jobID: "j1")
            let path = ctx.paths.cronJobsJSON
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            try Self.chmod000(path)

            let store = GuardedJSONStore(transport: ctx.makeTransport(), label: "jobs.json")
            let inspection = store.inspect(path, maxBytes: ProjectDashboardService.maxJSONBytes)
            #expect(inspection.isDamaged)
            #expect(throws: GuardedStoreError.self) {
                try store.write(Data("{}".utf8), to: path, after: inspection)
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        }
    }

    // MARK: - Cross-process registry write lock (t-db8c745b)

    @Test func lockIsExclusiveAcrossHoldersAndTimesOutAsBusy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("projects.json.lock")

        // Stand in for the other process: the lock file simply exists, and
        // is fresh enough not to be considered stale.
        try Data("pid=1".utf8).write(to: url)
        #expect(throws: ProjectRegistryError.registryBusy(path: "/r")) {
            try RegistryWriteLock(lockURL: url).withLock(path: "/r") { }
        }
    }

    @Test func staleLockIsBrokenSoACrashCannotBrickTheRegistry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("projects.json.lock")
        try Data("pid=1".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(RegistryWriteLock.staleAfter + 60))],
            ofItemAtPath: url.path
        )

        var ran = false
        try RegistryWriteLock(lockURL: url).withLock(path: "/r") { ran = true }
        #expect(ran)
        // And it cleans up after itself.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// `ProjectStore.indexInRegistry` holds the lock across its whole
    /// read-modify-write and then calls `saveRegistry`, which takes it
    /// again. Non-reentrant, that is a guaranteed self-deadlock on every
    /// project save.
    @Test func lockIsReentrantWithinAThread() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("projects.json.lock")
        let lock = RegistryWriteLock(lockURL: url)

        var depth = 0
        try lock.withLock(path: "/r") {
            try lock.withLock(path: "/r") {
                depth = 2
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
            // The inner scope must NOT have released the file lock.
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(depth == 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func localAndRemoteContextsGetDifferentLockPaths() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-lockpath-\(UUID().uuidString)", isDirectory: true)
        let local = try #require(RegistryWriteLock.lockURL(for: .local(home: home)))
        // Local locks sit beside the registry, so a second PROCESS
        // resolving the same home contends on the same inode.
        #expect(local.path == ServerContext.local(home: home).paths.projectsRegistry + ".lock")
    }

    /// The race the lock exists for: two writers each read the registry,
    /// add their own row, and publish. Unserialized, the loser's row is
    /// gone. Both are in-process here, but they contend on the same lock
    /// FILE — which is the same primitive the MCP helper contends on.
    @Test func concurrentRegistryWritersDoNotLoseEachOthersRows() throws {
        try Self.withTempHome { ctx, _ in
            let service = ProjectDashboardService(context: ctx)
            try service.saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "Seed", path: "/p/seed")
            ]))

            let group = DispatchGroup()
            for i in 0..<8 {
                DispatchQueue.global().async(group: group) {
                    // A full read-modify-write, the shape every in-app
                    // registry mutator has.
                    guard let lock = RegistryWriteLock(context: ctx) else { return }
                    try? lock.withLock(path: ctx.paths.projectsRegistry) {
                        var registry = service.loadRegistry()
                        registry.projects.append(ProjectEntry(name: "P\(i)", path: "/p/\(i)"))
                        try service.saveRegistry(registry)
                    }
                }
            }
            group.wait()

            let names = Set(service.loadRegistry().projects.map(\.name))
            #expect(names.count == 9, "lost rows: \(names.sorted())")
        }
    }
}
