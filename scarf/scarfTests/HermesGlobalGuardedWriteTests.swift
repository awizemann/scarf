import Testing
import Foundation
import ScarfCore
@testable import scarf

/// GW-E2a, Mac-target half — `~/.hermes/.env` (`HermesEnvService`) and
/// `MEMORY.md` / `USER.md` (`HermesFileService`).
///
/// Real temp directories through `LocalTransport`, W1 style: the bug is in
/// what the writer BELIEVES about the file, so an always-honest fake proves
/// nothing. Mode-0000 cases self-skip under root.
@Suite struct HermesGlobalGuardedWriteTests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    private static func makeScratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-e2a-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func cleanUp(_ base: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: base.path
        )
        try? FileManager.default.removeItem(at: base)
    }

    private static func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    // MARK: - .env

    private static let realEnv = """
    # Hermes Agent Environment Configuration
    ANTHROPIC_API_KEY=sk-ant-not-a-real-key
    TELEGRAM_BOT_TOKEN=12345:abc

    """

    /// The bug this closes: `setMany` fell back to a ONE-LINE header file on
    /// a failed read and published it — every key the user owns, gone.
    @Test func setManyRefusesWhenTheEnvIsUnreadableAndKeepsEveryKey() throws {
        try #require(!Self.runningAsRoot)
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let path = base.appendingPathComponent(".env").path
        try Data(Self.realEnv.utf8).write(to: URL(fileURLWithPath: path))
        try Self.chmod(path, 0o000)

        let service = HermesEnvService(path: path)
        #expect(service.setMany(["DISCORD_BOT_TOKEN": "new"]) == false)

        try Self.chmod(path, 0o600)
        #expect(Self.text(path) == Self.realEnv, "the .env must be byte-identical")
    }

    @Test func setManyRefusesOnNonUTF8Bytes() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let path = base.appendingPathComponent(".env").path
        let bytes = Data([0xFF, 0xFE, 0x9C, 0x00])
        try bytes.write(to: URL(fileURLWithPath: path))

        let service = HermesEnvService(path: path)
        #expect(service.set("K", value: "v") == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
    }

    @Test func unsetRefusesWhenTheEnvIsUnreadable() throws {
        try #require(!Self.runningAsRoot)
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let path = base.appendingPathComponent(".env").path
        try Data(Self.realEnv.utf8).write(to: URL(fileURLWithPath: path))
        try Self.chmod(path, 0o000)

        let service = HermesEnvService(path: path)
        #expect(service.unset("ANTHROPIC_API_KEY") == false)

        try Self.chmod(path, 0o600)
        #expect(Self.text(path) == Self.realEnv)
    }

    /// Healthy path, unchanged: an absent `.env` is created with the header,
    /// and an existing one keeps every key we didn't touch.
    @Test func setManyStillCreatesAndStillPreservesUntouchedKeys() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let path = base.appendingPathComponent(".env").path

        let service = HermesEnvService(path: path)
        #expect(service.set("FIRST", value: "1"))
        let created = try #require(Self.text(path))
        #expect(created.hasPrefix("# Hermes Agent Environment Configuration"))
        #expect(created.contains("FIRST=1"))

        #expect(service.set("SECOND", value: "2"))
        let both = try #require(Self.text(path))
        #expect(both.contains("FIRST=1"))
        #expect(both.contains("SECOND=2"))
        // One-deep .bak of the bytes the second write replaced.
        #expect(Self.text(path + ".bak") == created)
    }

    /// An EMPTY `.env` is a legal state a person can make — zero bytes is
    /// damage for a JSON sidecar, not here. It must still be writable, and it
    /// must NOT take the "create fresh" header branch.
    @Test func setManyTreatsAnEmptyEnvAsLegalAndNotAsAbsent() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let path = base.appendingPathComponent(".env").path
        FileManager.default.createFile(atPath: path, contents: Data())

        let service = HermesEnvService(path: path)
        #expect(service.set("K", value: "v"))
        let written = try #require(Self.text(path))
        #expect(written.contains("K=v"))
        #expect(!written.contains("# Hermes Agent Environment Configuration"),
                "an existing empty .env is not a fresh file — no header is invented")
    }

    // MARK: - MEMORY.md / USER.md

    @Test func saveMemoryRefusesOverAnUnreadableFileAndKeepsTheProse() throws {
        try #require(!Self.runningAsRoot)
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        let service = HermesFileService(context: ctx)
        let path = ctx.paths.memoriesDir + "/MEMORY.md"
        try FileManager.default.createDirectory(
            atPath: ctx.paths.memoriesDir, withIntermediateDirectories: true
        )
        try Data("years of the user's notes\n".utf8).write(to: URL(fileURLWithPath: path))
        try Self.chmod(path, 0o000)

        // GW-F2: the READ refuses too. It used to hand the editor an empty
        // buffer — the exact input the old unguarded `saveMemory` would have
        // published, and the input the Mac conflict check called "the file
        // changed to empty".
        #expect(throws: (any Error).self) { try service.loadMemory() }
        #expect(throws: (any Error).self) { try service.saveMemory("") }

        try Self.chmod(path, 0o644)
        #expect(Self.text(path) == "years of the user's notes\n")
    }

    @Test func saveMemoryStillWritesFreshAndOverEmptyAndKeepsABak() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        let service = HermesFileService(context: ctx)
        let path = ctx.paths.memoriesDir + "/MEMORY.md"
        try FileManager.default.createDirectory(
            atPath: ctx.paths.memoriesDir, withIntermediateDirectories: true
        )

        try service.saveMemory("first\n")
        #expect(Self.text(path) == "first\n")
        try service.saveMemory("second\n")
        #expect(Self.text(path) == "second\n")
        #expect(Self.text(path + ".bak") == "first\n")

        // Emptying MEMORY.md is a legal thing to do, then writing over the
        // empty file is legal too.
        try service.saveMemory("")
        #expect(Self.text(path) == "")
        try service.saveMemory("third\n")
        #expect(Self.text(path) == "third\n")
    }

    @Test func saveUserProfileRefusesOverAnUnreadableFile() throws {
        try #require(!Self.runningAsRoot)
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        let service = HermesFileService(context: ctx)
        let path = ctx.paths.memoriesDir + "/USER.md"
        try FileManager.default.createDirectory(
            atPath: ctx.paths.memoriesDir, withIntermediateDirectories: true
        )
        try Data("who the user is\n".utf8).write(to: URL(fileURLWithPath: path))
        try Self.chmod(path, 0o000)

        #expect(throws: (any Error).self) { try service.saveUserProfile("") }
        try Self.chmod(path, 0o644)
        #expect(Self.text(path) == "who the user is\n")
    }
}
