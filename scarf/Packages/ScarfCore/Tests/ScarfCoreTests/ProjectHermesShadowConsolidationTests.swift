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
    /// what the UI says. `-n` makes the step purely additive.
    @Test func authCopyNeverClobbersTheGlobalAuthJSON() throws {
        let cmd = try #require(
            ProjectHermesShadowDetector.consolidationCommand(for: shadow(hasAuthJSON: true), hermesHome: "/home/deploy/.hermes")
        )
        #expect(cmd.contains("cp -n "))
        // No bare `cp ` anywhere — that would be the clobbering form.
        #expect(!cmd.contains("&& cp '"))
        #expect(cmd.hasPrefix("mkdir -p "))
        #expect(cmd.contains("chmod 600 "))
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
