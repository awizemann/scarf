import Testing
import Foundation
@testable import ScarfCore

/// P40c — the third review of P40's gateway verdicts: the partial stdout a
/// transport timeout carries, and the `Gateway already running` collision.
@Suite("HermesGatewayVerdictP40c")
struct HermesGatewayVerdictP40cTests {

    // MARK: - the timeout carries what the child printed

    /// `TransportError.timeout` has carried `partialStdout` since it was
    /// introduced, but nothing read it: `diagnosticStderr` has no `.timeout`
    /// case (by design — it is *stderr*), so `runHermesCLI` dropped it. The
    /// named accessor is what closes the hole without moving the meaning of
    /// `diagnosticStderr` for its seven other callers.
    @Test func aTimeoutSurrendersItsPartialStdoutByName() throws {
        let data = try #require("Starting gateway...\n".data(using: .utf8))
        let error = TransportError.timeout(seconds: 30, partialStdout: data)
        #expect(error.partialStdoutText == "Starting gateway...\n")
        // …and it is still not stderr.
        #expect(error.diagnosticStderr == "")
    }

    @Test func everyOtherCaseHasNoPartialStdout() {
        #expect(TransportError.commandFailed(exitCode: 1, stderr: "boom").partialStdoutText == "")
        #expect(TransportError.hostUnreachable(host: "h", stderr: "x").partialStdoutText == "")
        #expect(TransportError.other(message: "x").partialStdoutText == "")
    }

    /// Both transports must capture the partial stdout the same way — the SSH
    /// side does (`SSHTransport.swift:1130`, after a `waitUntilExit` so the
    /// read cannot race the kill), the local side does
    /// (`LocalTransport.swift:306`). This pins the shape a caller depends on.
    @Test func aTimeoutWithNoOutputIsEmptyNotNil() {
        #expect(TransportError.timeout(seconds: 5, partialStdout: Data()).partialStdoutText == "")
    }

    // MARK: - `Gateway already running` is two different lines

    /// The Windows success line — `_report_already_running`,
    /// `hermes_cli/gateway_windows.py:698` @ v2026.9.7 — which spells the PID
    /// with a colon.
    @Test(arguments: [HermesGatewayServiceVerdict.Verb.start, .restart])
    func theWindowsAlreadyRunningLineIsASuccess(verb: HermesGatewayServiceVerdict.Verb) {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: verb, output: "✓ Gateway already running (PID: 4821)", exitCode: 0
        )
        #expect(outcome.succeeded)
    }

    /// The collision: `gateway/run.py:4769` prints
    /// `❌ Gateway already running (PID {n}).` — a REFUSAL from
    /// `_start_gateway_replace_existing_instance`, which returns False and
    /// aborts startup — with NO colon. It reaches Scarf on exactly the path
    /// the foreground arm above covers (a run that ends inside `run_gateway`),
    /// and the only thing that kept the old marker off it was `❌` not being
    /// in the glyph set. It must never read as a success.
    @Test func theRunPyRefusalIsNotASuccess() {
        let output = """
        ❌ Gateway already running (PID 4821).
           Use 'hermes gateway restart' to replace it,
           or 'hermes gateway stop' to kill it first.
        """
        for verb in [HermesGatewayServiceVerdict.Verb.start, .restart] {
            #expect(
                HermesGatewayServiceVerdict.judge(verb: verb, output: output, exitCode: 0)
                    .succeeded == false,
                "run.py's refusal must not be read as the Windows success line"
            )
        }
    }

    /// The refusal reaches Scarf on the very path the foreground arm covers:
    /// `_cmd_restart`'s last-resort `run_gateway` (`gateway.py:6066`), whose
    /// run ends at Scarf's timeout. `Starting gateway...` is in that output —
    /// so without a marker for the refusal this read as "started in the
    /// foreground, could not confirm" while the gateway had refused to start.
    @Test func theRunPyRefusalOutranksTheForegroundNote() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart,
            output: """
            ✓ Stopped gateway for this profile
            Starting gateway...

            ❌ Gateway already running (PID 4821).
               Use 'hermes gateway restart' to replace it,
            """,
            exitCode: -1
        )
        #expect(outcome.confidence == .failed)
        #expect(outcome.detail?.contains("Gateway already running") == true,
                "the banner quotes Hermes's reason, not the foreground note")
    }

    /// And the marker does not touch the Windows success line, which is the
    /// whole reason it carries a space where that one has a colon.
    @Test func theWindowsSuccessLineIsNotCaughtByTheRefusalMarker() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: "✓ Gateway already running (PID: 4821)", exitCode: 0
        )
        #expect(outcome.succeeded)
        #expect(outcome.confidence == .confirmed)
    }

    /// And the glyph is not what the marker leans on: the same colon-less
    /// sentence with no glyph at all — or behind a `✓`, which is what a
    /// future Hermes could do — still must not pass.
    @Test(arguments: ["Gateway already running (PID 4821).", "✓ Gateway already running (PID 4821)."])
    func theColonIsWhatTellsThemApart(line: String) {
        #expect(
            HermesGatewayServiceVerdict.judge(verb: .start, output: line, exitCode: 0)
                .succeeded == false
        )
    }

    // MARK: - the container refusal is a refusal, not a silence

    /// Found while correcting the P40 banner test, which asserted this exact
    /// output was a FAILURE and stopped being true the moment the third arm
    /// landed. `_no_backend_exit`'s `("start", "container")` entry
    /// (`hermes_cli/gateway.py:5860-5866` @ v2026.9.7) prints at column 0 with
    /// no glyph and exits **0** — a real refusal that was being read as "could
    /// not confirm". Silence is the only thing the neutral arm may claim.
    @Test func theDockerContainerRefusalIsAFailureNotAnUnconfirmed() {
        let output = """
        Service start is not applicable inside a Docker container.
        The gateway runs as the container's main process.

          docker start <container>     # start a stopped container
        """
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .start, output: output, exitCode: 0
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .failed, "Hermes said no in as many words")
        #expect(outcome.detail == "Service start is not applicable inside a Docker container.")
    }

    /// The foreground restart shape end to end, exactly as `runHermesCLI`
    /// hands it over: the partial stdout, then the timeout message as the
    /// last line, at exit `-1`.
    @Test func theForegroundRestartShapeAsTheCallerSeesIt() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart,
            output: """
            ✓ Stopped gateway for this profile
            Starting gateway...
            Command timed out after 30s.
            """,
            exitCode: -1
        )
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.succeeded == false)
        #expect(outcome.detail == HermesGatewayServiceVerdict.foregroundStartNote)
    }
}
