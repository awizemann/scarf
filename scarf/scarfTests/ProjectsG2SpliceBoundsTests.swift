import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P8 SEC-L5 and t-05a7c23d: the block-splice writers that operate on the
/// user's own long-lived text files (`~/.hermes/.env`, MEMORY.md), and the
/// two ways those splices used to destroy them — an unbounded region, and
/// bytes that aren't UTF-8 collapsing to an empty document.
@Suite("Projects G2 splice bounds")
struct ProjectsG2SpliceBoundsTests {

    private static func withTempDir(_ body: (String) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-g2-splice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body(dir.path)
    }

    // MARK: - SEC-L5: an unbounded memory block strips NOTHING

    /// THE ATTACK. MEMORY.md is agent-writable. Append a bare begin marker
    /// for any installed template and the next uninstall — a routine
    /// one-click action — used to delete from that marker to EOF, taking
    /// the user's own notes with it and leaving no backup.
    @Test func beginMarkerWithNoEndMarkerStripsNothing() throws {
        try Self.withTempDir { dir in
            let memoryPath = dir + "/MEMORY.md"
            let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: "tmpl")
            let original = """
            # My notes

            \(begin)

            Everything below here is mine and there is no end marker.
            Years of it.
            """
            try original.write(toFile: memoryPath, atomically: true, encoding: .utf8)

            let uninstaller = ProjectTemplateUninstaller(context: .local)
            try uninstaller.stripMemoryBlock(
                blockId: "tmpl", memoryPath: memoryPath, transport: LocalTransport()
            )
            #expect(try String(contentsOfFile: memoryPath, encoding: .utf8) == original)
        }
    }

    /// The well-formed case still strips exactly its own region.
    @Test func wellFormedMemoryBlockIsStrippedAndTheRestSurvives() throws {
        try Self.withTempDir { dir in
            let memoryPath = dir + "/MEMORY.md"
            let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: "tmpl")
            let end = ProjectTemplateService.memoryBlockEndMarker(templateId: "tmpl")
            try """
            # My notes

            \(begin)
            template stuff
            \(end)

            Mine again.
            """.write(toFile: memoryPath, atomically: true, encoding: .utf8)

            let uninstaller = ProjectTemplateUninstaller(context: .local)
            try uninstaller.stripMemoryBlock(
                blockId: "tmpl", memoryPath: memoryPath, transport: LocalTransport()
            )
            let after = try String(contentsOfFile: memoryPath, encoding: .utf8)
            #expect(after.contains("# My notes"))
            #expect(after.contains("Mine again."))
            #expect(after.contains("template stuff") == false)
            #expect(after.contains(begin) == false)
        }
    }

    // MARK: - t-05a7c23d: non-UTF-8 MEMORY.md refuses instead of collapsing

    @Test func nonUTF8MemoryFileIsRefusedNotTreatedAsEmpty() throws {
        try Self.withTempDir { dir in
            let memoryPath = dir + "/MEMORY.md"
            var bytes = Data("# real notes\n".utf8)
            bytes.append(contentsOf: [0xFF, 0xFE, 0x80])
            try bytes.write(to: URL(fileURLWithPath: memoryPath))

            let inspection = ProjectTemplateInstaller.inspectMemory(
                at: memoryPath, transport: LocalTransport()
            )
            #expect(throws: ProjectTemplateError.self) {
                _ = try ProjectTemplateInstaller.memoryText(of: inspection, at: memoryPath)
            }
            // Untouched.
            #expect(try Data(contentsOf: URL(fileURLWithPath: memoryPath)) == bytes)
        }
    }

    @Test func absentMemoryFileReadsAsEmptyAndAnEmptyOneIsWritable() throws {
        try Self.withTempDir { dir in
            let missing = dir + "/nope/MEMORY.md"
            let absent = ProjectTemplateInstaller.inspectMemory(
                at: missing, transport: LocalTransport()
            )
            #expect(try ProjectTemplateInstaller.memoryText(of: absent, at: missing) == "")

            let empty = dir + "/MEMORY.md"
            try Data().write(to: URL(fileURLWithPath: empty))
            let inspection = ProjectTemplateInstaller.inspectMemory(
                at: empty, transport: LocalTransport()
            )
            #expect(try ProjectTemplateInstaller.memoryText(of: inspection, at: empty) == "")
        }
    }

    @Test func decodableMemoryFileRoundTrips() throws {
        try Self.withTempDir { dir in
            let memoryPath = dir + "/MEMORY.md"
            try "# notes\n".write(toFile: memoryPath, atomically: true, encoding: .utf8)
            let inspection = ProjectTemplateInstaller.inspectMemory(
                at: memoryPath, transport: LocalTransport()
            )
            #expect(try ProjectTemplateInstaller.memoryText(of: inspection, at: memoryPath)
                == "# notes\n")
        }
    }

    // MARK: - t-05a7c23d: non-UTF-8 `.env` refuses instead of collapsing

    /// THE FAILURE. `~/.hermes/.env` holds Hermes's own credentials outside
    /// any Scarf block. One non-UTF-8 byte in it used to become `""`, and
    /// the splice then published a Scarf-block-only `.env` — deleting
    /// `ANTHROPIC_API_KEY` and everything beside it.
    @Test func nonUTF8EnvFileRefusesTheMirrorAndIsLeftIntact() throws {
        try Self.withTempDir { dir in
            let envPath = dir + "/.env"
            var bytes = Data("ANTHROPIC_API_KEY=sk-real\n".utf8)
            bytes.append(contentsOf: [0xC3, 0x28, 0xFF])
            try bytes.write(to: URL(fileURLWithPath: envPath))

            let mirror = KeychainEnvMirror(context: .local)
            #expect(throws: KeychainEnvMirror.EnvMirrorError.refusedUndecodableText(path: envPath)) {
                try mirror.mirror(slug: "x", entries: [("KEY", "v")], envPath: envPath)
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: envPath)) == bytes)
        }
    }

    /// The `.bak` the guarded writer now keeps must be `0600` too — it
    /// holds exactly the secrets the original does (SEC-L2).
    @Test func envBackupIsWrittenAndIsPrivate() throws {
        try Self.withTempDir { dir in
            let envPath = dir + "/.env"
            try "ANTHROPIC_API_KEY=sk-real\n".write(
                toFile: envPath, atomically: true, encoding: .utf8
            )
            let mirror = KeychainEnvMirror(context: .local)
            try mirror.mirror(slug: "x", entries: [("KEY", "v")], envPath: envPath)

            let bak = envPath + ".bak"
            #expect(FileManager.default.fileExists(atPath: bak))
            #expect(try String(contentsOfFile: bak, encoding: .utf8) == "ANTHROPIC_API_KEY=sk-real\n")
            let perms = try FileManager.default.attributesOfItem(atPath: bak)[.posixPermissions]
                as? NSNumber
            #expect(perms?.intValue == 0o600, "got \(String(describing: perms)) on \(bak)")
            // And the live file still carries the user's own line.
            #expect(try String(contentsOfFile: envPath, encoding: .utf8)
                .hasPrefix("ANTHROPIC_API_KEY=sk-real"))
        }
    }
}
