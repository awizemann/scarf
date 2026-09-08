import Testing
import Foundation
@testable import ScarfCore

/// GW-F6 — the last of the E5 audit's guard-machinery lows.
///
/// Absence proven POSITIVELY by an ENOENT rather than by two correlated
/// failures (DI L1), the real size caps on the two files that still passed
/// `Int.max` (the F5 handoff), the `.bak`-churn policy the audit asked to be
/// pinned (DI M10), and the proof token that must not be constructible from
/// outside ScarfCore (DI L5 — enforced by this file compiling only because
/// it is `@testable`).
@Suite struct GuardMachineryF6Tests {

    private static func scratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-f6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var runningAsRoot: Bool { getuid() == 0 }

    // MARK: - DI L1: ENOENT is a positive answer

    @Test("a missing file reports ENOENT, and inspect takes it as proof")
    func missingFileIsProvenAbsentFromTheReadError() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("nope.json").path

        // The normalization LocalTransport now does, so `isNoSuchFile` means
        // the same thing on both transports.
        do {
            _ = try LocalTransport().readFile(path)
            Issue.record("reading a missing file should throw")
        } catch let error as TransportError {
            #expect(error.isNoSuchFile)
        }

        let inspection = GuardedJSONStore(transport: LocalTransport(), label: "nope.json")
            .inspect(path, maxBytes: 1024)
        #expect(inspection.state == .absent)
    }

    @Test("a read failure that is NOT ENOENT still falls through to the probe")
    func unreadableFileIsNotMistakenForAbsent() throws {
        try #require(!Self.runningAsRoot)
        let base = try Self.scratch()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: base.appendingPathComponent("locked.json").path
            )
            try? FileManager.default.removeItem(at: base)
        }
        let url = base.appendingPathComponent("locked.json")
        try Data(#"{"a":1}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        do {
            _ = try LocalTransport().readFile(url.path)
            Issue.record("reading a 0000 file should throw")
        } catch let error as TransportError {
            #expect(!error.isNoSuchFile, "EACCES is not ENOENT — it must not prove absence")
        }

        let inspection = GuardedJSONStore(transport: LocalTransport(), label: "locked.json")
            .inspect(url.path, maxBytes: 1024)
        #expect(inspection.state == .unreadable(path: url.path))
    }

    // MARK: - F5 handoff: the last two Int.max caps

    @Test("AGENTS.md and MEMORY.md carry the 32 MB house cap, not Int.max")
    func proseFilesAreCappedGenerouslyRatherThanNotAtAll() {
        #expect(ProjectContextBlock.maxAgentsBytes == GuardedTextFile.defaultMaxBytes)
        #expect(GuardedTextFile.defaultMaxBytes == 32 * 1024 * 1024)
        #expect(ProjectContextBlock.maxAgentsBytes != Int.max, "Int.max also skips the stat probe")
    }

    @Test("an over-cap AGENTS.md is refused unread, with no quarantine copy")
    func overCapProseFileIsRefusedWithoutBeingHeld() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("AGENTS.md").path
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: path))

        // A deliberately tiny cap stands in for a multi-gigabyte file.
        let inspection = GuardedJSONStore(transport: LocalTransport(), label: "AGENTS.md")
            .inspect(path, maxBytes: 128)
        #expect(inspection.state == .unreadable(path: path))
        #expect(inspection.bytes == nil, "the bytes must never be held")
        #expect(inspection.quarantineCopy == nil, "and nothing is copied aside")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: base.path)
        #expect(siblings == ["AGENTS.md"])
    }

    // MARK: - DI M10: what the one-deep .bak is, and is not

    /// The audit's M10 is that a double save consumes the last-good backup:
    /// the second write's `.bak` is the FIRST write's output, not the
    /// pre-edit file. That is the documented contract of a one-deep backup,
    /// and it is pinned here so nobody "fixes" it into a versioned history
    /// (or, worse, into a backup that is never refreshed and silently ages
    /// out of relevance).
    @Test("the .bak is one deep: it holds the bytes the CURRENT write replaced")
    func backupIsOneDeepByDesign() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("notes.md").path
        let file = GuardedTextFile(transport: LocalTransport(), label: "notes.md")

        try Data("original\n".utf8).write(to: URL(fileURLWithPath: path))
        try file.mutate(path) { _ in "first\n" }
        #expect(try String(contentsOfFile: path + ".bak", encoding: .utf8) == "original\n")

        try file.mutate(path) { _ in "second\n" }
        #expect(
            try String(contentsOfFile: path + ".bak", encoding: .utf8) == "first\n",
            "one deep means the previous save, not the original — a second save in one sitting does consume it"
        )
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "second\n")
    }

    // MARK: - DI L5: the proof token is not forgeable outside the module

    /// This compiles only because of `@testable import ScarfCore`. Outside
    /// the module the memberwise initializer is now invisible, so the only
    /// way to obtain a `Loaded` — and therefore the only way to reach
    /// `write` — is a successful `load`.
    @Test("a Loaded can still be built in-module, which is what write needs")
    func proofTokenIsInternalNotPublic() throws {
        let token = GuardedTextFile.Loaded(
            text: "x",
            exists: true,
            inspection: GuardedJSONStore.Inspection(state: .present, bytes: Data("x".utf8))
        )
        #expect(token.exists)
    }
}
