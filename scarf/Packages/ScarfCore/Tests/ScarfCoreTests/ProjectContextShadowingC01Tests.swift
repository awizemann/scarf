import Testing
import Foundation
@testable import ScarfCore

/// S11-F1 (pre-release audit): Hermes loads ONE project-context type from
/// the cwd, first non-empty wins (`.hermes.md` → `AGENTS.md` → `CLAUDE.md` →
/// `.cursorrules`; `agent/prompt_builder.py:1746-1747` @ v2026.9.24). Scarf
/// used to create a block-only AGENTS.md next to a project's CLAUDE.md, and
/// Hermes then dropped the CLAUDE.md. The block now goes into the file
/// Hermes loads, and a block-only AGENTS.md from earlier builds is folded
/// back into it.
///
/// Real temp directories through `LocalTransport`; the last test runs
/// Hermes's own `build_context_files_prompt` from the reference checkout.
@Suite struct ProjectContextShadowingC01Tests {

    private static let block = "\(ProjectContextBlock.beginMarker)\nSCARF-BLOCK\n\(ProjectContextBlock.endMarker)"

    private static func withProject(_ body: (URL, ServerContext) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-c01-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(project, .local(home: base.appendingPathComponent("hermes")))
    }

    private static func write(_ text: String, _ name: String, in project: URL) throws {
        let url = project.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func read(_ name: String, in project: URL) -> String? {
        try? String(contentsOf: project.appendingPathComponent(name), encoding: .utf8)
    }

    private static func exists(_ name: String, in project: URL) -> Bool {
        FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path)
    }

    @Test func claudeMdProjectGetsTheBlockInClaudeMdAndNoAgentsMd() throws {
        try Self.withProject { project, ctx in
            try Self.write("# Build with make\n", "CLAUDE.md", in: project)
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            #expect(!Self.exists("AGENTS.md", in: project))
            let claude = try #require(Self.read("CLAUDE.md", in: project))
            #expect(claude.contains("SCARF-BLOCK"))
            #expect(claude.contains("# Build with make"))
            // Idempotent on the next chat start.
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            #expect(Self.read("CLAUDE.md", in: project) == claude)
        }
    }

    @Test func cursorRulesProjectsGetTheBlockInCursorrules() throws {
        try Self.withProject { project, ctx in
            try Self.write("tabs only\n", ".cursorrules", in: project)
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            #expect(!Self.exists("AGENTS.md", in: project))
            #expect(Self.read(".cursorrules", in: project)?.contains("SCARF-BLOCK") == true)
        }
        // Only `.cursor/rules/*.mdc`: Hermes concatenates `.cursorrules` with
        // them, so a new `.cursorrules` carries the block without shadowing.
        try Self.withProject { project, ctx in
            try Self.write("rule\n", ".cursor/rules/style.mdc", in: project)
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            #expect(!Self.exists("AGENTS.md", in: project))
            #expect(Self.read(".cursorrules", in: project)?.contains("SCARF-BLOCK") == true)
        }
    }

    @Test func existingUserAgentsMdStillWins() throws {
        try Self.withProject { project, ctx in
            try Self.write("# agents\n", "AGENTS.md", in: project)
            try Self.write("# claude\n", "CLAUDE.md", in: project)
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            #expect(Self.read("AGENTS.md", in: project)?.contains("SCARF-BLOCK") == true)
            #expect(Self.read("CLAUDE.md", in: project) == "# claude\n")
        }
    }

    @Test func hermesMdKeepsItsFrontmatterFirst() throws {
        try Self.withProject { project, ctx in
            try Self.write("---\nmodel: x\n---\n# rules\n", ".hermes.md", in: project)
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            let text = try #require(Self.read(".hermes.md", in: project))
            #expect(text.hasPrefix("---\nmodel: x\n---\n\n\(ProjectContextBlock.beginMarker)"))
            #expect(text.contains("# rules"))
            #expect(!Self.exists("AGENTS.md", in: project))
        }
    }

    @Test func blockOnlyAgentsMdIsFoldedIntoClaudeMd() throws {
        try Self.withProject { project, ctx in
            try Self.write("# claude rules\n", "CLAUDE.md", in: project)
            try Self.write("\(ProjectContextBlock.beginMarker)\nOLD\n\(ProjectContextBlock.endMarker)\n",
                           "AGENTS.md", in: project)
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            #expect(!Self.exists("AGENTS.md", in: project))
            let claude = try #require(Self.read("CLAUDE.md", in: project))
            #expect(claude.contains("SCARF-BLOCK") && claude.contains("# claude rules"))
            #expect(!claude.contains("OLD"))
        }
    }

    @Test func agentsMdWithUserTextIsNeverDeleted() throws {
        try Self.withProject { project, ctx in
            try Self.write("# claude\n", "CLAUDE.md", in: project)
            try Self.write("\(Self.block)\n\n# mine\n", "AGENTS.md", in: project)
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            #expect(Self.read("AGENTS.md", in: project)?.contains("# mine") == true)
            #expect(Self.read("CLAUDE.md", in: project) == "# claude\n")
        }
    }

    @Test func removalStripsTheBlockFromClaudeMd() throws {
        try Self.withProject { project, ctx in
            try Self.write("# claude\n", "CLAUDE.md", in: project)
            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            #expect(try ProjectContextBlock.removeBlock(forProjectAt: project.path, context: ctx))
            #expect(Self.read("CLAUDE.md", in: project) == "# claude\n")
        }
    }

    @Test func unreadableClaudeMdRefusesRatherThanShadowingIt() throws {
        try #require(getuid() != 0)
        try Self.withProject { project, ctx in
            try Self.write("# claude\n", "CLAUDE.md", in: project)
            let path = project.appendingPathComponent("CLAUDE.md").path
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
            #expect(throws: ProjectContextBlock.WriteError.self) {
                try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            }
            #expect(!Self.exists("AGENTS.md", in: project))
        }
    }

    // MARK: - What Hermes itself loads

    static let hermesRef = NSHomeDirectory() + "/.hermes/hermes-agent-v0215"
    static let hermesRefAvailable = FileManager.default.isExecutableFile(atPath: hermesRef + "/.venv/bin/python")

    private static func hermesContextPrompt(cwd: URL, home: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hermesRef + "/.venv/bin/python")
        p.arguments = ["-c", "import sys; from agent.prompt_builder import build_context_files_prompt as b; print(b(cwd=sys.argv[1], skip_soul=True))", cwd.path]
        p.currentDirectoryURL = URL(fileURLWithPath: hermesRef)
        var env = ProcessInfo.processInfo.environment
        env["HERMES_HOME"] = home.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @Test(.enabled(if: hermesRefAvailable, "needs ~/.hermes/hermes-agent-v0215"))
    func hermesLoadsBothTheUsersClaudeMdAndScarfsBlock() throws {
        try Self.withProject { project, ctx in
            try Self.write("USE-MAKE-FOR-BUILDS\n", "CLAUDE.md", in: project)
            // Earlier-build state: block-only AGENTS.md shadowing CLAUDE.md.
            try Self.write(Self.block + "\n", "AGENTS.md", in: project)
            let home = project.deletingLastPathComponent().appendingPathComponent("hermes")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let before = try Self.hermesContextPrompt(cwd: project, home: home)
            #expect(before.contains("SCARF-BLOCK") && !before.contains("USE-MAKE-FOR-BUILDS"),
                    "precondition: Hermes shadows CLAUDE.md with the block-only AGENTS.md")

            try ProjectContextBlock.writeBlock(Self.block, forProjectAt: project.path, context: ctx)
            let after = try Self.hermesContextPrompt(cwd: project, home: home)
            #expect(after.contains("USE-MAKE-FOR-BUILDS"))
            #expect(after.contains("SCARF-BLOCK"))
        }
    }
}
