import Testing
import Foundation
@testable import ScarfCore

/// GW-F5 — hardening the guard machinery itself.
///
/// Everything here is about the guards' OWN behaviour rather than about a
/// surface that uses them: the mode a fresh private file is born with
/// (SEC F2), the cap that has to refuse before it reads (SEC F3), what the
/// Skills picker is allowed to list (SEC F5 / DI L3), the private-mode list
/// (SEC F6), and the symlink-replacement property the whole `.bak` /
/// `.corrupt-` discipline silently relies on (audit I1).
@Suite struct GuardMachineryF5Tests {

    private static func scratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-f5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func mode(_ path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - SEC F2: the mode is decided BEFORE the bytes are published

    @Test("a brand-new private file is 0600 the instant it exists")
    func freshPrivateFileIsOwnerOnly() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let transport = LocalTransport()

        for name in [".env", ".env.bak", "auth.json", "servers.json",
                     "servers.json.corrupt-20260907T101112Z"] {
            let path = base.appendingPathComponent(name).path
            try transport.unguardedWriteFile(path, data: Data("k=v".utf8))
            let published = try Self.mode(path)
            #expect(published == 0o600, "\(name) was published as \(String(published, radix: 8))")
        }

        // The staging file is cleaned up, so the directory holds exactly the
        // files that were asked for — no `.scarf-write-*` litter to leak the
        // same bytes at a looser mode.
        let listed = try FileManager.default.contentsOfDirectory(atPath: base.path)
        #expect(!listed.contains { $0.hasPrefix(".scarf-write-") })
    }

    /// The race window itself (SEC F2), empirically. A poller watches the
    /// destination while the transport republishes it; because the mode is
    /// set on the staging file and the publish is a `rename(2)`, the path
    /// NEVER names a file whose mode is anything but `0600` — including on
    /// the very first write, which is the case the old
    /// `write(.atomic)`-then-`chmod` ordering left at `0644` for a window.
    @Test("the destination is never observable in a loose mode")
    func noLooseModeWindow() async throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent(".env").path
        let transport = LocalTransport()
        let payload = Data(String(repeating: "K=", count: 200_000).utf8)

        let observed = Observations()
        let poller = Task.detached {
            while !Task.isCancelled {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let m = (attrs[.posixPermissions] as? NSNumber)?.intValue {
                    observed.record(m)
                }
            }
        }
        for _ in 0..<40 {
            try transport.unguardedWriteFile(path, data: payload)
            try FileManager.default.removeItem(atPath: path)
        }
        poller.cancel()
        #expect(observed.modes().allSatisfy { $0 == 0o600 },
                "observed modes: \(observed.modes().map { String($0, radix: 8) })")
    }

    /// Existing-file permissions still survive a rewrite (audit I2 verified
    /// this held BEFORE the reorder; the reorder must not be what breaks it).
    /// Non-private files only — a private one is tightened on purpose.
    @Test("a non-private file keeps the mode it already had")
    func existingModeSurvivesRewrite() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let transport = LocalTransport()

        for original in [0o644, 0o755, 0o640] {
            let path = base.appendingPathComponent("notes-\(original).md").path
            try Data("one".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes(
                [.posixPermissions: original], ofItemAtPath: path
            )
            try transport.unguardedWriteFile(path, data: Data("two".utf8))
            #expect(try Self.mode(path) == original)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("two".utf8))
        }
    }

    @Test("a missing parent directory is still created")
    func parentIsStillCreated() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("a/b/c/MEMORY.md").path
        try LocalTransport().unguardedWriteFile(path, data: Data("hi".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("hi".utf8))
    }

    // MARK: - audit I1: a planted symlink is REPLACED, never followed

    /// The highest-value attack the E5 audit checked by hand and left
    /// unpinned: an attacker (or a confused agent) plants a symlink where a
    /// guarded writer is about to drop `<name>.bak` or
    /// `<name>.corrupt-<stamp>`, hoping the secrets in it land somewhere
    /// world-readable. The publish is a `rename(2)` onto the destination
    /// NAME, which replaces the symlink itself rather than writing through
    /// it, so the link's target never sees a byte.
    ///
    /// **Local only, by construction.** `SSHTransport` and
    /// `CitadelServerTransport` inherit the same property from the same
    /// primitive — a remote `mv`/SFTP rename onto a path replaces the entry —
    /// but pinning it here would need a live remote host; this test pins the
    /// transport whose semantics can actually be exercised, and the parity
    /// note ("transport atomic-write parity is a per-transport contract")
    /// carries the argument for the other two.
    @Test("a pre-planted symlink at the destination is replaced, not followed")
    func symlinkAtDestinationIsReplaced() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let transport = LocalTransport()

        // 1. A symlink pointing at a real file elsewhere.
        let victim = base.appendingPathComponent("victim.txt").path
        try Data("untouched".utf8).write(to: URL(fileURLWithPath: victim))
        let bak = base.appendingPathComponent(".env.bak").path
        try FileManager.default.createSymbolicLink(atPath: bak, withDestinationPath: victim)

        try transport.unguardedWriteFile(bak, data: Data("SECRET=1".utf8))

        #expect(try Data(contentsOf: URL(fileURLWithPath: victim)) == Data("untouched".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: bak)) == Data("SECRET=1".utf8))
        let type = try FileManager.default.attributesOfItem(atPath: bak)[.type] as? FileAttributeType
        #expect(type == .typeRegular, "the symlink survived the publish")
        // …and the replacement is owner-only, because `.env.bak` is `.env`.
        #expect(try Self.mode(bak) == 0o600)

        // 2. A DANGLING symlink — the shape that would otherwise CREATE the
        // attacker's chosen path on the first write.
        let nowhere = base.appendingPathComponent("nowhere/deep.txt").path
        let corrupt = base.appendingPathComponent("servers.json.corrupt-20260907T101112Z").path
        try FileManager.default.createSymbolicLink(atPath: corrupt, withDestinationPath: nowhere)

        try transport.unguardedWriteFile(corrupt, data: Data("[]".utf8))

        #expect(!FileManager.default.fileExists(atPath: nowhere))
        #expect(try Data(contentsOf: URL(fileURLWithPath: corrupt)) == Data("[]".utf8))
        #expect(try Self.mode(corrupt) == 0o600)
    }

    // MARK: - SEC F3: the cap refuses BEFORE the read

    @Test("an over-cap file is refused without ever being read")
    func overCapFileIsNeverRead() {
        let spy = ProbeSpyTransport(size: 5_000_000)
        let store = GuardedJSONStore(transport: spy, label: "big.json")
        let inspection = store.inspect("/fake/big.json", maxBytes: 1 * 1024 * 1024)

        #expect(inspection.state == .unreadable(path: "/fake/big.json"))
        // The whole point: no bytes were pulled across the transport…
        #expect(spy.reads() == 0)
        // …and nothing was copied aside, because there was nothing to copy.
        #expect(inspection.bytes == nil)
        #expect(inspection.quarantineCopy == nil)
        #expect(spy.writes() == 0)
    }

    @Test("an uncapped inspection pays no stat and exactly one read")
    func uncappedLoadCostsOneRead() {
        let spy = ProbeSpyTransport(size: 10, contents: Data("{\"a\":1}".utf8))
        let store = GuardedJSONStore(transport: spy, label: "small.json")
        let inspection = store.inspect("/fake/small.json", maxBytes: Int.max)

        #expect(inspection.state == .present)
        #expect(spy.stats() == 0)
        #expect(spy.reads() == 1)
    }

    @Test("a healthy capped load pays the stat and one read, and nothing more")
    func healthyCappedLoadCost() {
        let spy = ProbeSpyTransport(size: 7, contents: Data("{\"a\":1}".utf8))
        let store = GuardedJSONStore(transport: spy, label: "small.json")
        let inspection = store.inspect("/fake/small.json", maxBytes: 1024)

        #expect(inspection.state == .present)
        #expect(spy.stats() == 1)
        #expect(spy.reads() == 1)
    }

    /// The correlated-probe semantics must be exactly what they were: the
    /// stat-first branch only fires when a stat SUCCEEDS and reports a size
    /// past the cap, so an unstattable path still decides absent-vs-unreadable
    /// the old way.
    @Test("stat-first does not change the absent or unreadable verdicts")
    func verdictsAreUnchanged() {
        let absent = ProbeSpyTransport(size: nil, contents: nil)
        #expect(GuardedJSONStore(transport: absent, label: "x.json")
            .inspect("/fake/x.json", maxBytes: 1024).state == .absent)

        let damaged = ProbeSpyTransport(size: 10, contents: nil)
        #expect(GuardedJSONStore(transport: damaged, label: "x.json")
            .inspect("/fake/x.json", maxBytes: 1024).state == .unreadable(path: "/fake/x.json"))

        let empty = ProbeSpyTransport(size: 0, contents: Data())
        #expect(GuardedJSONStore(transport: empty, label: "x.json")
            .inspect("/fake/x.json", maxBytes: 1024).state == .unreadable(path: "/fake/x.json"))
    }

    /// The text guard turns the size refusal into its own user-facing
    /// refusal, and — the part that matters — publishes nothing.
    @Test("GuardedTextFile refuses an over-cap file and writes nothing")
    func textFileRefusesOverCap() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("MEMORY.md").path
        let huge = Data(String(repeating: "m", count: 4096).utf8)
        try huge.write(to: URL(fileURLWithPath: path))

        let guarded = GuardedTextFile(transport: LocalTransport(), label: "MEMORY.md")
        #expect(throws: GuardedTextFile.Refusal.unreadable(path: path, label: "MEMORY.md")) {
            _ = try guarded.load(path, maxBytes: 1024)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == huge)
        // No quarantine copy: the bytes were never held.
        let listed = try FileManager.default.contentsOfDirectory(atPath: base.path)
        #expect(!listed.contains { $0.contains(".corrupt-") })
    }

    // MARK: - SEC F6: servers.json is private-mode

    @Test("servers.json and its guard artifacts are private-mode")
    func serversJSONIsPrivate() {
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/.hermes/servers.json"))
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/.hermes/servers.json.bak"))
        #expect(TransportPrivateMode.shouldEnforce(
            for: "/h/.hermes/servers.json.corrupt-20260907T101112Z"))
        #expect(TransportPrivateMode.shouldEnforce(
            for: "/h/.hermes/servers.json.bak.corrupt-20260907T101112Z"))
        // Unrelated JSON stays where it was.
        #expect(!TransportPrivateMode.shouldEnforce(for: "/h/.hermes/projects.json"))
    }

    // MARK: - SEC F5 / DI L3: the Skills picker lists content, not artifacts

    @Test("guard artifacts are recognised by both shapes")
    func guardArtifactShapes() {
        #expect(SkillsScanner.isGuardArtifact("SKILL.md.bak"))
        #expect(SkillsScanner.isGuardArtifact("SKILL.md.corrupt-20260907T101112Z"))
        #expect(SkillsScanner.isGuardArtifact("skill.yaml.corrupt-20260907T101112Z-a1b2c3d4"))
        #expect(SkillsScanner.isGuardArtifact("SKILL.md.bak.corrupt-20260907T101112Z"))
        #expect(!SkillsScanner.isGuardArtifact("SKILL.md"))
        #expect(!SkillsScanner.isGuardArtifact("corrupt-handling.md"))
        #expect(!SkillsScanner.isGuardArtifact("bakery.md"))
    }

    @Test("the scanner drops .bak and .corrupt- copies from a skill's files")
    func scannerFiltersGuardArtifacts() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = ServerContext.local(home: home)
        let skillDir = home.appendingPathComponent("skills/writing/haiku", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        for name in ["SKILL.md", "SKILL.md.bak", "SKILL.md.corrupt-20260907T101112Z",
                     "skill.yaml", "reference.md"] {
            try Data("x".utf8).write(to: skillDir.appendingPathComponent(name))
        }

        let categories = SkillsScanner.scan(context: context, transport: LocalTransport())
        let skill = try #require(categories.first?.skills.first)
        #expect(skill.files == ["SKILL.md", "reference.md", "skill.yaml"])
    }
}

/// Records what a `ServerTransport` was asked to do, and answers from a
/// script rather than a filesystem — the only way to prove a read did NOT
/// happen.
private final class ProbeSpyTransport: ServerTransport, @unchecked Sendable {
    let contextID: ServerID = UUID()
    let isRemote: Bool = true

    private let size: Int64?
    private let contents: Data?
    private let lock = NSLock()
    private var readCount = 0
    private var statCount = 0
    private var writeCount = 0

    /// - Parameters:
    ///   - size: what `stat` reports, or `nil` for "cannot stat".
    ///   - contents: what `readFile` returns, or `nil` for "read fails".
    init(size: Int64?, contents: Data? = nil) {
        self.size = size
        self.contents = contents
    }

    func reads() -> Int { lock.lock(); defer { lock.unlock() }; return readCount }
    func stats() -> Int { lock.lock(); defer { lock.unlock() }; return statCount }
    func writes() -> Int { lock.lock(); defer { lock.unlock() }; return writeCount }

    func readFile(_ path: String) throws -> Data {
        lock.lock(); readCount += 1; lock.unlock()
        guard let contents else { throw TransportError.other(message: "read failed") }
        return contents
    }
    func unguardedWriteFile(_ path: String, data: Data) throws {
        lock.lock(); writeCount += 1; lock.unlock()
    }
    func fileExists(_ path: String) -> Bool { size != nil }
    func stat(_ path: String) -> FileStat? {
        lock.lock(); statCount += 1; lock.unlock()
        guard let size else { return nil }
        return FileStat(size: size, mtime: Date(), isDirectory: false)
    }
    func listDirectory(_ path: String) throws -> [String] { [] }
    func createDirectory(_ path: String) throws {}
    func removeFile(_ path: String) throws {}
    func runProcess(
        executable: String, args: [String], stdin: Data?, timeout: TimeInterval
    ) throws -> ProcessResult {
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
    func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        AsyncStream { $0.finish() }
    }
}

/// Thread-safe bag of observed POSIX modes.
private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<Int> = []
    func record(_ mode: Int) { lock.lock(); seen.insert(mode); lock.unlock() }
    func modes() -> [Int] { lock.lock(); defer { lock.unlock() }; return Array(seen) }
}
