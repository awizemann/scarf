import Testing
import Foundation
@testable import ScarfCore

/// P40 — the CLI outcome verdicts for `gateway start|stop|restart`,
/// `mcp remove`, `mcp test` and `plugins update`, plus the two `--` argv
/// guards in this phase's scope.
///
/// Every fixture is the emitter's own text, reproduced from the Hermes source
/// at tag `v2026.9.7` with `color()` a no-op — which is what it is for Scarf,
/// since `hermes_cli/colors.py::should_use_color()` is `sys.stdout.isatty()`
/// and Scarf always pipes.
@Suite("HermesCLIVerdictP40")
struct HermesCLIVerdictP40Tests {

    // MARK: - gateway stop

    /// `_cmd_stop`'s single-profile "nothing to stop" arm
    /// (`hermes_cli/gateway.py:5998` @ v2026.9.7), at exit 0. Round-4
    /// decision 2: a SUCCESS carrying the neutral note.
    @Test func stopWithNothingRunningIsASuccessWithANote() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .stop, output: "✗ No gateway running for this profile", exitCode: 0
        )
        #expect(outcome.succeeded)
        #expect(outcome.detail == nil)
        #expect(outcome.warning == HermesGatewayServiceVerdict.nothingWasRunningNote)
    }

    /// The `--all` spelling (`:5993`) and the s6 one (`:5644`) take the same
    /// arm.
    @Test(arguments: [
        "✗ No gateway processes found",
        "✗ No profile gateways registered under s6",
    ])
    func everyNothingRunningSpellingIsTheSameState(line: String) {
        let outcome = HermesGatewayServiceVerdict.judge(verb: .stop, output: line, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.warning != nil)
    }

    /// `_cmd_stop`'s three success lines (`:5991`, `:5996`, `:6000`) and the
    /// two backend lines (`launchd_stop` `:3978`, `systemd_stop` `:3186`).
    @Test(arguments: [
        "✓ Stopped gateway for this profile",
        "✓ Stopped 2 gateway process(es) across all profiles",
        "✓ Stopped hermes-gateway service",
        "✓ Service stopped",
        "✓ User service stopped",
        "✓ System service stopped",
        "✓ Stopped 3 profile gateway(s) under s6",
    ])
    func everyStopSuccessLineIsRecognised(line: String) {
        let outcome = HermesGatewayServiceVerdict.judge(verb: .stop, output: line, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    /// The regression this phase exists for: exit 0 with no line Hermes
    /// itself printed is never a success (charter C5). Before P40 the five
    /// call sites read `exitCode == 0` and reported a stop that never
    /// happened — two of them into Analytics.
    @Test func exitZeroWithNoSuccessLineIsNotASuccess() {
        for verb in HermesGatewayServiceVerdict.Verb.allCases {
            let outcome = HermesGatewayServiceVerdict.judge(
                verb: verb, output: "", exitCode: 0
            )
            #expect(!outcome.succeeded, "\(verb.rawValue) read silence as success")
        }
    }

    /// "Nothing was running" must not launder a REAL refusal printed in the
    /// same run — `_refuse_from_inside_gateway` (`gateway.py:5776-5781` via
    /// `print_error`) is the one that can share the output.
    @Test func aRealRefusalIsNotLaunderedByTheNothingRunningNote() {
        let output = """
        ✗ Refusing to stop the gateway from inside the gateway process.
        ✗ No gateway running for this profile
        """
        let outcome = HermesGatewayServiceVerdict.judge(verb: .stop, output: output, exitCode: 0)
        #expect(!outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    // MARK: - gateway start

    @Test(arguments: [
        "✓ Service started",
        "✓ User service started",
        "✓ System service started",
        "✓ Gateway started via detached launcher (PID: 4021)",
        "✓ Gateway already running (PID: 4021)",
    ])
    func everyStartSuccessLineIsRecognised(line: String) {
        #expect(HermesGatewayServiceVerdict.judge(verb: .start, output: line, exitCode: 0).succeeded)
    }

    /// `_no_backend_exit`'s `("start", "container")` row is the one that
    /// carries an exit code of 0 (`hermes_cli/gateway.py:5854-5860`), and it
    /// prints no success line at all.
    @Test func theContainerNoBackendArmIsAFailure() {
        let output = """
        Service start is not applicable inside a Docker container.
        The gateway runs as the container's main process.

          docker start <container>     # start a stopped container
        """
        let outcome = HermesGatewayServiceVerdict.judge(verb: .start, output: output, exitCode: 0)
        #expect(!outcome.succeeded)
    }

    /// `launchd_start` returns WITHOUT `✓ Service started` when the bootstrap
    /// degrades (`:3926-3928`, `:3938-3939`) — still exit 0.
    @Test func aDegradedLaunchdBootstrapIsAFailure() {
        let output = "↻ launchd plist missing; regenerating service definition"
        #expect(!HermesGatewayServiceVerdict.judge(verb: .start, output: output, exitCode: 0).succeeded)
    }

    // MARK: - gateway restart

    @Test(arguments: [
        "✓ Service restarted",
        "✓ Service restart requested",
        "✓ User service restarted (PID 4021)",
        "✓ System service restarted (PID 4021)",
        "✓ Restarted 3 profile gateway(s) under s6",
    ])
    func everyRestartSuccessLineIsRecognised(line: String) {
        #expect(HermesGatewayServiceVerdict.judge(verb: .restart, output: line, exitCode: 0).succeeded)
    }

    /// `⚠ Cannot restart gateway as a service — linger is not enabled.`
    /// (`gateway.py:6047`) is a plain `return` at exit 0. It is NOT a managed
    /// install; the shared `Cannot ` ANCHOR is what catches it.
    @Test func theLingerRefusalIsAFailureAndIsQuoted() {
        let output = """

        ⚠ Cannot restart gateway as a service — linger is not enabled.
          The gateway user service requires linger to function on headless servers.

          Run:  sudo loginctl enable-linger alan
        """
        let outcome = HermesGatewayServiceVerdict.judge(verb: .restart, output: output, exitCode: 0)
        #expect(!outcome.succeeded)
        #expect(outcome.detail?.contains("linger is not enabled") == true)
    }

    /// A warning printed BEFORE a real success line must not flip it —
    /// `_systemd_graceful_restart_action` prints
    /// `⚠ Graceful restart did not complete within 180s; forcing a service
    /// restart...` (`gateway.py:3249`) and the restart then succeeds.
    @Test func aWarningBeforeTheSuccessLineDoesNotWin() {
        let output = """
        ⏳ User service restarting gracefully (PID 4021) — waiting up to 180s for in-flight turns + drain...
        ⚠ Graceful restart did not complete within 180s; forcing a service restart...
        ✓ User service restarted (PID 4099)
        """
        #expect(HermesGatewayServiceVerdict.judge(verb: .restart, output: output, exitCode: 0).succeeded)
    }

    /// `_wait_for_systemd_service_restart`'s startup-failed arm (`:1223`)
    /// returns False at exit 0 with no `✓` line; the reason is quoted.
    @Test func aStartedProcessWithAFailedRuntimeIsAFailure() {
        let output = "⚠ User service process restarted (PID 4099), but gateway startup failed: port in use"
        let outcome = HermesGatewayServiceVerdict.judge(verb: .restart, output: output, exitCode: 0)
        #expect(!outcome.succeeded)
        #expect(outcome.detail?.contains("port in use") == true)
    }

    /// The verbs do not borrow each other's success lines: a `stop` line in a
    /// `start` run is not proof the gateway came up.
    @Test func aStopLineDoesNotSatisfyStart() {
        #expect(!HermesGatewayServiceVerdict.judge(
            verb: .start, output: "✓ Stopped gateway for this profile", exitCode: 0
        ).succeeded)
    }

    @Test func gatewayArgvCarriesNoStrayToken() {
        #expect(HermesGatewayServiceVerdict.argv(.start) == ["gateway", "start"])
        #expect(HermesGatewayServiceVerdict.argv(.stop) == ["gateway", "stop"])
        #expect(HermesGatewayServiceVerdict.argv(.restart) == ["gateway", "restart"])
    }

    // MARK: - mcp remove

    @Test func mcpRemoveSuccessIsTheEmittersOwnLine() {
        let outcome = HermesMCPRemoveVerdict.judge(
            output: "  ✓ Removed 'files' from config\n  ✓ Cleaned up OAuth tokens", exitCode: 0
        )
        #expect(outcome.succeeded)
    }

    /// `_lookup_server` prints and `cmd_mcp_remove` returns — exit 0
    /// (`hermes_cli/mcp_config.py:104`, `:518-519`).
    @Test func mcpRemoveNotFoundIsAFailure() {
        let output = """
          ✗ Server 'nope' not found in config.
          Available servers: files, github
        """
        let outcome = HermesMCPRemoveVerdict.judge(output: output, exitCode: 0)
        #expect(!outcome.succeeded)
        #expect(outcome.detail?.contains("not found in config.") == true)
    }

    /// The managed-install shape: `save_config` refuses
    /// (`hermes_cli/config.py:2316-2318`) and `:524` prints the success line
    /// anyway. `failureWins` is what makes this a failure.
    @Test func aManagedRefusalBeatsTheRemoveSuccessLine() {
        let output = """
        Cannot save configuration: this Hermes install is managed by your administrator.
          ✓ Removed 'files' from config
        """
        #expect(!HermesMCPRemoveVerdict.judge(output: output, exitCode: 0).succeeded)
    }

    @Test func mcpRemoveArgvEndsTheOptions() {
        #expect(HermesMCPRemoveVerdict.argv(name: "-weird") == ["mcp", "remove", "--", "-weird"])
    }

    // MARK: - mcp test

    /// The false positive the bare `output.contains("✗")` produced: the
    /// success path prints every discovered tool's own description
    /// (`_print_tools`, `mcp_config.py:49-52`).
    @Test func aToolDescribedWithAFailurePhraseDoesNotTurnAHealthyProbeRed() {
        let output = """
          Testing 'files'...
            Transport: stdio → npx
            Auth: none
          ✓ Connected (412ms)
          ✓ Tools discovered: 2
            probe        Reports "✗ Connection failed (…)" when the peer is down
            list_dir     Fails with No such file or directory on a bad path
        """
        #expect(HermesMCPTestVerdict.judge(output: output, exitCode: 0).succeeded)
    }

    @Test func aRealConnectionFailureIsAFailure() {
        let output = """
          Testing 'flaky'...
            Transport: HTTP → https://example.invalid/mcp
          ✗ Connection failed (5001ms): timed out
        """
        let outcome = HermesMCPTestVerdict.judge(output: output, exitCode: 0)
        #expect(!outcome.succeeded)
        #expect(outcome.detail?.contains("timed out") == true)
    }

    @Test func mcpTestArgvEndsTheOptions() {
        #expect(HermesMCPTestVerdict.argv(name: "-weird") == ["mcp", "test", "--", "-weird"])
    }

    // MARK: - plugins update (round-4 decision 3)

    @Test func aPlainUpdateIsAPlainSuccess() {
        let output = """
        Updating weather...
        ✓ Plugin weather updated.
        Updating 3 files, 12 insertions(+), 4 deletions(-)
        """
        let outcome = HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    /// The third state. `_rescan_after_update` disables the plugin
    /// (`hermes_cli/plugins_cmd.py:845-851` @ v2026.9.7) and `cmd_update`
    /// prints its success line anyway (`:828`); both at exit 0.
    @Test func aSecurityDisabledUpdateIsASuccessCarryingTheReason() throws {
        let output = """
        Updating weather...

        ⚠ Security scan flagged the updated plugin: dangerous: subprocess with shell=True
        [scan report body]
        Plugin 'weather' has been disabled. Review the findings, then re-enable with `hermes plugins enable weather` if you trust them.
        ✓ Plugin weather updated.
        """
        let outcome = HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.succeeded)
        let warning = try #require(outcome.warning)
        #expect(warning.contains("disabled by the security scan"))
        #expect(warning.contains("subprocess with shell=True"))
    }

    /// The unanchored-success bug: `"updated."` matched a `git pull` body
    /// line in a run that printed no success line of its own (`:829`).
    @Test func aPullBodyMentioningUpdatedIsNotASuccess() {
        let output = """
        Updating weather...
        commit a1b2c3d  docs updated.
        """
        #expect(!HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0).succeeded)
    }

    @Test func theConsentRefusalStillBeatsTheSuccessLine() {
        let output = """
        capabilities NOT granted (fail closed).
        ✓ Plugin weather updated.
        """
        #expect(!HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0).succeeded)
    }

    @Test func alreadyUpToDateIsASuccess() {
        #expect(HermesPluginsUpdateVerdict.judge(
            output: "✓ Plugin weather is already up to date.", exitCode: 0
        ).succeeded)
    }

    // MARK: - argv separators

    /// `skills trust|untrust`'s only positional is `path` (`nargs="?"`) with
    /// no flag after it (`hermes_cli/subcommands/skills.py:29-37` @
    /// v2026.9.7), so `--` is both safe and needed for a root beginning `-`.
    @Test func skillsTrustArgvEndsTheOptions() {
        #expect(ProjectSkillsScanner.trustArgs("-odd/repo", trusted: true)
            == ["skills", "trust", "--", "-odd/repo"])
        #expect(ProjectSkillsScanner.trustArgs("-odd/repo", trusted: false)
            == ["skills", "untrust", "--", "-odd/repo"])
    }
}
