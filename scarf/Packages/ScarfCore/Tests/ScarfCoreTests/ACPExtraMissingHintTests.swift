import Testing
import Foundation
@testable import ScarfCore

/// Hermes v0.22.5 parity, slice S9 — `hermes acp` on an install without the
/// ACP extra prints why to stderr and exits 1; the chat banner must say what
/// Hermes says to run instead of a bare "Failed".
@Suite struct ACPExtraMissingHintTests {

    /// `cmd_acp`'s ImportError path, v0.21.6+ (`hermes_cli/main_agent_cmds.py:97`
    /// @ v0.22.5; the command is `pm/extras.py` `install_hint("acp")`).
    static let v0225Stderr = """
    The ACP server can't start: its protocol packages are missing from this install.
    From the Hermes environment, run: hermes pm install --extra acp
    Then restart Hermes.
    Details: No module named 'acp'
    """

    /// The same opening line at v2026.9.24 (`hermes_cli/main_dep_hints.py:18`).
    static let v0215Stderr = """
    The ACP server can't start: its protocol packages are missing from this install.
    Run `hermes update` to reinstall dependencies. If that fails, run manually:
      cd /opt/hermes && /opt/hermes/.venv/bin/python -m pip install -e '.[acp]'
      (no pip in this venv: uv pip install -e '.[acp]')
    Details: No module named 'acp'
    """

    static let terminated = ACPClientError.processTerminated(exitCode: 1, stderrTail: "")

    @Test func quotesHermesInstallCommand() throws {
        let cls = try #require(ACPErrorHint.classify(
            errorMessage: Self.terminated.localizedDescription, stderrTail: Self.v0225Stderr))
        #expect(cls.hint.contains("`hermes pm install --extra acp`"))
        #expect(cls.hint.contains("protocol packages are missing"))
        #expect(cls.oauthProvider == nil)
    }

    @Test func quotesOlderHermesCommand() throws {
        let cls = try #require(ACPErrorHint.classify(
            errorMessage: Self.terminated.localizedDescription, stderrTail: Self.v0215Stderr))
        #expect(cls.hint.contains("`hermes update`"))
        #expect(!cls.hint.contains("pm install"))
    }

    @Test func fallsBackWhenTheCommandLineIsCutOff() throws {
        let tail = "The ACP server can't start: its protocol packages are missing from this install.\n"
        let cls = try #require(ACPErrorHint.classify(errorMessage: "", stderrTail: tail))
        #expect(cls.hint.contains("Run the install command Hermes printed"))
    }

    @Test func inertWithoutHermesText() {
        let hint = ACPErrorHint.classify(
            errorMessage: Self.terminated.localizedDescription, stderrTail: "Traceback: something else")
        #expect(hint?.hint.contains("protocol packages") != true)
    }
}
