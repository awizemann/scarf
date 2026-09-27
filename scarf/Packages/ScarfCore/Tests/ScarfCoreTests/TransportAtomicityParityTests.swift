import Testing
import Foundation
@testable import ScarfCore

/// t-a6f22379 — transport atomicity parity.
///
/// Three behaviours, all of which used to depend on a transport being
/// healthy and honest, and none of which were tested:
/// 1. `ProjectStore` tells ABSENT from UNREADABLE, so a blip can't get a
///    stripped record committed over a good one.
/// 2. `RemoteRestoreService` rewrites remote JSON through the transport
///    (atomic, `.bak`'d) and SURFACES failures instead of `try?`-ing them
///    into a reported success.
/// 3. `SSHTransport`'s scp remote spec is quoted and its staging name is
///    unique per write.
@Suite struct TransportAtomicityParityTests {

    // MARK: - Fake transport

    /// An in-memory filesystem with a switch for every failure mode the
    /// real remotes produce: reads that fail while the file is plainly
    /// there (a dropped `cat`), stats that fail too (a host that is gone),
    /// and writes that refuse.
    final class FakeTransport: ServerTransport, @unchecked Sendable {
        let contextID: ServerID = UUID()
        let isRemote: Bool = true

        private let lock = NSLock()
        private var files: [String: Data] = [:]
        var failReads = false
        var failStat = false
        var failWrites = false
        private(set) var writes: [String] = []

        init(files: [String: Data] = [:]) { self.files = files }

        func contents(_ path: String) -> Data? { lock.withLock { files[path] } }
        func seed(_ path: String, _ data: Data) { lock.withLock { files[path] = data } }

        func readFile(_ path: String) throws -> Data {
            if failReads { throw TransportError.other(message: "connection reset") }
            guard let data = lock.withLock({ files[path] }) else {
                throw TransportError.fileIO(path: path, underlying: "No such file or directory")
            }
            return data
        }

        func unguardedWriteFile(_ path: String, data: Data) throws {
            if failWrites { throw TransportError.other(message: "connection reset") }
            lock.withLock {
                files[path] = data
                writes.append(path)
            }
        }

        func fileExists(_ path: String) -> Bool {
            lock.withLock { files[path] != nil || files.keys.contains { $0.hasPrefix(path + "/") } }
        }

        var failList = false

        func stat(_ path: String) -> FileStat? {
            if failStat { return nil }
            guard let data = lock.withLock({ files[path] }) else {
                // A directory exists while any file lives under it.
                let isDir = lock.withLock { files.keys.contains { $0.hasPrefix(path + "/") } }
                return isDir ? FileStat(size: 0, mtime: Date(), isDirectory: true) : nil
            }
            return FileStat(size: Int64(data.count), mtime: Date(), isDirectory: false)
        }

        /// The immediate children of `path`, derived from the files under
        /// it; absent (nothing under it) throws, as the real transports do.
        func listDirectory(_ path: String) throws -> [String] {
            if failList { throw TransportError.other(message: "connection reset") }
            let children = lock.withLock {
                Set(files.keys.compactMap { key -> String? in
                    guard key.hasPrefix(path + "/") else { return nil }
                    return key.dropFirst(path.count + 1).split(separator: "/").first.map(String.init)
                })
            }
            guard !children.isEmpty else {
                throw TransportError.fileIO(path: path, underlying: "No such file or directory")
            }
            return children.sorted()
        }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws { _ = lock.withLock { files.removeValue(forKey: path) } }
        func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        #if !os(iOS)
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        #endif
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }
    }

    private static func encodedRecord(_ project: ScarfProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    // MARK: - project.json: absent vs unreadable

    @Test func recordLoadReportsAbsentWhenNothingIsThere() {
        let store = ProjectStore(context: .local, transport: FakeTransport())
        #expect(store.loadDetailed(projectPath: "/p") == .absent)
    }

    @Test func recordLoadReportsUnreadableWhenStatConfirmsAndReadsFail() throws {
        let path = ProjectStore.recordPath(forProjectPath: "/p")
        let fake = FakeTransport(files: [path: try Self.encodedRecord(
            ScarfProject(id: UUID(), name: "P", rootPath: "/p")
        )])
        fake.failReads = true
        let store = ProjectStore(context: .local, transport: fake)
        #expect(store.loadDetailed(projectPath: "/p") == .unreadable(path: path))
    }

    /// A transport too sick to even stat must NOT be reported as damage:
    /// that would refuse writes on a host where nothing is known to exist,
    /// and first-launch would never get its first record.
    @Test func recordLoadReportsAbsentWhenTransportCannotStatEither() throws {
        let path = ProjectStore.recordPath(forProjectPath: "/p")
        let fake = FakeTransport(files: [path: Data("{}".utf8)])
        fake.failReads = true
        fake.failStat = true
        #expect(ProjectStore(context: .local, transport: fake).loadDetailed(projectPath: "/p") == .absent)
    }

    /// Unparseable is NOT unreadable — the record is regenerable from
    /// facets, so the writers must stay allowed to replace it.
    @Test func unparseableRecordReadsAsAbsentSoItCanBeRebuilt() {
        let path = ProjectStore.recordPath(forProjectPath: "/p")
        let fake = FakeTransport(files: [path: Data("not json".utf8)])
        #expect(ProjectStore(context: .local, transport: fake).loadDetailed(projectPath: "/p") == .absent)
    }

    @Test func saveRefusesToOverwriteAnUnreadableRecord() throws {
        let path = ProjectStore.recordPath(forProjectPath: "/p")
        let good = ScarfProject(id: UUID(), name: "P", rootPath: "/p", modelPresetId: "fast")
        let fake = FakeTransport(files: ["/p": Data(), path: try Self.encodedRecord(good)])
        fake.failReads = true
        let store = ProjectStore(context: .local, transport: fake)

        // The stripped record a `load(…) ?? derive(…)` caller would build
        // over a sick transport: same path, none of the facets.
        let stripped = ScarfProject(id: good.id, name: "P", rootPath: "/p")
        #expect(throws: ProjectStoreError.refusedUnreadableRecord(path: path)) {
            try store.save(stripped)
        }
        // And the good bytes are still on disk, untouched.
        fake.failReads = false
        #expect(store.load(projectPath: "/p")?.modelPresetId == "fast")
    }

    @Test func saveBacksUpThePreviousRecordBeforeReplacingIt() throws {
        let path = ProjectStore.recordPath(forProjectPath: "/p")
        let first = ScarfProject(id: UUID(), name: "P", rootPath: "/p", modelPresetId: "fast")
        let fake = FakeTransport(files: ["/p": Data(), path: try Self.encodedRecord(first)])
        let store = ProjectStore(context: .local, transport: fake)

        try? store.save(ScarfProject(id: first.id, name: "P", rootPath: "/p", modelPresetId: "slow"))

        let backup = try #require(fake.contents(path + ".bak"))
        #expect(try JSONDecoder().decode(ScarfProject.self, from: backup).modelPresetId == "fast")
    }

    // MARK: - RemoteRestoreService: honest failures

    @Test func reanchorRewritesPathsAndPreservesUnknownKeys() async throws {
        let registry = """
        {"projects":[{"name":"A","path":"/root/projects/a","futureField":7}],"schemaOfTomorrow":true}
        """
        let fake = FakeTransport(files: ["/home/u/.hermes/scarf/projects.json": Data(registry.utf8)])
        let service = RemoteRestoreService(context: .local)

        try await service.reanchorProjectsRegistry(
            transport: fake,
            hermesHome: "/home/u/.hermes",
            mapping: ["/root/projects/a": "/home/u/projects/a"]
        )

        let written = try #require(fake.contents("/home/u/.hermes/scarf/projects.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        let entry = try #require((root["projects"] as? [[String: Any]])?.first)
        #expect(entry["path"] as? String == "/home/u/projects/a")
        #expect(entry["futureField"] as? Int == 7)
        #expect(root["schemaOfTomorrow"] as? Bool == true)
        // Previous contents kept alongside.
        #expect(fake.contents("/home/u/.hermes/scarf/projects.json.bak") == Data(registry.utf8))
    }

    /// The headline regression: a rewrite that could not happen used to
    /// report success (`try?` + a nil result read as "fine").
    @Test func reanchorThrowsWhenTheRegistryIsThereButUnreadable() async throws {
        let fake = FakeTransport(files: ["/home/u/.hermes/scarf/projects.json": Data("{}".utf8)])
        fake.failReads = true
        await #expect(throws: (any Error).self) {
            try await RemoteRestoreService(context: .local).reanchorProjectsRegistry(
                transport: fake,
                hermesHome: "/home/u/.hermes",
                mapping: ["/a": "/b"]
            )
        }
    }

    @Test func reanchorThrowsWhenTheWriteFails() async throws {
        let registry = #"{"projects":[{"name":"A","path":"/a"}]}"#
        let fake = FakeTransport(files: ["/home/u/.hermes/scarf/projects.json": Data(registry.utf8)])
        fake.failWrites = true
        await #expect(throws: (any Error).self) {
            try await RemoteRestoreService(context: .local).reanchorProjectsRegistry(
                transport: fake,
                hermesHome: "/home/u/.hermes",
                mapping: ["/a": "/b"]
            )
        }
    }

    /// An absent registry is a legitimate outcome, not damage.
    @Test func reanchorIsANoOpWhenTheRegistryIsAbsent() async throws {
        let fake = FakeTransport()
        try await RemoteRestoreService(context: .local).reanchorProjectsRegistry(
            transport: fake,
            hermesHome: "/home/u/.hermes",
            mapping: ["/a": "/b"]
        )
        #expect(fake.contents("/home/u/.hermes/scarf/projects.json") == nil)
    }

    @Test func cronPauseFlipsEnabledJobsAndReportsTheCount() async throws {
        let jobs = #"{"jobs":[{"id":"1","enabled":true},{"id":"2","enabled":false},{"id":"3","enabled":true}]}"#
        let fake = FakeTransport(files: ["/home/u/.hermes/cron/jobs.json": Data(jobs.utf8)])
        let paused = try await RemoteRestoreService(context: .local)
            .pauseAllCronJobs(transport: fake, hermesHome: "/home/u/.hermes")
        #expect(paused == 2)

        let written = try #require(fake.contents("/home/u/.hermes/cron/jobs.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        let enabled = try #require(root["jobs"] as? [[String: Any]]).compactMap { $0["enabled"] as? Bool }
        #expect(enabled == [false, false, false])
    }

    /// "0 jobs paused" must mean nothing needed pausing — never "the
    /// write failed and the restored jobs are still armed".
    @Test func cronPauseThrowsWhenTheWriteFails() async throws {
        let jobs = #"{"jobs":[{"id":"1","enabled":true}]}"#
        let fake = FakeTransport(files: ["/home/u/.hermes/cron/jobs.json": Data(jobs.utf8)])
        fake.failWrites = true
        await #expect(throws: (any Error).self) {
            _ = try await RemoteRestoreService(context: .local)
                .pauseAllCronJobs(transport: fake, hermesHome: "/home/u/.hermes")
        }
    }

    /// R16a X2: Hermes cron is per-profile (`cron/jobs.py:62-74` @
    /// v2026.9.24), so a restore must pause every profile's jobs, not only
    /// the root home's, and report the true total. A job with no `enabled`
    /// key is armed (Hermes defaults it to true) and is paused and counted.
    @Test func cronPausePausesEveryProfileAndReportsTheTotal() async throws {
        let home = "/home/u/.hermes"
        let rootJobs = #"{"jobs":[{"id":"r1","enabled":true,"state":"scheduled"},{"id":"r2","enabled":false,"state":"paused"}]}"#
        let workJobs = #"{"jobs":[{"id":"w1","enabled":true},{"id":"w2"},{"id":"w3","enabled":true,"state":"completed"}]}"#
        // Id-keyed map shape, which Hermes also loads.
        let mapJobs = #"{"jobs":{"m1":{"enabled":true,"state":"scheduled"},"m2":{"enabled":true,"paused_at":"2026-09-01T00:00:00+00:00"}}}"#
        let fake = FakeTransport(files: [
            home + "/cron/jobs.json": Data(rootJobs.utf8),
            home + "/profiles/work/cron/jobs.json": Data(workJobs.utf8),
            home + "/profiles/my team/cron/jobs.json": Data(mapJobs.utf8),
            home + "/profiles/empty/config.yaml": Data("model: x\n".utf8),
        ])
        let paused = try await RemoteRestoreService(context: .local)
            .pauseAllCronJobs(transport: fake, hermesHome: home)
        #expect(paused == 1 + 3 + 1)

        func jobs(_ path: String) throws -> [[String: Any]] {
            let data = try #require(fake.contents(path))
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            if let list = root["jobs"] as? [[String: Any]] { return list }
            let map = try #require(root["jobs"] as? [String: [String: Any]])
            return map.keys.sorted().map { map[$0]! }
        }
        for path in [home + "/cron/jobs.json", home + "/profiles/work/cron/jobs.json", home + "/profiles/my team/cron/jobs.json"] {
            for job in try jobs(path) {
                #expect(RemoteRestoreService.isRunnable(job) == false, "\(path): \(job)")
            }
        }
        // A half-paused record (enabled but carrying a pause marker) can't
        // fire in Hermes, so it is neither touched nor counted.
        let map = try jobs(home + "/profiles/my team/cron/jobs.json")
        #expect(map[0]["enabled"] as? Bool == false)
        #expect(map[1]["enabled"] as? Bool == true)
        let work = try jobs(home + "/profiles/work/cron/jobs.json")
        // Marked the way `hermes cron pause` marks it, so both apps show "paused".
        #expect(work[0]["state"] as? String == "paused")
        #expect(work[0]["paused_at"] is String)
        // A finished job keeps its terminal state.
        #expect(work[2]["state"] as? String == "completed")
        #expect(fake.contents(home + "/profiles/empty/cron/jobs.json") == nil, "no jobs file is created")
    }

    /// A profiles directory that is there but can't be listed must fail the
    /// pause, not report a count that silently skipped every profile.
    @Test func cronPauseThrowsWhenProfilesCannotBeListed() async throws {
        let home = "/home/u/.hermes"
        let fake = FakeTransport(files: [
            home + "/cron/jobs.json": Data(#"{"jobs":[{"id":"1","enabled":true}]}"#.utf8),
            home + "/profiles/work/cron/jobs.json": Data(#"{"jobs":[{"id":"w","enabled":true}]}"#.utf8),
        ])
        fake.failList = true
        await #expect(throws: (any Error).self) {
            _ = try await RemoteRestoreService(context: .local)
                .pauseAllCronJobs(transport: fake, hermesHome: home)
        }
        // The root home's jobs are still paused before the error surfaces.
        let rootData = try #require(fake.contents(home + "/cron/jobs.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: rootData) as? [String: Any])
        #expect((root["jobs"] as? [[String: Any]])?.first?["enabled"] as? Bool == false)
    }

    /// One bad `jobs.json` doesn't stop the others being paused; the error
    /// names it. A bare-list file (a shape Hermes loads and rewrites
    /// wrapped, `cron/jobs.py:1374-1376`) is paused and written wrapped.
    @Test func cronPauseTriesEveryHomeAndHandlesABareList() async throws {
        let home = "/home/u/.hermes"
        let fake = FakeTransport(files: [
            home + "/cron/jobs.json": Data(#"[{"id":"r","enabled":true}]"#.utf8),
            home + "/profiles/a/cron/jobs.json": Data("not json".utf8),
            home + "/profiles/b/cron/jobs.json": Data(#"{"jobs":[{"id":"b","enabled":true}]}"#.utf8),
        ])
        do {
            _ = try await RemoteRestoreService(context: .local).pauseAllCronJobs(transport: fake, hermesHome: home)
            Issue.record("a jobs.json that can't be parsed must fail the pause")
        } catch {
            #expect(error.localizedDescription.contains("profiles/a/cron/jobs.json"), "\(error.localizedDescription)")
            #expect(error.localizedDescription.contains("Paused 2"), "\(error.localizedDescription)")
        }
        for path in [home + "/cron/jobs.json", home + "/profiles/b/cron/jobs.json"] {
            let data = try #require(fake.contents(path))
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(path) written as an object")
            let jobs = try #require(root["jobs"] as? [[String: Any]])
            #expect(jobs.allSatisfy { $0["enabled"] as? Bool == false }, "\(path)")
        }
    }

    @Test func cronRunnableMatchesHermes() {
        #expect(RemoteRestoreService.isRunnable([:]))
        #expect(RemoteRestoreService.isRunnable(["enabled": 1]))
        #expect(!RemoteRestoreService.isRunnable(["enabled": 0]))
        #expect(!RemoteRestoreService.isRunnable(["enabled": NSNull()]))
        #expect(!RemoteRestoreService.isRunnable(["enabled": true, "state": "paused"]))
        #expect(!RemoteRestoreService.isRunnable(["enabled": true, "paused_at": "x"]))
        #expect(RemoteRestoreService.isRunnable(["enabled": true, "paused_at": ""]))
    }

    @Test func cronPauseReportsZeroWhenJobsFileIsAbsent() async throws {
        let paused = try await RemoteRestoreService(context: .local)
            .pauseAllCronJobs(transport: FakeTransport(), hermesHome: "/home/u/.hermes")
        #expect(paused == 0)
    }

    // MARK: - SSHTransport: scp spec quoting

    @Test func scpRemoteSpecQuotesSpacesButLeavesTildeExpandable() {
        #expect(SSHTransport.scpRemoteSpec("~/.hermes/scarf/projects.json") == "~/.hermes/scarf/projects.json")
        #expect(SSHTransport.scpRemoteSpec("~/My Projects/a.json") == "~/'My Projects/a.json'")
        #expect(SSHTransport.scpRemoteSpec("/tmp/a b") == "'/tmp/a b'")
        // A path that would otherwise run a command on the far side.
        #expect(SSHTransport.scpRemoteSpec("/tmp/$(rm -rf ~)") == "'/tmp/$(rm -rf ~)'")
    }
}
