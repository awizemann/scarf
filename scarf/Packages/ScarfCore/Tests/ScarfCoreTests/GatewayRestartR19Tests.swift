import Testing
import Foundation
@testable import ScarfCore

/// R19: the restart guard's parked-profile arm and the v0.21.4+
/// external-supervisor hand-back that can outlast Scarf's CLI timeout.
@Suite struct GatewayRestartR19Tests {

    /// `print_parked_status`'s line for the current named profile
    /// (`gateway_profile_lifecycle.py:87` @ v2026.9.24), which `_cmd_status`
    /// prints and then returns (`gateway.py:5021-5023`).
    static let parked = "Profile 'work': parked (hermes -p work gateway start)\n"

    /// The DEFAULT profile prints a parked line per parked profile and then
    /// its own status (`gateway_profile_lifecycle.py:89-98`).
    static let defaultWithParkedSibling = """
    Served profiles: default, home
    Profile 'work': parked (hermes -p work gateway start)
    Launchd plist: /Users/a/Library/LaunchAgents/ai.hermes.gateway.plist
    ✓ Gateway is supervised by launchd (PID 812)
    """

    static let manualRunning = """
    ✓ Gateway is running (PID: 4242)
      (Running manually, not as a system service)
    """

    static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")

    final class Calls: @unchecked Sendable { var argvs: [[String]] = [] }

    static func decide(status: String, stopThenStart: Bool = false, state: Data? = nil,
                       caps: HermesCapabilities = .empty, calls: Calls = Calls()) -> HermesGatewayRestartGuard.Decision {
        HermesGatewayRestartGuard.decide(
            run: { args, _ in calls.argvs.append(args); return args == ["gateway", "status"] ? (status, 0) : ("", 0) },
            stateJSON: { state }, capabilities: caps, stopThenStart: stopThenStart)
    }

    @Test func aParkedProfileIsNotRestarted() {
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.parked) == .parkedProfile)
        let calls = Calls()
        let decision = Self.decide(status: Self.parked, calls: calls)
        #expect(decision == .refuse(HermesCLIOutcome(succeeded: false, detail: HermesGatewayRestartGuard.parkedProfileNote)))
        // Decided from gateway status alone.
        #expect(calls.argvs == [["gateway", "status"]])
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.parked, statusExitCode: 0, stateJSON: nil, capabilities: .empty)?.detail
            == HermesGatewayRestartGuard.parkedProfileNote)
    }

    /// Stop + start unparks the profile (`gateway start`'s own arm), so it
    /// is not refused there.
    @Test func stopThenStartOfAParkedProfileGoesAhead() {
        #expect(Self.decide(status: Self.parked, stopThenStart: true) == .restart(externallySupervised: false))
    }

    /// A parked sibling listed above the default profile's own status says
    /// nothing about this home; the service branch decides.
    @Test func aParkedSiblingDoesNotBlockTheDefaultProfile() {
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.defaultWithParkedSibling) == .restartable)
        #expect(Self.decide(status: Self.defaultWithParkedSibling) == .restart(externallySupervised: false))
        // A parked line above a hand-run gateway's status is still hand-run.
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.parked + Self.manualRunning) == .runningWithoutService)
    }

    @Test func theSupervisedHandBackIsFlagged() {
        let supervised = try! JSONSerialization.data(withJSONObject: [
            "pid": 4242, "argv": ["hermes", "gateway", "run", "--external-supervisor"]])
        #expect(Self.decide(status: Self.manualRunning, state: supervised, caps: Self.v0214)
            == .restart(externallySupervised: true))
        // Every other go-ahead is not.
        #expect(Self.decide(status: "✓ Gateway is supervised by launchd (PID 812)")
            == .restart(externallySupervised: false))
    }

    // MARK: verdict

    /// `restart_externally_supervised_gateway`'s success line
    /// (`gateway_supervised_restart.py:89` @ v2026.9.24).
    @Test func aSupervisedRelaunchIsASuccess() {
        let output = """
        → Restarting externally-supervised gateway (PID 4242) — draining in-flight runs (up to 60s)...

        ✓ Gateway relaunched by its supervisor (PID 4300)
        """
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: output, exitCode: 0, externallySupervised: true)
        #expect(outcome.succeeded)
        #expect(outcome.confidence == .confirmed)
    }

    /// Scarf's timeout cut a supervised hand-back short: the gateway goes on
    /// restarting, so the answer is "still restarting", not a failure.
    @Test func aSupervisedRestartPastTheTimeoutIsStillRestarting() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: "", exitCode: -1, externallySupervised: true)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail == HermesGatewayServiceVerdict.supervisedRestartPendingNote)
    }

    /// The same timeout on any other restart stays a failure, and the
    /// supervised path's own refusal (exit 1) is still a failure.
    @Test func otherTimeoutsAndRefusalsStayFailures() {
        #expect(HermesGatewayServiceVerdict.judge(verb: .restart, output: "", exitCode: -1).confidence == .failed)
        let refused = """
        ⚠ Supervisor did not relaunch the gateway after its graceful exit

        ✗ Not stopping or foreground-running a supervisor-owned gateway.
        """
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: refused, exitCode: 1, externallySupervised: true)
        #expect(outcome.confidence == .failed)
    }
}
