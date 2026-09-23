#if canImport(Citadel)

import Testing
import Foundation
import ScarfCore
@testable import ScarfIOS

/// Unit coverage for `ACPClient.buildACPCommand` — the remote shell
/// command that spawns `hermes acp` on iOS.
///
/// The project-cwd behavior is the iOS counterpart to Mac's
/// `SSHTransport.makeProcess(cwd:)`: a `cd <project>;` prefix is what makes
/// Hermes load the project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` (it
/// reads context files from the PROCESS cwd, not the ACP session cwd).
/// Before this was wired, iOS project chats spawned from the SSH login dir
/// and the agent never saw project context. See
/// `.memory/architecture/scarfgo-ios-does-not-load-project-context-process-cwd-gap.md`.
@Suite struct ACPCommandBuilderTests {

    /// The PATH prefix every spawned command carries (mirrors
    /// `HermesPathSet.hermesBinaryCandidates`).
    private static let pathPrefix =
        #"PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH""#

    // MARK: - Quick chat (no project)

    @Test func quickChatHasNoCdAndNoProfileHome() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root", projectCwd: nil
        )
        #expect(cmd == "\(Self.pathPrefix) exec hermes acp")
        #expect(!cmd.contains("cd "))
        #expect(!cmd.contains("HERMES_HOME="))
    }

    @Test func emptyProjectCwdIsTreatedAsNoProject() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root", projectCwd: ""
        )
        #expect(!cmd.contains("cd "))
    }

    // MARK: - Project chat

    @Test func projectChatCdsIntoProjectFirst() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "/usr/local/bin/hermes",
            home: "/home/alan",
            projectCwd: "/home/alan/projects/myapp"
        )
        #expect(cmd == "cd '/home/alan/projects/myapp'; \(Self.pathPrefix) exec /usr/local/bin/hermes acp")
    }

    @Test func projectPathWithSpacesIsQuoted() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root", projectCwd: "/srv/My Project"
        )
        #expect(cmd.hasPrefix("cd '/srv/My Project'; "))
    }

    @Test func tildeProjectPathExpandsHome() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root", projectCwd: "~/projects/app"
        )
        // Double-quoted so the remote shell expands $HOME but nothing else.
        #expect(cmd.hasPrefix(#"cd "$HOME/projects/app"; "#))
    }

    // MARK: - Profile scoping composes with the cd prefix

    @Test func profileHomeKeepsHermesHomeAssignment() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes",
            home: "/root/profiles/work",
            projectCwd: "/srv/app"
        )
        #expect(cmd.hasPrefix("cd '/srv/app'; "))
        #expect(cmd.contains("HERMES_HOME='/root/profiles/work' exec hermes acp"))
    }

    // MARK: - Injection: a hostile project path must stay inert

    @Test func commandSubstitutionInPathIsNeutralized() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root",
            projectCwd: "/tmp/$(touch pwned)"
        )
        // Single-quoted → `$(…)` cannot run.
        #expect(cmd.contains("cd '/tmp/$(touch pwned)'; "))
    }

    @Test func semicolonInPathCannotChainCommands() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root",
            projectCwd: "/tmp/x; rm -rf ~"
        )
        // The malicious `;` is captured INSIDE the single-quoted path; the
        // only live `; ` is the cd→PATH separator we added.
        #expect(cmd.hasPrefix("cd '/tmp/x; rm -rf ~'; PATH="))
    }

    @Test func embeddedSingleQuoteIsEscaped() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root",
            projectCwd: "/tmp/a'b"
        )
        // Standard '\'' close-escape-reopen trick keeps the quoting balanced.
        #expect(cmd.contains(#"cd '/tmp/a'\''b'; "#))
    }

    // MARK: - Environment hint (gh#142)

    @Test func noHintOmitsAssignment() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root",
            projectCwd: "/srv/app", environmentHint: nil
        )
        #expect(!cmd.contains("HERMES_ENVIRONMENT_HINT"))
    }

    @Test func hintInjectedAsShellAssignment() {
        let hint = "This chat was opened in Scarf for project \"myapp\" at /srv/app."
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root",
            projectCwd: "/srv/app", environmentHint: hint
        )
        #expect(cmd.contains("HERMES_ENVIRONMENT_HINT="))
        // The hint must be single-quoted so spaces/newlines/quotes are inert.
        #expect(cmd.contains("'\(hint)'"))
        // The cd prefix still comes first.
        #expect(cmd.hasPrefix("cd '/srv/app'; "))
    }

    @Test func emptyHintOmitsAssignment() {
        let cmd = ACPClient.buildACPCommand(
            hermesBinary: "hermes", home: "/root",
            projectCwd: "/srv/app", environmentHint: ""
        )
        #expect(!cmd.contains("HERMES_ENVIRONMENT_HINT"))
    }
}

#endif
