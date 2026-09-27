import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R19: the menu bar's Restart says why it can't restart a hand-run
/// gateway, a parked profile's restart is refused in the Gateway view, and
/// a supervised hand-back that outlasts the timeout reads "still
/// restarting".
@Suite("GatewayRestartR19", .serialized)
@MainActor
struct GatewayRestartR19Tests {

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ args: [String]) { lock.lock(); argvs.append(args); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return argvs }
    }

    private static func viewModel(
        status: String, restart: (String, Int32) = ("✓ Service restarted", 0), caps: HermesCapabilities = .empty,
        state: Data? = nil, calls: Calls
    ) throws -> MessagingGatewayViewModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r19-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let context = ServerContext.local(home: home)
        if let state { try state.write(to: URL(fileURLWithPath: context.paths.gatewayStateJSON)) }
        return MessagingGatewayViewModel(
            context: context,
            capabilities: caps,
            cliRunner: { args, _ in
                calls.record(args)
                if args == ["gateway", "status"] { return (status, 0) }
                if args == ["gateway", "restart"] { return restart }
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

    @Test func menuRestartStateFollowsTheGuard() {
        #expect(ServerLiveStatus.restartBlock(for: nil) == nil)
        #expect(ServerLiveStatus.restartBlock(for: HermesCLIOutcome(
            succeeded: false, detail: HermesGatewayRestartGuard.runningWithoutServiceNote)) == .handRun)
        #expect(ServerLiveStatus.restartBlock(for: HermesCLIOutcome(
            succeeded: false, detail: HermesGatewayRestartGuard.statusUnreadableNote)) == .statusUnknown)
    }

    /// The menu item is relabelled and disabled rather than silently doing
    /// nothing.
    @Test func menuRestartItemSaysWhy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("scarf/scarfApp.swift"), encoding: .utf8)
        #expect(source.contains(#"case .handRun: Text("Restart Hermes (running manually)")"#))
        #expect(source.contains(".disabled(!status.hermesRunning || status.restartBlock == .handRun)"))
    }

    @Test func aParkedProfileIsNotSentARestart() async throws {
        let calls = Calls()
        let vm = try Self.viewModel(status: "Profile 'work': parked (hermes -p work gateway start)", calls: calls)
        vm.restartGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(!calls.all.contains(["gateway", "restart"]))
        #expect(vm.actionMessage == HermesGatewayRestartGuard.parkedProfileNote)
        #expect(vm.actionFailed == true)
    }

    @Test func aSupervisedRestartPastTheTimeoutIsStillRestarting() async throws {
        let calls = Calls()
        let state = try JSONSerialization.data(withJSONObject: [
            "pid": 4242, "argv": ["hermes", "gateway", "run", "--external-supervisor"]])
        let vm = try Self.viewModel(
            status: HermesGatewayRestartGuardFixtures.manualRunning, restart: ("Command timed out after 60s.", -1),
            caps: HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)"), state: state, calls: calls)
        vm.restartGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(calls.all.contains(["gateway", "restart"]))
        #expect(vm.actionFailed == false, "unconfirmed, not failed")
        #expect(vm.actionMessage?.contains(HermesGatewayServiceVerdict.supervisedRestartPendingNote) == true,
                "\(vm.actionMessage ?? "nil")")
    }
}
