import Testing
import Foundation
import ScarfCore
@testable import scarf

/// v0.22.3+: `gateway stop|restart` refuse while sessions are live
/// (`hermes_cli/gateway_lifecycle_guards.py:97-129` @ v0.22.5). The Gateway
/// pane shows Hermes's reason, asks, and only a confirmed answer re-runs the
/// verb with `--yes`.
@Suite("GatewayInterruptV0223", .serialized)
@MainActor
struct GatewayInterruptV0223Tests {

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ args: [String]) { lock.lock(); argvs.append(args); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return argvs }
    }

    static let v0225 = HermesCapabilities.parseLine("Hermes Agent v0.22.5 (2026.9.24)")
    static let refusal = """
    ✗ Refusing to stop the gateway: 2 live session(s) would be interrupted.
      • telegram:42 — turn running 3m
      Let them finish, or interrupt them deliberately:
        hermes gateway stop --yes   # interrupts 2 live session(s)
    """

    private static func viewModel(caps: HermesCapabilities, calls: Calls) -> MessagingGatewayViewModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-interrupt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return MessagingGatewayViewModel(
            context: .local(home: home), capabilities: caps,
            cliRunner: { args, _ in
                calls.record(args)
                if args == ["gateway", "stop"] { return (Self.refusal, 1) }
                if args == ["gateway", "stop", "--yes"] { return ("✓ Service stopped", 0) }
                return ("", 0)
            })
    }

    private static func until(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aRefusedStopAsksAndOnlyAYesSendsYes() async throws {
        let calls = Calls()
        let vm = Self.viewModel(caps: Self.v0225, calls: calls)
        vm.stopGateway()
        await Self.until(timeout: 10) { vm.pendingInterrupt != nil }
        let request = try #require(vm.pendingInterrupt)
        #expect(request.verb == .stop)
        #expect(request.count == 2)
        #expect(vm.actionFailed)
        #expect(vm.actionMessage?.contains("2 live session(s) would be interrupted.") == true)
        #expect(!calls.all.contains { $0.contains("--yes") })

        vm.confirmInterrupt(request)
        await Self.until(timeout: 10) { vm.actionMessage == "Gateway stopped" }
        #expect(calls.all.contains(["gateway", "stop", "--yes"]))
        #expect(vm.pendingInterrupt == nil)
    }

    /// A host without the flag never gets the question (it could not take
    /// `--yes` anyway).
    @Test func noQuestionBelowTheFloor() async throws {
        let calls = Calls()
        let vm = Self.viewModel(caps: .empty, calls: calls)
        vm.stopGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil && !vm.isBusy }
        #expect(vm.pendingInterrupt == nil)
    }

    @Test func incompatibleOwnerIsGated() {
        let line = "✗ Gateway is running (PID: 7) but cannot serve this Hermes (incompatible: protocol_version)"
        #expect(MessagingGatewayViewModel.incompatibleOwnerReason(statusOutput: line, capabilities: Self.v0225)
            == "protocol_version")
        #expect(MessagingGatewayViewModel.incompatibleOwnerReason(statusOutput: line, capabilities: .empty) == nil)
    }
}
