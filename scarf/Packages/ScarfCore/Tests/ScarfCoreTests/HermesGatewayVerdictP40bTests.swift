import Testing
import Foundation
@testable import ScarfCore

/// P40b — the review of P40's four commits. Everything here is a verdict that
/// P40 got wrong by not walking a helper the handler calls.
@Suite("P40b — gateway / plugins verdicts, re-walked")
struct HermesGatewayVerdictP40bTests {

    // MARK: - the launchd detached fallback is a real start

    /// `_launchd_fallback_to_detached` (`hermes_cli/gateway.py:3607-3618` @
    /// v2026.9.7) `Popen`s the gateway, prints
    /// `✓ Started gateway as a background process instead` (`:3614`) and
    /// returns True. P40 judged `launchd_start`'s own body and reported every
    /// macOS host whose launchd domain is unmanageable as "Start failed".
    @Test func aDetachedFallbackStartIsASuccess() {
        let output = """
        ⚠ launchd cannot manage the gateway on this macOS version (launchctl exit 125).
        ✓ Started gateway as a background process instead
          It will NOT auto-start at login or auto-restart on crash.
          Logs: ~/.hermes/logs/gateway.log
          Stop it with: hermes gateway stop
        """
        let outcome = HermesGatewayServiceVerdict.judge(verb: .start, output: output, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.confidence == .confirmed)
    }

    /// The same helper is reached from `launchd_restart`'s two
    /// `_launchd_degrade_or_raise` arms (`:4068`, `:4079`).
    @Test func aDetachedFallbackRestartIsASuccess() {
        let output = """
        ⚠ launchd cannot manage the gateway on this macOS version (launchctl kickstart exit 5).
        ✓ Started gateway as a background process instead
          Stop it with: hermes gateway stop
        """
        let outcome = HermesGatewayServiceVerdict.judge(verb: .restart, output: output, exitCode: 0)
        #expect(outcome.succeeded)
    }

    /// The helper's OTHER exit: `print_error("Failed to start the gateway as a
    /// background process.")` then `sys.exit(1)` (`:3619-3622`). The exit code
    /// owns it — and the success marker must not be confused by the
    /// surrounding prose.
    @Test func aFailedDetachedFallbackIsAFailure() {
        let output = """
        ⚠ launchd cannot manage the gateway on this macOS version (launchctl exit 125).
        ✗ Failed to start the gateway as a background process.
          Try manually: nohup hermes gateway run --replace > ~/.hermes/logs/gateway.log 2>&1 &
        """
        let outcome = HermesGatewayServiceVerdict.judge(verb: .start, output: output, exitCode: 1)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .failed)
    }

    /// The `⚠ launchd cannot manage …` line must not read as a managed-install
    /// refusal: `managedRefusalAnchored` anchors `Cannot …` and this line
    /// starts `launchd cannot`.
    @Test func theLaunchdUnsupportedNoticeIsNotAManagedRefusal() {
        let line = "launchd cannot manage the gateway on this macOS version (launchctl exit 125)."
        #expect(HermesCLIMarkers.managedRefusalAnchored.contains { line.hasPrefix($0) } == false)
    }

    // MARK: - Windows restart

    /// `gateway_windows.restart()` (`gateway_windows.py:1380-1399`) is
    /// `stop()` + `start()` and prints no restart line of its own, so the run
    /// ends on `start()`'s line (`:971` / `:698`). P40 had those on the START
    /// verb only, so every Windows restart was "could not confirm".
    @Test(arguments: [
        "✓ Gateway started via Scheduled Task (PID: 4812)",
        "✓ Gateway already running (PID: 4812)",
    ])
    func aWindowsRestartIsJudgedByStartsOwnLine(line: String) {
        let outcome = HermesGatewayServiceVerdict.judge(verb: .restart, output: line, exitCode: 0)
        #expect(outcome.succeeded, "restart must accept \(line)")
    }

    /// …and the Windows failure line still loses.
    @Test func aWindowsRestartFailureIsStillAFailure() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart,
            output: "✗ Gateway start via Scheduled Task FAILED — no stable gateway process detected.",
            exitCode: 0
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .failed)
    }

    // MARK: - the foreground restart

    /// `_cmd_restart`'s last-resort arm (`gateway.py:6062-6066`) prints
    /// `✓ Stopped gateway for this profile` and `Starting gateway...`, then
    /// runs the gateway in the FOREGROUND — the run ends at Scarf's timeout.
    /// That is neither "restarted" nor a refusal.
    @Test func aForegroundRestartIsUnconfirmedRatherThanFailed() {
        let output = """
        ✓ Stopped gateway for this profile
        Starting gateway...
        """
        let outcome = HermesGatewayServiceVerdict.judge(verb: .restart, output: output, exitCode: 0)
        #expect(outcome.succeeded == false, "nothing may claim 'restarted' without a confirmation line")
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail == HermesGatewayServiceVerdict.foregroundStartNote)
    }

    /// P40c corrects this case to the real semantics. The timeout IS the
    /// shape: `run_gateway` never returns, so a foreground restart can only
    /// ever end at Scarf's own timer with exit `-1`. Judging that `.failed`
    /// because "the exit code wins" made the `.unconfirmed` arm above
    /// unreachable in production — exit 0 is what this arm never sees.
    @Test func aForegroundRestartThatTimedOutIsUnconfirmed() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart,
            output: "Starting gateway...\nCommand timed out after 30s.",
            exitCode: -1
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail == HermesGatewayServiceVerdict.foregroundStartNote)
    }

    /// …and a timeout WITHOUT the line stays a failure: nothing was printed
    /// that says the gateway is coming up, so "could not confirm" would be a
    /// claim Scarf has no evidence for.
    @Test func aTimeoutWithoutTheForegroundLineIsStillAFailure() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: "Command timed out after 30s.", exitCode: -1
        )
        #expect(outcome.confidence == .failed)
    }

    /// A refusal in the same output outranks the foreground note.
    @Test func aRefusalOutranksTheForegroundNote() {
        let output = """
        ⚠ Cannot restart gateway as a service — linger is not enabled.
        Starting gateway...
        """
        let outcome = HermesGatewayServiceVerdict.judge(verb: .restart, output: output, exitCode: 0)
        #expect(outcome.confidence == .failed)
        #expect(outcome.detail?.contains("linger") == true)
        // …and after the timeout too (P40c): the arm is keyed on the absence
        // of a refusal, not on the exit code, so it must still stand aside.
        let timedOut = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: output, exitCode: -1
        )
        #expect(timedOut.confidence == .failed)
        #expect(timedOut.detail?.contains("linger") == true)
    }

    /// `Starting gateway...` on the START verb is not a thing `_cmd_start`
    /// prints, and must not become one by accident.
    @Test func theForegroundNoteIsRestartOnly() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .start, output: "Starting gateway...", exitCode: 0
        )
        #expect(outcome.detail != HermesGatewayServiceVerdict.foregroundStartNote)
    }

    // MARK: - the three-state confidence

    /// The s6 blind spot: `_dispatch_via_service_manager_if_s6`
    /// (`gateway.py:5608-5629`) prints NOTHING on success. "Could not
    /// confirm" must be distinguishable from a refusal, because
    /// `stopHermes()`'s fallback is a `kill -TERM` that s6 reads as a crash.
    @Test func silenceAtExitZeroIsUnconfirmedNotFailed() {
        let outcome = HermesGatewayServiceVerdict.judge(verb: .stop, output: "", exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
    }

    @Test func aMatchedRefusalIsFailed() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .stop,
            output: "✗ Refusing to stop the gateway from inside the gateway process.",
            exitCode: 1
        )
        #expect(outcome.confidence == .failed)
    }

    @Test func aNothingWasRunningStopIsConfirmed() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .stop, output: "✗ No gateway running for this profile", exitCode: 0
        )
        #expect(outcome.succeeded)
        #expect(outcome.confidence == .confirmed)
        #expect(outcome.warning == HermesGatewayServiceVerdict.nothingWasRunningNote)
    }

    /// The two-argument initialiser every pre-P40b call site uses still maps
    /// onto the two ends of the scale.
    @Test func theBoolInitialiserKeepsItsMeaning() {
        #expect(HermesCLIOutcome(succeeded: true, detail: nil).confidence == .confirmed)
        #expect(HermesCLIOutcome(succeeded: false, detail: nil).confidence == .failed)
    }

    // MARK: - plugins update: flagged but NOT disabled

    /// `_rescan_after_update` (`plugins_cmd.py:832-851`) prints the
    /// `⚠ Security scan flagged the updated plugin: {reason}` line for EVERY
    /// not-allowed verdict (`:843`) but only disables on `dangerous`
    /// (`:845-851`). P40 keyed the third state on `has been disabled.`, so a
    /// `suspicious` verdict was reported as a flat success and the user never
    /// learned the scan had found anything.
    @Test func aFlaggedButNotDisabledUpdateStillWarns() throws {
        let output = """
        ⚠ Security scan flagged the updated plugin: suspicious: reads ~/.ssh
        Findings: 1 suspicious pattern
        ✓ Plugin weather updated.
        """
        let outcome = HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.succeeded)
        let warning = try #require(outcome.warning)
        #expect(warning.contains("reads ~/.ssh"))
        #expect(warning.contains("disabled") == false,
                "nothing was disabled — the copy must not say it was")
    }

    /// The `dangerous` arm keeps its own wording.
    @Test func aDisabledUpdateSaysDisabled() throws {
        let output = """
        ⚠ Security scan flagged the updated plugin: dangerous: subprocess with shell=True
        Plugin 'weather' has been disabled. Review the findings, then re-enable with `hermes plugins enable weather`.
        ✓ Plugin weather updated.
        """
        let outcome = HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.succeeded)
        let warning = try #require(outcome.warning)
        #expect(warning.contains("disabled by the security scan"))
        #expect(warning.contains("shell=True"))
    }

    /// A clean update still carries no warning at all.
    @Test func aCleanUpdateCarriesNoWarning() {
        let outcome = HermesPluginsUpdateVerdict.judge(
            output: "✓ Plugin weather updated.", exitCode: 0
        )
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    // MARK: - rich's 80-column wrap

    /// `rich` wraps `console.print` at 80 columns when stdout is not a TTY,
    /// which can split `✓ Plugin <long name> updated.` across two lines and
    /// break the whole-shape success match. Both transports hand Hermes a
    /// wide `COLUMNS` so its own lines arrive intact.
    @Test func theLocalSubprocessEnvironmentCarriesAWideCOLUMNS() throws {
        let env = LocalTransport.subprocessEnvironment(forExecutable: "/usr/local/bin/hermes")
        let columns = try #require(env["COLUMNS"])
        #expect((Int(columns) ?? 0) > 80, "rich would wrap at 80 without this")
        #expect(columns == LocalTransport.wideColumns)
    }

    /// ssh does not forward the client's environment, so the remote command
    /// carries the assignment itself.
    @Test func theRemoteCommandCarriesAWideCOLUMNS() {
        let transport = SSHTransport(
            contextID: UUID(),
            config: SSHConfig(host: "box.local"),
            displayName: "Box"
        )
        let cmd = transport.composedRemoteCommand(executable: "hermes", args: ["plugins", "update"])
        #expect(cmd.hasPrefix("COLUMNS=\(LocalTransport.wideColumns) "))
    }

    /// The wrap this guards against, spelled out: the marker requires the
    /// column-0 `Plugin ` prefix AND an `updated.` tail on ONE line.
    @Test func anEightyColumnWrapWouldHaveBrokenTheSuccessMatch() {
        let wrapped = """
        ✓ Plugin an-extremely-long-plugin-name-that-rich-will-happily-wrap-at-eighty
        updated.
        """
        #expect(HermesPluginsUpdateVerdict.judge(output: wrapped, exitCode: 0).succeeded == false)
        let unwrapped = "✓ Plugin an-extremely-long-plugin-name-that-rich-will-happily-wrap-at-eighty updated."
        #expect(HermesPluginsUpdateVerdict.judge(output: unwrapped, exitCode: 0).succeeded)
    }
}
