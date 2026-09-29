import Testing
import Foundation
@testable import ScarfCore

/// gh#142 P2 — `HERMES_ENVIRONMENT_HINT` composition.
///
/// Hermes (`agent/prompt_builder.py:1054-1058` @ v0.21.4) uses
/// `(os.getenv("HERMES_ENVIRONMENT_HINT") or "").strip() or
/// config agent.environment_hint`, so a non-empty env var REPLACES the
/// config hint. Scarf's value must keep the user's hint (env, else config)
/// and append its own after a blank line. The remote fragment is executed
/// through a real `/bin/sh` so the quoting is proven, not just pattern-matched.
@Suite struct EnvironmentHintComposerTests {

    /// A value built to break naive quoting: both quote kinds, `$`
    /// expansions, a command substitution, backticks, backslashes, newlines,
    /// a glob and a trailing `'`.
    static let nasty = "it's \"quoted\" $HOME ${X:-y} $(echo pwned) `id` \\n \\\\ back\\slash\nline two\n*\n'"

    // MARK: - Local compose

    @Test func composeUsesScarfAloneWhenNothingElseIsSet() {
        #expect(EnvironmentHintComposer.compose(existing: nil, configHint: nil, scarfHint: "S") == "S")
        #expect(EnvironmentHintComposer.compose(existing: "", configHint: "", scarfHint: "S") == "S")
        #expect(EnvironmentHintComposer.compose(existing: " \n\t", configHint: "  ", scarfHint: "S") == "S")
    }

    @Test func composePrefersExistingEnvOverConfig() {
        #expect(EnvironmentHintComposer.compose(existing: "E", configHint: "C", scarfHint: "S") == "E\n\nS")
    }

    @Test func composeFallsBackToConfigWhenEnvIsBlank() {
        #expect(EnvironmentHintComposer.compose(existing: nil, configHint: "C", scarfHint: "S") == "C\n\nS")
        #expect(EnvironmentHintComposer.compose(existing: "   ", configHint: "C", scarfHint: "S") == "C\n\nS")
    }

    @Test func composeKeepsTheBaseVerbatim() {
        #expect(EnvironmentHintComposer.compose(existing: Self.nasty, configHint: nil, scarfHint: "S")
                == Self.nasty + "\n\nS")
    }

    @Test func applyingNilOrBlankScarfHintLeavesTheEnvironmentIdentical() {
        let env = ["PATH": "/bin", "HERMES_ENVIRONMENT_HINT": "mine"]
        #expect(EnvironmentHintComposer.applying(scarfHint: nil, configHint: "C", to: env) == env)
        #expect(EnvironmentHintComposer.applying(scarfHint: " \n", configHint: "C", to: env) == env)
        #expect(EnvironmentHintComposer.applying(scarfHint: nil, configHint: nil, to: [:]) == [:])
    }

    @Test func applyingComposesAgainstTheGivenEnvironment() {
        let env = ["PATH": "/bin", "HERMES_ENVIRONMENT_HINT": "mine"]
        let out = EnvironmentHintComposer.applying(scarfHint: "S", configHint: "C", to: env)
        #expect(out == ["PATH": "/bin", "HERMES_ENVIRONMENT_HINT": "mine\n\nS"])
        #expect(EnvironmentHintComposer.applying(scarfHint: "S", configHint: "C", to: ["PATH": "/bin"])
                == ["PATH": "/bin", "HERMES_ENVIRONMENT_HINT": "C\n\nS"])
    }

    // MARK: - Remote fragment, executed by a real shell

    @Test func fragmentIsEmptyForNilOrBlankScarfHint() {
        #expect(EnvironmentHintComposer.remoteShellFragment(configHint: "C", scarfHint: nil) == "")
        #expect(EnvironmentHintComposer.remoteShellFragment(configHint: "C", scarfHint: "") == "")
        #expect(EnvironmentHintComposer.remoteShellFragment(configHint: "C", scarfHint: " \n ") == "")
    }

    @Test(arguments: [
        // (pre-set env value or nil = unset, config hint)
        (String?.none, String?.none),
        (String?.none, String?("C")),
        (String?(""), String?("C")),
        (String?("  \n "), String?("C")),
        (String?("E"), String?("C")),
        (String?("E"), String?.none),
        (String?(EnvironmentHintComposerTests.nasty), String?(EnvironmentHintComposerTests.nasty)),
        (String?.none, String?(EnvironmentHintComposerTests.nasty)),
        (String?("  \n "), String?("   ")),
    ])
    func fragmentMatchesLocalCompose(existing: String?, config: String?) async throws {
        for scarf in ["S", Self.nasty] {
            let fragment = EnvironmentHintComposer.remoteShellFragment(configHint: config, scarfHint: scarf)
            let got = try await Self.runSh(fragment + "printf %s \"$HERMES_ENVIRONMENT_HINT\"", preset: existing)
            #expect(got == EnvironmentHintComposer.compose(existing: existing, configHint: config, scarfHint: scarf))
        }
    }

    /// The fragment EXPORTS the value: a child process (what `exec hermes`
    /// becomes) sees it, not just the shell.
    @Test func fragmentExportsToChildProcesses() async throws {
        let fragment = EnvironmentHintComposer.remoteShellFragment(configHint: nil, scarfHint: Self.nasty)
        let got = try await Self.runSh(fragment + "/usr/bin/printenv HERMES_ENVIRONMENT_HINT", preset: "E")
        #expect(got == "E\n\n" + Self.nasty + "\n")
    }

    /// The fragment survives `set -u` (an unset var is read as `${VAR:-}`).
    @Test func fragmentIsSafeUnderNounset() async throws {
        let fragment = EnvironmentHintComposer.remoteShellFragment(configHint: "C", scarfHint: "S")
        let got = try await Self.runSh("set -u; " + fragment + "printf %s \"$HERMES_ENVIRONMENT_HINT\"", preset: nil)
        #expect(got == "C\n\nS")
    }

    // MARK: - SSHTransport

    private static func transport() -> SSHTransport {
        SSHTransport(contextID: UUID(), config: SSHConfig(host: "box", remoteHome: "~/.hermes/profiles/work"),
                     displayName: "box")
    }

    @Test func composedRemoteCommandIsByteIdenticalWithoutAHint() {
        let t = Self.transport()
        let base = t.composedRemoteCommand(executable: "hermes", args: ["acp"], cwd: "/srv/my app")
        #expect(t.composedRemoteCommand(executable: "hermes", args: ["acp"], cwd: "/srv/my app",
                                        environmentHint: nil) == base)
        #expect(t.composedRemoteCommand(executable: "hermes", args: ["acp"], cwd: "/srv/my app",
                                        environmentHint: EnvironmentHintRequest(scarfHint: "  ", configHint: "C")) == base)
        #expect(t.remoteShellCommand(executable: "hermes", args: ["acp"], environmentHint: nil)
                == t.remoteShellCommand(executable: "hermes", args: ["acp"]))
        #expect(!base.contains("HERMES_ENVIRONMENT_HINT"))
    }

    /// The fragment goes after the `cd` and before the assignment prefix.
    @Test func composedRemoteCommandPlacesTheFragmentAfterCd() {
        let t = Self.transport()
        let req = EnvironmentHintRequest(scarfHint: "S", configHint: "C")
        let base = t.composedRemoteCommand(executable: "hermes", args: ["acp"], cwd: "/srv/app")
        let cmd = t.composedRemoteCommand(executable: "hermes", args: ["acp"], cwd: "/srv/app", environmentHint: req)
        let fragment = EnvironmentHintComposer.remoteShellFragment(configHint: "C", scarfHint: "S")
        #expect(base.hasPrefix("cd \"/srv/app\"; COLUMNS="))
        #expect(cmd == base.replacingOccurrences(of: "cd \"/srv/app\"; ", with: "cd \"/srv/app\"; " + fragment))
    }

    /// End to end through the same two shell layers the real spawn uses: the
    /// composed command single-quoted as one word (what `SSHTransport`'s
    /// `shellQuote` emits for any non-trivial string) and run by an outer
    /// shell, with `printenv` standing in for `hermes`.
    @Test func composedRemoteCommandDeliversTheValueThroughTwoShellLayers() async throws {
        let t = SSHTransport(contextID: UUID(), config: SSHConfig(host: "box"), displayName: "box")
        let req = EnvironmentHintRequest(scarfHint: Self.nasty, configHint: "cfg 'x' $y")
        let inner = t.composedRemoteCommand(
            executable: "/usr/bin/printenv", args: ["HERMES_ENVIRONMENT_HINT"], environmentHint: req)
        let outer = "/bin/sh -c " + HermesProfileScope.shellSingleQuote(inner)
        #expect(try await Self.runSh(outer, preset: "user's own") == "user's own\n\n" + Self.nasty + "\n")
        #expect(try await Self.runSh(outer, preset: nil) == "cfg 'x' $y\n\n" + Self.nasty + "\n")
    }

    // MARK: - Helpers

    /// Run `script` under `/bin/sh -c` with a minimal env, `HERMES_ENVIRONMENT_HINT`
    /// set to `preset` (or absent), returning stdout. Async (`ShellTestRunner`)
    /// so no pool thread is parked on the child.
    static func runSh(_ script: String, preset: String?) async throws -> String {
        var env = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "LC_ALL": "C"]
        if let preset { env["HERMES_ENVIRONMENT_HINT"] = preset }
        let out = try await ShellTestRunner.run(arguments: ["-c", script], environment: env, timeout: 30)
        #expect(out.status == 0, "stderr: \(out.stderr)")
        return out.stdout
    }
}
