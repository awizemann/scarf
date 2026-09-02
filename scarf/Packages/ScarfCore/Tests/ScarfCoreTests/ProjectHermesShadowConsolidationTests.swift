import Testing
import Foundation
@testable import ScarfCore

/// Pins the shape of the "Copy fix command" one-liner the Dashboard hands
/// the user to paste into a remote shell.
///
/// This string runs, unreviewed, against the user's real Hermes home — so
/// its destructiveness is the thing under test, not its formatting.
@Suite struct ProjectHermesShadowConsolidationTests {

    private func shadow(hasAuthJSON: Bool) -> ProjectHermesShadowDetector.Shadow {
        ProjectHermesShadowDetector.Shadow(
            projectName: "Atlas",
            projectPath: "/home/deploy/atlas",
            shadowPath: "/home/deploy/atlas/.hermes",
            hasAuthJSON: hasAuthJSON,
            hasStateDB: true
        )
    }

    /// The copy MUST NOT overwrite `~/.hermes/auth.json`. A plain `cp` would
    /// replace the user's primary credential with a project-local one, from
    /// a button that only promised to "consolidate" — unrecoverable, and not
    /// what the UI says. The `[ -e dest ] ||` guard makes the step purely
    /// additive.
    @Test func authCopyNeverClobbersTheGlobalAuthJSON() throws {
        let cmd = try #require(
            ProjectHermesShadowDetector.consolidationCommand(for: shadow(hasAuthJSON: true), hermesHome: "/home/deploy/.hermes")
        )
        #expect(cmd.contains("[ -e '/home/deploy/.hermes/auth.json' ] ||"))
        // The copy is only ever reached through that guard.
        #expect(!cmd.contains("&& cp '"))
        #expect(cmd.hasPrefix("mkdir -p "))
        #expect(cmd.contains("chmod 600 "))
    }

    /// The regression this replaced: BSD `cp -n` exits 1 when it SKIPS an
    /// existing file, which aborted the `&&` chain — so on exactly the
    /// has-existing-global-auth case the `mv` never ran and the shadow was
    /// left binding. The guarded form must not use `cp -n` at all, and the
    /// skip path must be exit-0 (`[ -e … ] || cp …` is, by construction).
    @Test func skippedCopyDoesNotAbortTheChain() throws {
        let cmd = try #require(
            ProjectHermesShadowDetector.consolidationCommand(for: shadow(hasAuthJSON: true), hermesHome: "/home/deploy/.hermes")
        )
        #expect(!cmd.contains("cp -n"))
        // The guard is braced so the `||` binds to the copy alone and the
        // chain continues into `chmod` and `mv`.
        #expect(cmd.contains("; }"))
        let mvIndex = try #require(cmd.range(of: "&& mv "))
        let chmodIndex = try #require(cmd.range(of: "chmod 600 "))
        #expect(chmodIndex.lowerBound < mvIndex.lowerBound)
    }

    /// Executed proof, not just string-shape: run the emitted command in a
    /// real shell against a pre-existing destination and assert the global
    /// auth.json is untouched AND the shadow still got renamed.
    @Test func emittedCommandRenamesShadowEvenWhenGlobalAuthExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-consolidate-\(UUID().uuidString)")
        let shadowPath = root.appendingPathComponent("project/.hermes")
        let home = root.appendingPathComponent("home/.hermes")
        try FileManager.default.createDirectory(at: shadowPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "PROJECT".write(to: shadowPath.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "GLOBAL".write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let s = ProjectHermesShadowDetector.Shadow(
            projectName: "Atlas",
            projectPath: root.appendingPathComponent("project").path,
            shadowPath: shadowPath.path,
            hasAuthJSON: true,
            hasStateDB: true
        )
        let cmd = try #require(ProjectHermesShadowDetector.consolidationCommand(for: s, hermesHome: home.path))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        try p.run()
        p.waitUntilExit()

        #expect(p.terminationStatus == 0)
        // Global credential preserved…
        #expect(try String(contentsOf: home.appendingPathComponent("auth.json"), encoding: .utf8) == "GLOBAL")
        // …and the shadow actually moved out of the way.
        #expect(!FileManager.default.fileExists(atPath: shadowPath.path))
    }

    /// The rename is still unconditional — it's what actually stops the
    /// shadow binding as `$HERMES_HOME` — and it renames rather than deletes,
    /// so the project's own auth.json remains recoverable even when `-n`
    /// skipped the copy.
    @Test func shadowIsRenamedAsideNotDeleted() throws {
        let cmd = try #require(
            ProjectHermesShadowDetector.consolidationCommand(for: shadow(hasAuthJSON: true), hermesHome: "/home/deploy/.hermes")
        )
        #expect(cmd.contains("mv "))
        #expect(cmd.contains(".scarf-bak.$(date -u +%Y%m%d-%H%M%S)"))
        #expect(!cmd.contains("rm "))
    }

    /// Without auth.json the command touches the global home not at all.
    @Test func noAuthShadowOnlyRenames() throws {
        let cmd = try #require(
            ProjectHermesShadowDetector.consolidationCommand(for: shadow(hasAuthJSON: false), hermesHome: "/home/deploy/.hermes")
        )
        #expect(!cmd.contains("cp"))
        #expect(!cmd.contains("/home/deploy/.hermes/auth.json"))
        #expect(cmd.hasPrefix("mv "))
    }
}
