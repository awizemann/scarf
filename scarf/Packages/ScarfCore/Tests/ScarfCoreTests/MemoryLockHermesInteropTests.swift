import Testing
import Foundation
@testable import ScarfCore

/// S14-F5: a local MEMORY.md / USER.md save must interoperate with Hermes's
/// own memory lock (`tools/memory_tool_store.py:168-205` @ v2026.9.24):
/// Hermes `flock`s a persistent `<name>.lock` beside the file and never
/// deletes it. Scarf used the same path as a create-exclusive lock, so it
/// waited on Hermes's file, broke it as "stale", and refused saves as
/// "Another Scarf process".
@Suite(.serialized)
struct MemoryLockHermesInteropTests {

    static func scratchHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r05-memlock-\(UUID().uuidString)/.hermes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("memories"), withIntermediateDirectories: true)
        return home
    }

    /// A separate process holding `flock(LOCK_EX)` on `path`, the way a
    /// Hermes memory write does. Returns once the lock is held.
    static func holdFlock(_ path: String) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = ["-e", """
            use Fcntl qw(:flock O_RDWR O_CREAT); $| = 1;
            sysopen(my $fh, $ARGV[0], O_RDWR|O_CREAT, 0600) or die "open: $!";
            flock($fh, LOCK_EX) or die "flock: $!";
            print "locked\\n"; sleep 60;
            """, path]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        var seen = Data()
        while !String(decoding: seen, as: UTF8.self).contains("locked") {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            seen.append(chunk)
        }
        return proc
    }

    @Test("a local memory save leaves Hermes's lock file alone and doesn't stall on it")
    func saveKeepsHermesLockFile() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let ctx = ServerContext.local(home: home)
        let memory = ctx.paths.memoryMD
        let hermesLock = memory + ".lock"
        try Data("old entry".utf8).write(to: URL(fileURLWithPath: memory))
        // Hermes's lock as it is found in the wild: 0 bytes, months old.
        FileManager.default.createFile(atPath: hermesLock, contents: Data())
        let old = Date(timeIntervalSinceNow: -90 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: hermesLock)
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: hermesLock)[.systemFileNumber] as? Int

        let started = Date()
        let file = GuardedTextFile(context: ctx, label: "MEMORY.md")
        let wrote = try file.mutate(memory) { _ in "new entry" }
        #expect(wrote)
        #expect(Date().timeIntervalSince(started) < 1.5, "must not wait out the 2 s lock budget")
        #expect(try String(contentsOfFile: memory, encoding: .utf8) == "new entry")

        // Hermes's lock file is still there, same inode, and free again.
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: hermesLock)[.systemFileNumber] as? Int
        #expect(inodeAfter == inodeBefore)
        let fd = open(hermesLock, O_RDWR)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "Scarf must release Hermes's flock after the save")
        // Scarf's own lock is a different, hidden file, and is gone again.
        let scarfLock = try #require(RegistryWriteLock.lockURL(for: ctx, path: memory))
        #expect(scarfLock.lastPathComponent == ".MEMORY.md.scarf-lock")
        #expect(!FileManager.default.fileExists(atPath: scarfLock.path))
    }

    @Test("a save waits for, then refuses on, a Hermes writer holding the flock")
    func saveRespectsHermesFlock() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let ctx = ServerContext.local(home: home)
        let user = ctx.paths.userMD
        try Data("hermes wrote this".utf8).write(to: URL(fileURLWithPath: user))

        let holder = try Self.holdFlock(user + ".lock")
        defer { holder.terminate(); holder.waitUntilExit() }

        let file = GuardedTextFile(context: ctx, label: "USER.md")
        var thrown: Error?
        do {
            try file.withLock(user, acquireTimeout: 0.3) {
                _ = try file.mutate(user) { _ in "scarf overwrite" }
            }
        } catch {
            thrown = error
        }
        #expect(thrown as? ProjectRegistryError == .hermesBusy(path: user, label: "USER.md"))
        #expect(thrown?.localizedDescription.contains("Hermes is updating USER.md") == true)
        #expect(try String(contentsOfFile: user, encoding: .utf8) == "hermes wrote this")
        #expect(FileManager.default.fileExists(atPath: user + ".lock"))

        // Once Hermes lets go, the same save goes through.
        holder.terminate()
        holder.waitUntilExit()
        #expect(try file.mutate(user) { _ in "scarf overwrite" })
        #expect(try String(contentsOfFile: user, encoding: .utf8) == "scarf overwrite")
    }

    @Test("only local memory files take Hermes's flock; other files keep <name>.lock")
    func lockPlacement() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let ctx = ServerContext.local(home: home)
        #expect(RegistryWriteLock.hermesFlockURL(for: ctx, path: ctx.paths.memoryMD)?.path == ctx.paths.memoryMD + ".lock")
        #expect(RegistryWriteLock.hermesFlockURL(for: ctx, path: ctx.paths.configYAML) == nil)
        #expect(RegistryWriteLock.lockURL(for: ctx, path: ctx.paths.configYAML)?.path == ctx.paths.configYAML + ".lock")

        let remote = ServerContext(id: UUID(), displayName: "r", kind: .ssh(SSHConfig(host: "h")))
        #expect(RegistryWriteLock.hermesFlockURL(for: remote, path: remote.paths.memoryMD) == nil)
    }
}
