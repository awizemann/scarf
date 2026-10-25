import Testing
import Foundation
@testable import ScarfCore

/// v0.22.3+ gateway lifecycle parity: the live-session refusal, `--yes`,
/// `--detach`, the incompatible-owner status line, and `status --all`.
/// Fixtures follow the v0.22.5 source verbatim
/// (`hermes_cli/gateway_lifecycle_guards.py:81-129`,
/// `gateway_runtime_start.py:86-97`, `gateway_status_notes.py:20-31`).
@Suite struct HermesGatewayLifecycleV0223Tests {

    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")
    static let v0216 = HermesCapabilities.parseLine("Hermes Agent v0.21.6 (2026.9.24)")
    static let v0221 = HermesCapabilities.parseLine("Hermes Agent v0.22.1 (2026.9.24)")
    static let v0222 = HermesCapabilities.parseLine("Hermes Agent v0.22.2 (2026.9.24)")
    static let v0225 = HermesCapabilities.parseLine("Hermes Agent v0.22.5 (2026.9.24)")

    /// `refuse_while_sessions_live` with no terminal: `print_error(lines[0])`,
    /// the rest printed plain, exit 1.
    static func refusal(_ verb: String, count: Int = 2) -> String {
        """
        ✗ Refusing to \(verb) the gateway: \(count) live session(s) would be interrupted.
          • telegram:42 — turn running 3m
          • cron job 'digest' — running
          Let them finish, or interrupt them deliberately:
            hermes gateway \(verb) --yes   # interrupts \(count) live session(s)
        """
    }

    // MARK: - live-session refusal

    @Test func refusalIsFailedAndQuotesTheFirstLine() {
        for verb in [HermesGatewayServiceVerdict.Verb.stop, .restart] {
            let outcome = HermesGatewayServiceVerdict.judge(
                verb: verb, output: Self.refusal(verb.rawValue), exitCode: 1)
            #expect(!outcome.succeeded)
            #expect(outcome.confidence == .failed)
            #expect(outcome.detail == "Refusing to \(verb.rawValue) the gateway: 2 live session(s) would be interrupted.")
            let live = HermesGatewayServiceVerdict.liveSessionRefusal(verb: verb, outcome: outcome)
            #expect(live?.count == 2)
        }
    }

    /// The other `Refusing to` line, the `--yes` warning, and a success are
    /// never a live-session refusal.
    @Test func otherShapesAreNotALiveSessionRefusal() {
        let insideGateway = HermesGatewayServiceVerdict.judge(
            verb: .stop, output: "✗ Refusing to stop the gateway from inside the gateway process.", exitCode: 1)
        #expect(HermesGatewayServiceVerdict.liveSessionRefusal(verb: .stop, outcome: insideGateway) == nil)

        let proceeded = """
        ⚠ --yes: stop proceeds: 2 live session(s) would be interrupted.
          • telegram:42 — turn running 3m
        ✓ Service stopped
        """
        let yes = HermesGatewayServiceVerdict.judge(verb: .stop, output: proceeded, exitCode: 0)
        #expect(yes.succeeded)
        #expect(HermesGatewayServiceVerdict.liveSessionRefusal(verb: .stop, output: proceeded) == nil)

        // The verb must match: a stop refusal is not a restart's.
        #expect(HermesGatewayServiceVerdict.liveSessionRefusal(verb: .restart, output: Self.refusal("stop")) == nil)
        #expect(HermesGatewayServiceVerdict.liveSessionRefusal(verb: .start, output: Self.refusal("stop")) == nil)
    }

    @Test func interruptIsOfferedOnlyWhereTheHostHasYes() {
        let outcome = HermesGatewayServiceVerdict.judge(verb: .stop, output: Self.refusal("stop", count: 1), exitCode: 1)
        #expect(HermesGatewayServiceVerdict.interruptOffer(verb: .stop, outcome: outcome, capabilities: Self.v0225)?.count == 1)
        #expect(HermesGatewayServiceVerdict.interruptOffer(verb: .stop, outcome: outcome, capabilities: Self.v0222) == nil)
        #expect(HermesGatewayServiceVerdict.interruptOffer(verb: .stop, outcome: outcome, capabilities: .empty) == nil)
    }

    // MARK: - argv

    @Test func argvAddsFlagsOnlyAtTheirFloors() {
        typealias V = HermesGatewayServiceVerdict
        for caps in [Self.v0215, Self.v0221, Self.v0222, HermesCapabilities.empty] {
            #expect(V.argv(.stop, capabilities: caps, interrupt: true) == ["gateway", "stop"])
            #expect(V.argv(.restart, capabilities: caps, interrupt: true) == ["gateway", "restart"])
        }
        #expect(V.argv(.restart, capabilities: Self.v0225) == ["gateway", "restart", "--detach"])
        #expect(V.argv(.stop, capabilities: Self.v0225) == ["gateway", "stop"])
        #expect(V.argv(.stop, capabilities: Self.v0225, interrupt: true) == ["gateway", "stop", "--yes"])
        #expect(V.argv(.restart, capabilities: Self.v0225, interrupt: true) == ["gateway", "restart", "--detach", "--yes"])
        #expect(V.argv(.start, capabilities: Self.v0225, interrupt: true) == ["gateway", "start"])
    }

    // MARK: - restart --detach

    @Test func detachedRestartLinesAreJudged() {
        let started = HermesGatewayServiceVerdict.judge(
            verb: .restart,
            output: "✓ Stopped gateway for this profile\nStarting gateway...\n✓ Started the gateway in the background",
            exitCode: 0)
        #expect(started.succeeded)

        // The failure line is on stderr after `Starting gateway...`: it must
        // not read as the foreground arm's "could not confirm".
        let failed = HermesGatewayServiceVerdict.judge(
            verb: .restart,
            output: "Starting gateway...\n✗ Could not start the gateway in the background: spawn_failed",
            exitCode: 1)
        #expect(failed.confidence == .failed)
        #expect(failed.detail == "✗ Could not start the gateway in the background: spawn_failed")
    }

    // MARK: - incompatible owner

    static let incompatibleHandRun = """
    ✗ Gateway is running (PID: 4242) but cannot serve this Hermes (incompatible: protocol_version)
      It was started by another Hermes version; TUI, Desktop and chat cannot attach to it.
      Replace it with this version:
        hermes gateway restart
    """

    static let incompatibleService = """
    ✓ Service is loaded
    ✗ The running gateway but cannot serve this Hermes (incompatible: unknown)
      It was started by another Hermes version; TUI, Desktop and chat cannot attach to it.
      Replace it with this version:
        hermes gateway restart
    """

    @Test func incompatibleOwnerParses() {
        #expect(HermesGatewayIncompatibleOwner.reason(statusOutput: Self.incompatibleHandRun) == "protocol_version")
        #expect(HermesGatewayIncompatibleOwner.isHandRun(statusOutput: Self.incompatibleHandRun))
        #expect(HermesGatewayIncompatibleOwner.reason(statusOutput: Self.incompatibleService) == "unknown")
        #expect(!HermesGatewayIncompatibleOwner.isHandRun(statusOutput: Self.incompatibleService))
        #expect(HermesGatewayIncompatibleOwner.reason(statusOutput: HermesGatewayRestartGuardR18aTests.manualRunning) == nil)
    }

    /// The hand-run spelling replaces the `(Running manually …)` pair, so the
    /// restart guard must still see a gateway with no service behind it.
    @Test func incompatibleHandRunIsStillNoService() {
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.incompatibleHandRun) == .runningWithoutService)
        #expect(HermesGatewayRestartGuard.mode(statusOutput: Self.incompatibleService) == .restartable)
        #expect(HermesGatewayRestartGuard.runningPIDs(statusOutput: Self.incompatibleHandRun) == [4242])
    }

    // MARK: - status --all

    @Test func fullStatusArgvFromV0216Only() {
        #expect(HermesStatusArgv.full(capabilities: .empty) == ["status"])
        #expect(HermesStatusArgv.full(capabilities: Self.v0215) == ["status"])
        #expect(HermesStatusArgv.full(capabilities: Self.v0216) == ["status", "--all"])
        #expect(HermesStatusArgv.full(capabilities: Self.v0225) == ["status", "--all"])
    }

    /// The guard's s6 probe asks the full view on a summary host.
    @Test func guardAsksFullStatusOnASummaryHost() {
        var asked: [[String]] = []
        _ = HermesGatewayRestartGuard.check(
            run: { args, _ in
                asked.append(args)
                return args == ["gateway", "status"] ? (HermesGatewayRestartGuardR18aTests.manualRunning, 0) : ("", 0)
            },
            stateJSON: { nil }, capabilities: Self.v0225)
        #expect(asked == [["gateway", "status"], ["status", "--all"]])
    }
}
