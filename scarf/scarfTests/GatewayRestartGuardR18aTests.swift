import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R18a (T5-F1): Restart on a gateway with no service behind it. Hermes
/// would stop the hand-run gateway and run the replacement inside Scarf's
/// own spawn (`hermes_cli/gateway.py:4977-4981` @ v2026.9.24), which Scarf's
/// timeout then kills. The Gateway pane now asks `gateway status` first and
/// never sends `gateway restart` into that state.
@Suite("GatewayRestartGuardR18a", .serialized)
@MainActor
struct GatewayRestartGuardR18aTests {

    /// Every argv the fake CLI saw, in order.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ args: [String]) { lock.lock(); argvs.append(args); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return argvs }
    }

    private static func viewModel(status: String, statusExit: Int32 = 0, calls: Calls) -> MessagingGatewayViewModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r18a-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return MessagingGatewayViewModel(
            context: .local(home: home),
            capabilities: .empty,
            cliRunner: { args, _ in
                calls.record(args)
                if args == ["gateway", "status"] { return (status, statusExit) }
                if args == ["gateway", "restart"] { return ("✓ Service restarted", 0) }
                return ("", 0)
            }
        )
    }

    private static func until(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aHandRunGatewayIsNeverSentARestart() async throws {
        let calls = Calls()
        let vm = Self.viewModel(status: HermesGatewayRestartGuardFixtures.manualRunning, calls: calls)
        vm.restartGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        let message = try #require(vm.actionMessage)
        #expect(!calls.all.contains(["gateway", "restart"]), "\(calls.all)")
        #expect(calls.all.first == ["gateway", "status"])
        #expect(message == HermesGatewayRestartGuard.runningWithoutServiceNote)
        #expect(vm.actionFailed == true, "it stays until the next action")
        #expect(vm.isBusy == false)
    }

    @Test func aStoppedNoServiceGatewayIsNotRestartedInTheForegroundEither() async throws {
        let calls = Calls()
        let vm = Self.viewModel(status: HermesGatewayRestartGuardFixtures.manualStopped, calls: calls)
        vm.restartGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(!calls.all.contains(["gateway", "restart"]))
        #expect(vm.actionMessage == HermesGatewayRestartGuard.stoppedWithoutServiceNote)
    }

    @Test func aServiceManagedGatewayStillRestarts() async throws {
        let calls = Calls()
        let vm = Self.viewModel(status: HermesGatewayRestartGuardFixtures.launchd, calls: calls)
        vm.restartGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(calls.all.contains(["gateway", "restart"]))
        #expect(vm.actionFailed == false)
        #expect(vm.actionMessage == "Gateway restarted")
    }

    @Test func aStatusTimeoutSendsNothing() async throws {
        let calls = Calls()
        let vm = Self.viewModel(status: "", statusExit: -1, calls: calls)
        vm.restartGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(!calls.all.contains(["gateway", "restart"]))
        #expect(vm.actionMessage == HermesGatewayRestartGuard.statusUnreadableNote)
    }

    /// Start and Stop are not gated: neither runs a gateway in the CLI's
    /// foreground.
    @Test func stopIsUnchanged() async throws {
        let calls = Calls()
        let vm = Self.viewModel(status: HermesGatewayRestartGuardFixtures.manualRunning, calls: calls)
        vm.stopGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(calls.all.first == ["gateway", "stop"])
    }

    /// Platforms and MCP restart through `HermesFileService.restartGateway()`,
    /// whose binary lookup a test can't redirect; pin that it asks status and
    /// consults the guard before it sends the restart.
    @Test func theSharedRestartAsksFirst() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scarf/Core/Services/HermesFileService.swift"),
            encoding: .utf8)
        let body = try #require(source.range(of: "nonisolated func restartGateway() -> HermesCLIOutcome {"))
        let rest = source[body.upperBound...]
        let status = try #require(rest.range(of: "args: [\"gateway\", \"status\"]"))
        let guardCall = try #require(rest.range(of: "HermesGatewayRestartGuard.refusal("))
        let restart = try #require(rest.range(of: "HermesGatewayServiceVerdict.argv(.restart)"))
        #expect(status.lowerBound < guardCall.lowerBound)
        #expect(guardCall.lowerBound < restart.lowerBound)
    }
}

/// Shapes printed by the v2026.9.24 checkout's `_cmd_status`.
enum HermesGatewayRestartGuardFixtures {
    static let manualRunning = """
    ✓ Gateway is running (PID: 4242)
      (Running manually, not as a system service)

    To install as a service:
      hermes gateway install
    """
    static let manualStopped = """
    ✗ Gateway is not running

    To start:
      hermes gateway run      # Run in foreground
      hermes gateway install  # Install as user service
    """
    static let launchd = """
    Launchd plist: /Users/a/Library/LaunchAgents/ai.hermes.gateway.plist
    ✓ Service definition matches the current Hermes install
    ✓ Gateway is supervised by launchd (PID 812)
    """
}
