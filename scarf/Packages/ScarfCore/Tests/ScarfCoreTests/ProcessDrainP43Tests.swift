#if !os(iOS)
import Foundation
import Testing
@testable import ScarfCore

/// Round-4 P43, decision 15: `Process.waitDraining` lives in ScarfCore now,
/// and the package's own `unzip`/`zip` spawns use it.
///
/// Every test here spawns a REAL child. The shapes that matter are the two
/// that used to wedge a caller forever:
///
/// * a child that writes more than the 64 KB pipe buffer before exiting — the
///   classic `run` → `waitUntilExit` → `readToEnd` deadlock, where the child
///   blocks in `write()` and the parent blocks in `wait()`;
/// * a child that never exits at all.
///
/// Both are held to short budgets so the suite stays fast.
@Suite("Process drain + timeout (P43)")
struct ProcessDrainP43Tests {

    /// 200 KB — comfortably past the 64 KB pipe buffer that makes the
    /// deadlock reachable, small enough to produce in milliseconds.
    static let chattyBytes = 200_000

    /// Emit `chattyBytes` of `x` on stderr, then do `then`.
    static func chattyChild(then: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [
            "-c",
            "head -c \(chattyBytes) /dev/zero | tr '\\000' 'x' 1>&2; \(then)",
        ]
        return p
    }

    // MARK: - The primitive, now in ScarfCore

    @Test("a chatty child past the pipe buffer exits and its output arrives whole")
    func chattyChildDoesNotDeadlock() throws {
        let proc = Self.chattyChild(then: "exit 3")
        let err = Pipe()
        let out = Pipe()
        proc.standardError = err
        proc.standardOutput = out
        try proc.run()

        let (exited, drained) = proc.waitDraining(timeout: 20, pipes: [err, out])
        try? err.fileHandleForWriting.close()
        try? out.fileHandleForWriting.close()

        #expect(exited, "the child exits on its own; only an undrained pipe could stop it")
        let stderrData = try #require(drained.first)
        #expect(stderrData.count == Self.chattyBytes)
        #expect(proc.terminationStatus == 3)
    }

    @Test("a child that never exits is given up on inside the budget")
    func hangingChildIsBounded() throws {
        let proc = Self.chattyChild(then: "sleep 30")
        let err = Pipe()
        proc.standardError = err
        try proc.run()

        let started = Date()
        let (exited, drained) = proc.waitDraining(timeout: 0.5, pipes: [err])
        let elapsed = Date().timeIntervalSince(started)
        try? err.fileHandleForWriting.close()

        #expect(!exited)
        // 0.5 s budget + the SIGTERM grace + the drain grace. The point is
        // that it RETURNED: a bare `waitUntilExit()` here waits forever.
        #expect(elapsed < 10, "waitDraining took \(elapsed)s")
        // What the child managed to write before the deadline is still handed
        // back — the reader ran concurrently with the wait, not after it.
        let stderrData = try #require(drained.first)
        #expect(stderrData.count == Self.chattyBytes)
    }

    // MARK: - The three ScarfCore archive spawns

    /// A zip holding one 24 MB member, so extraction is long enough that a
    /// sub-millisecond budget cannot be met by a child that has only just
    /// been `exec`ed.
    static func makeFatZip(in dir: URL) throws -> URL {
        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(count: 24 * 1024 * 1024)
            .write(to: staging.appendingPathComponent("fat.bin"))
        let archive = dir.appendingPathComponent("fat.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-rqX", archive.path, "."]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        #expect(zip.waitUntilExit(timeout: 60))
        return archive
    }

    static func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p43-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("restore's unzip refuses instead of hanging when it outstays its budget")
    func unzipArchiveIsBounded() throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Self.makeFatZip(in: dir)
        let dest = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        var thrown: Error?
        do {
            try RemoteRestoreService.unzipArchive(at: archive, into: dest, timeout: 0.001)
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "a 1 ms budget cannot be met by a freshly exec'd unzip")
        #expect("\(error)".contains("did not finish"))
    }

    @Test("restore's unzip still succeeds on a sane archive within its budget")
    func unzipArchiveSucceeds() throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Self.makeFatZip(in: dir)
        let dest = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try RemoteRestoreService.unzipArchive(at: archive, into: dest, timeout: 60)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("fat.bin").path))
    }

    @Test("backup's zip refuses instead of hanging when it outstays its budget")
    func zipDirectoryIsBounded() throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Incompressible, so `zip` cannot shortcut its way under the budget.
        let urandom = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
        defer { try? urandom.close() }
        let bytes = urandom.readData(ofLength: 24 * 1024 * 1024)
        try bytes.write(to: work.appendingPathComponent("noise.bin"))

        var thrown: Error?
        do {
            try RemoteBackupService.zipDirectory(
                workDir: work, into: dir.appendingPathComponent("o.zip"), timeout: 0.001)
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "a 1 ms budget cannot be met by a freshly exec'd zip")
        #expect("\(error)".contains("did not finish"))
    }

    @Test("the archive budgets are named and ordered")
    func budgetsAreNamed() {
        // The remote extract begins only after the whole tarball is already
        // through the pipe, so it is the shorter of the two by construction.
        #expect(RemoteRestoreService.remoteExtractTimeout < RemoteRestoreService.unzipTimeout)
        #expect(RemoteBackupService.zipTimeout == RemoteRestoreService.unzipTimeout)
    }

    /// The audit's actual finding was textual: three `proc.waitUntilExit()`
    /// calls with a `readToEnd` after them. Pin the shape so a future edit
    /// cannot quietly re-introduce it in these two files.
    @Test("no unbounded wait survives in the archive services")
    func noBareWaitInArchiveServices() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .appendingPathComponent("Sources/ScarfCore/Services")
        for name in ["RemoteRestoreService.swift", "RemoteBackupService.swift"] {
            let text = try String(contentsOf: services.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains(".waitUntilExit()"), "\(name) still holds an unbounded wait")
            #expect(!text.contains("readToEnd()"), "\(name) still reads a pipe after the wait")
        }
    }
}
#endif
