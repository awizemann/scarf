import Testing
import Foundation
@testable import ScarfCore

/// t-e2cd2861 (P8 W1) — `fileExists` was the un-plugged absent-vs-unreadable
/// hole, and these are the two writers it destroyed the most valuable files
/// through: `model_presets.json` (DI-C1) and the user's own `AGENTS.md`
/// (DI-C2, rewritten on EVERY project-scoped chat start, Mac and iOS).
///
/// Everything here runs against a real temp directory through
/// `LocalTransport`, because the bug is in what the writer BELIEVES about
/// the file — a fake transport that always answers honestly would prove
/// nothing. The unreadable cases use mode 0000, which only produces an
/// unreadable file for a non-root user, so they self-skip under root.
@Suite struct ProjectsW1GuardedWriterTests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    private static func withScratch(_ body: (URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-w1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: base.path
            )
            try? FileManager.default.removeItem(at: base)
        }
        try await body(base)
    }

    // MARK: - DI-C1: ModelPresetService

    /// Zero bytes is damage: Scarf never writes an empty preset store, so
    /// somebody else truncated it. The old `fileExists`-gated load decoded
    /// nothing, returned an EMPTY store, and the upsert published a
    /// one-preset file over it.
    @Test func upsertRefusesOverAZeroByteStoreAndLeavesItAlone() async throws {
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let path = ctx.paths.modelPresetsJSON
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: path, contents: Data())

            let service = ModelPresetService(context: ctx)
            await #expect(throws: ModelPresetServiceError.self) {
                try await service.upsert(ModelPreset(name: "New", modelID: "m", providerID: "p"))
            }
            #expect(
                (try? Data(contentsOf: URL(fileURLWithPath: path)))?.isEmpty == true,
                "the damaged store must be left exactly as it was"
            )
        }
    }

    /// The blip shape itself: the file is provably there and cannot be
    /// read. The write must refuse rather than publish a store rebuilt
    /// from a failed read.
    @Test func upsertRefusesWhenTheStoreIsUnreadableAndKeepsEveryPreset() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let path = ctx.paths.modelPresetsJSON
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            let original = Data("""
                {"presets":[{"createdAt":"2026-01-01T00:00:00Z","id":"\(UUID().uuidString)",\
                "modelID":"m","name":"Kept","providerID":"p","updatedAt":"2026-01-01T00:00:00Z"}],\
                "version":1}
                """.utf8)
            try original.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

            let service = ModelPresetService(context: ctx)
            await #expect(throws: ModelPresetServiceError.self) {
                try await service.upsert(ModelPreset(name: "New", modelID: "m", providerID: "p"))
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        }
    }

    /// The store the guard gives it: a one-deep `.bak` of the bytes each
    /// write replaces. `model_presets.json` had none.
    @Test func upsertKeepsAOneDeepBackupOfWhatItReplaces() async throws {
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let service = ModelPresetService(context: ctx)
            try await service.upsert(ModelPreset(name: "First", modelID: "m", providerID: "p"))
            let afterFirst = try Data(contentsOf: URL(fileURLWithPath: ctx.paths.modelPresetsJSON))
            try await service.upsert(ModelPreset(name: "Second", modelID: "m", providerID: "p"))

            let bak = ctx.paths.modelPresetsJSON + ".bak"
            #expect(FileManager.default.fileExists(atPath: bak))
            #expect(try Data(contentsOf: URL(fileURLWithPath: bak)) == afterFirst)
            #expect(try await service.list().map(\.name) == ["First", "Second"])
        }
    }

    /// A store that is simply not there is still the ordinary first-run
    /// case — the guard must not have frozen it.
    @Test func firstWriteOnAHostWithNoStoreStillLands() async throws {
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let service = ModelPresetService(context: ctx)
            try await service.upsert(ModelPreset(name: "Only", modelID: "m", providerID: "p"))
            #expect(try await service.list().count == 1)
        }
    }

    // MARK: - DI-C2: AGENTS.md

    private static let block = "\(ProjectContextBlock.beginMarker)\nhello\n\(ProjectContextBlock.endMarker)"

    @Test func writeBlockRefusesAnUnreadableAgentsMdInsteadOfReplacingIt() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let agents = project.appendingPathComponent("AGENTS.md")
            let original = Data("# The user's own instructions\n".utf8)
            try original.write(to: agents)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: agents.path
            )

            #expect(throws: ProjectContextBlock.WriteError.refusedUnreadable(path: agents.path)) {
                try ProjectContextBlock.writeBlock(
                    Self.block, forProjectAt: project.path, context: .local(home: base)
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: agents.path
            )
            #expect(try Data(contentsOf: agents) == original)
        }
    }

    /// The second half of the same bug: `String(data:encoding:.utf8) ?? ""`
    /// turned one stray byte into an empty document, and the splice then
    /// republished the file as the Scarf block alone.
    @Test func writeBlockRefusesNonUTF8AgentsMdRatherThanTruncatingIt() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let agents = project.appendingPathComponent("AGENTS.md")
            let original = Data([0x23, 0x20, 0xFF, 0xFE, 0x0A])
            try original.write(to: agents)

            #expect(
                throws: ProjectContextBlock.WriteError.refusedUndecodableText(path: agents.path)
            ) {
                try ProjectContextBlock.writeBlock(
                    Self.block, forProjectAt: project.path, context: .local(home: base)
                )
            }
            #expect(try Data(contentsOf: agents) == original)
        }
    }

    /// AGENTS.md never had a `.bak` anywhere in Scarf. Now it does.
    @Test func writeBlockKeepsAOneDeepBackupOfTheUsersAgentsMd() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let agents = project.appendingPathComponent("AGENTS.md")
            let original = Data("# Mine\n\nkeep me\n".utf8)
            try original.write(to: agents)

            try ProjectContextBlock.writeBlock(
                Self.block, forProjectAt: project.path, context: .local(home: base)
            )

            let rewritten = try String(contentsOf: agents, encoding: .utf8)
            #expect(rewritten.contains("keep me"))
            #expect(rewritten.contains(ProjectContextBlock.beginMarker))
            let bak = project.appendingPathComponent("AGENTS.md.bak")
            #expect(try Data(contentsOf: bak) == original)
        }
    }

    /// Zero bytes is damage for a JSON sidecar; an empty AGENTS.md is just
    /// an empty markdown file, has nothing to lose, and must stay writable.
    @Test func writeBlockStillWritesIntoAnEmptyAgentsMd() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let agents = project.appendingPathComponent("AGENTS.md")
            FileManager.default.createFile(atPath: agents.path, contents: Data())

            try ProjectContextBlock.writeBlock(
                Self.block, forProjectAt: project.path, context: .local(home: base)
            )
            #expect(try String(contentsOf: agents, encoding: .utf8)
                .contains(ProjectContextBlock.beginMarker))
        }
    }

    @Test func writeBlockCreatesAgentsMdWhenTheProjectHasNone() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("fresh", isDirectory: true)
            try ProjectContextBlock.writeBlock(
                Self.block, forProjectAt: project.path, context: .local(home: base)
            )
            let text = try String(
                contentsOf: project.appendingPathComponent("AGENTS.md"), encoding: .utf8
            )
            #expect(text.hasPrefix(ProjectContextBlock.beginMarker))
        }
    }

    /// Idempotence is load-bearing (the block is re-rendered on every chat
    /// start): an unchanged block must not churn the file or the `.bak`.
    @Test func writeBlockIsANoOpWhenNothingChanged() async throws {
        try await Self.withScratch { base in
            let project = base.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try ProjectContextBlock.writeBlock(
                Self.block, forProjectAt: project.path, context: .local(home: base)
            )
            let first = try Data(contentsOf: project.appendingPathComponent("AGENTS.md"))
            try ProjectContextBlock.writeBlock(
                Self.block, forProjectAt: project.path, context: .local(home: base)
            )
            #expect(try Data(contentsOf: project.appendingPathComponent("AGENTS.md")) == first)
            #expect(!FileManager.default.fileExists(
                atPath: project.appendingPathComponent("AGENTS.md.bak").path
            ))
        }
    }
}
