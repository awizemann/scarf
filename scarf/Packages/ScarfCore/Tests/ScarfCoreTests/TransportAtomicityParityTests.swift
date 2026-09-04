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

        func writeFile(_ path: String, data: Data) throws {
            if failWrites { throw TransportError.other(message: "connection reset") }
            lock.withLock {
                files[path] = data
                writes.append(path)
            }
        }

        func fileExists(_ path: String) -> Bool {
            lock.withLock { files[path] != nil || files.keys.contains { $0.hasPrefix(path + "/") } }
        }

        func stat(_ path: String) -> FileStat? {
            if failStat { return nil }
            guard let data = lock.withLock({ files[path] }) else { return nil }
            return FileStat(size: Int64(data.count), mtime: Date(), isDirectory: false)
        }

        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws { _ = lock.withLock { files.removeValue(forKey: path) } }
        func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
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
            targetHome: "/home/u",
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
                targetHome: "/home/u",
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
                targetHome: "/home/u",
                mapping: ["/a": "/b"]
            )
        }
    }

    /// An absent registry is a legitimate outcome, not damage.
    @Test func reanchorIsANoOpWhenTheRegistryIsAbsent() async throws {
        let fake = FakeTransport()
        try await RemoteRestoreService(context: .local).reanchorProjectsRegistry(
            transport: fake,
            targetHome: "/home/u",
            mapping: ["/a": "/b"]
        )
        #expect(fake.contents("/home/u/.hermes/scarf/projects.json") == nil)
    }

    @Test func cronPauseFlipsEnabledJobsAndReportsTheCount() async throws {
        let jobs = #"{"jobs":[{"id":"1","enabled":true},{"id":"2","enabled":false},{"id":"3","enabled":true}]}"#
        let fake = FakeTransport(files: ["/home/u/.hermes/cron/jobs.json": Data(jobs.utf8)])
        let paused = try await RemoteRestoreService(context: .local)
            .pauseAllCronJobs(transport: fake, targetHome: "/home/u")
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
                .pauseAllCronJobs(transport: fake, targetHome: "/home/u")
        }
    }

    @Test func cronPauseReportsZeroWhenJobsFileIsAbsent() async throws {
        let paused = try await RemoteRestoreService(context: .local)
            .pauseAllCronJobs(transport: FakeTransport(), targetHome: "/home/u")
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
