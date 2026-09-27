import Testing
import Foundation
@testable import ScarfCore

/// R18a (T5-F1): Scarf never sends `hermes gateway restart` to a host whose
/// gateway has no service behind it — Hermes would stop the gateway and run
/// the replacement inside Scarf's own spawn, which Scarf's timeout kills.
///
/// The two no-service fixtures were printed by the v2026.9.24 checkout's own
/// `_cmd_status` (run from its venv against a scratch HERMES_HOME with the
/// service probe and process snapshot stubbed: one PID, then none).
@Suite struct HermesGatewayRestartGuardR18aTests {

    static let manualRunning = """
    ✓ Gateway is running (PID: 4242)
      (Running manually, not as a system service)

    To install as a service:
      hermes gateway install
      sudo hermes gateway install --system
    """

    static let manualStopped = """
    ✗ Gateway is not running

    To start:
      hermes gateway run      # Run in foreground
      hermes gateway install  # Install as user service
      sudo hermes gateway install --system  # Install as boot-time system service
    """

    /// The v2026.3.12 (v0.6 floor era) stopped hint.
    static let manualStoppedFloor = """
    ✗ Gateway is not running

    To start:
      hermes gateway          # Run in foreground
      hermes gateway install  # Install as service
    """

    /// `launchd_status` (`gateway_launchd.py:843-885` @ v2026.9.24).
    static let launchd = """
    Launchd plist: /Users/a/Library/LaunchAgents/ai.hermes.gateway.plist
    ✓ Service definition matches the current Hermes install
    ✓ Gateway is supervised by launchd (PID 812)
      Auto-start at login and auto-restart on crash are available.
    """

    /// The v0.21.1 satellite branch (`gateway.py:5037-5040`).
    static let satellite = """
    ✓ Gateway is running via the default-profile multiplexer
      Manage it from the default profile: hermes gateway status
    """

    static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")

    static func state(pid: Int, argv: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["pid": pid, "kind": "hermes-gateway", "argv": argv])
    }

    @Test func modesFollowTheStatusBranch() {
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.manualRunning) == .runningWithoutService)
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.manualStopped) == .stoppedWithoutService)
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.manualStoppedFloor) == .stoppedWithoutService)
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.launchd) == .restartable)
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.satellite) == .restartable)
        // A service branch that says the gateway is down still restarts
        // through the service manager.
        #expect(HermesGatewayRestartGuard.mode(statusOutput: "✗ Gateway service is not loaded\n  Run: hermes gateway start") == .restartable)
        // Coloured output is read the same.
        #expect(HermesGatewayRestartGuard.mode(statusOutput: "\u{1B}[32m✓ Gateway is running (PID: 1)\u{1B}[0m\n  (Running manually, not as a system service)") == .runningWithoutService)
    }

    @Test func aHandRunGatewayIsRefusedWithTheReason() throws {
        let refusal = try #require(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualRunning, statusExitCode: 0, stateJSON: nil, capabilities: Self.v0214))
        #expect(refusal.succeeded == false)
        #expect(refusal.confidence == .failed)
        #expect(refusal.detail == HermesGatewayRestartGuard.runningWithoutServiceNote)
        #expect(refusal.detail?.contains("hermes gateway install") == true)

        let stopped = try #require(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualStopped, statusExitCode: 0, stateJSON: nil, capabilities: Self.v0214))
        #expect(stopped.detail == HermesGatewayRestartGuard.stoppedWithoutServiceNote)
    }

    @Test func serviceManagedHostsRestartAsBefore() {
        // (A parked profile used to be in this list; R19 refuses it — see
        // `aParkedProfileIsNotRestarted`.)
        for output in [Self.launchd, Self.satellite, ""] {
            #expect(HermesGatewayRestartGuard.refusal(
                statusOutput: output, statusExitCode: 0, stateJSON: nil, capabilities: .empty) == nil)
        }
    }

    @Test func anUnreadableStatusIsNotARestartSentBlind() {
        let timedOut = HermesGatewayRestartGuard.refusal(
            statusOutput: "", statusExitCode: -1, stateJSON: nil, capabilities: .empty)
        #expect(timedOut?.detail == HermesGatewayRestartGuard.statusUnreadableNote)
        // Partial output that the timeout cut still counts as no answer.
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.launchd, statusExitCode: -1, stateJSON: nil, capabilities: .empty) != nil)
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: "  ", statusExitCode: 127, stateJSON: nil, capabilities: .empty) != nil)
    }

    /// v0.21.4+ hands a `--external-supervisor` gateway back to its
    /// supervisor, so that one restart is sent — but only for the PID status
    /// shows, and never on an older host, where the same restart runs the
    /// foreground path.
    @Test func anExternallySupervisedGatewayRestartsOnlyWhereHermesHandsItBack() {
        let supervised = Self.state(pid: 4242, argv: ["hermes", "gateway", "run", "--external-supervisor"])
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualRunning, statusExitCode: 0, stateJSON: supervised, capabilities: Self.v0214) == nil)
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualRunning, statusExitCode: 0, stateJSON: supervised, capabilities: Self.v0213) != nil)
        // A stale record for another PID proves nothing.
        let stale = Self.state(pid: 99, argv: ["hermes", "gateway", "run", "--external-supervisor"])
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualRunning, statusExitCode: 0, stateJSON: stale, capabilities: Self.v0214) != nil)
        let plain = Self.state(pid: 4242, argv: ["hermes", "gateway", "run"])
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualRunning, statusExitCode: 0, stateJSON: plain, capabilities: Self.v0214) != nil)
    }

    /// `hermes status`'s Gateway Service section on an s6 container
    /// (`status.py:231-234`, manager string `gateway.py:1469` @ v2026.9.24).
    static let s6Status = """
    ◆ Gateway Service
      Status:       ✓ running
      Manager:      s6 (container supervisor)
      PID(s):       57
    """

    /// An s6 container's gateway prints the no-service lines (status picks
    /// its branch from systemd/launchd/Windows only), yet `gateway restart`
    /// goes to s6 first (`gateway.py:4925-4926`). Restartable.
    @Test func anS6ContainerGatewayRestarts() {
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualRunning, statusExitCode: 0, stateJSON: nil, capabilities: .empty,
            managerStatusOutput: Self.s6Status) == nil)
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualStopped, statusExitCode: 0, stateJSON: nil, capabilities: .empty,
            managerStatusOutput: Self.s6Status) == nil)
        // A host `hermes status` that names another manager proves nothing.
        #expect(HermesGatewayRestartGuard.refusal(
            statusOutput: Self.manualRunning, statusExitCode: 0, stateJSON: nil, capabilities: .empty,
            managerStatusOutput: "  Manager:      Manual process") != nil)
    }

    final class Calls: @unchecked Sendable {
        var argvs: [[String]] = []
    }

    static func check(
        status: String, statusExit: Int32 = 0, manager: String = "", stopThenStart: Bool = false,
        state: Data? = nil, caps: HermesCapabilities = .empty, calls: Calls = Calls()
    ) -> HermesCLIOutcome? {
        HermesGatewayRestartGuard.check(
            run: { args, _ in
                calls.argvs.append(args)
                return args == ["gateway", "status"] ? (status, statusExit) : (manager, 0)
            },
            stateJSON: { state }, capabilities: caps, stopThenStart: stopThenStart)
    }

    /// `hermes status` is only asked on the no-service branch.
    @Test func checkAsksStatusOnlyWhenItMatters() {
        let service = Calls()
        #expect(Self.check(status: Self.launchd, calls: service) == nil)
        #expect(service.argvs == [["gateway", "status"]])

        let manual = Calls()
        #expect(Self.check(status: Self.manualRunning, calls: manual) != nil)
        #expect(manual.argvs == [["gateway", "status"], ["status"]])

        #expect(Self.check(status: Self.manualRunning, manager: Self.s6Status) == nil)
        #expect(Self.check(status: "", statusExit: -1)?.detail == HermesGatewayRestartGuard.statusUnreadableNote)
    }

    /// Stop + start (Health, the menu bar) refuses only a RUNNING hand-run
    /// gateway — a stopped one is what Start already handles — and never
    /// takes the external-supervisor exception, which is `gateway
    /// restart`'s own arm.
    @Test func stopThenStartRefusesOnlyARunningHandRunGateway() {
        #expect(Self.check(status: Self.manualStopped, stopThenStart: true) == nil)
        #expect(Self.check(status: Self.manualRunning, stopThenStart: true)?.detail
            == HermesGatewayRestartGuard.runningWithoutServiceNote)
        let supervised = Self.state(pid: 4242, argv: ["hermes", "gateway", "run", "--external-supervisor"])
        #expect(Self.check(status: Self.manualRunning, state: supervised, caps: Self.v0214) == nil)
        #expect(Self.check(status: Self.manualRunning, stopThenStart: true, state: supervised, caps: Self.v0214) != nil)
    }

    @Test func runningPIDsParse() {
        #expect(HermesGatewayRestartGuard.runningPIDs(statusOutput: "✓ Gateway is running (PID: 12, 34)") == [12, 34])
        #expect(HermesGatewayRestartGuard.runningPIDs(statusOutput: Self.launchd).isEmpty)
    }
}
