import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P2 (v0.21.5): a parked profile on the Gateway pane. `hermes gateway
/// status` on a parked named profile prints ONE line and no ✓/✗
/// (`hermes_cli/gateway_profile_lifecycle.py:86-88` @ `v2026.9.24`), so the
/// old reader fell back to whatever `gateway_state.json` last said — a green
/// "running" badge for a profile whose bots had been stopped.
@Suite("GatewayParkedProfileP2")
struct GatewayParkedProfileP2Tests {

    private static let parkedStatus = "Profile 'work': parked (hermes -p work gateway start)\n"
    private static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
    private static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    /// A home whose `gateway_state.json` still claims a live gateway — the
    /// stale file a parked profile leaves behind.
    private static func staleRunningContext() throws -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p2-parked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ctx = ServerContext.local(home: home)
        let json = #"{"pid": 4821, "gateway_state": "running", "platforms": {"telegram": {"state": "connected"}}}"#
        try Data(json.utf8).write(to: URL(fileURLWithPath: ctx.paths.gatewayStateJSON))
        return ctx
    }

    @MainActor private static func until(
        timeout: TimeInterval, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private static func loaded(
        capabilities: HermesCapabilities, status: String
    ) async throws -> MessagingGatewayViewModel {
        let vm = MessagingGatewayViewModel(
            context: try staleRunningContext(),
            capabilities: capabilities,
            cliRunner: { args, _ in
                args == ["gateway", "status"] ? (status, 0) : ("", 0)
            }
        )
        vm.load(force: true)
        await until(timeout: 10) { !vm.isLoading && vm.gateway.state != "unknown" }
        return vm
    }

    @MainActor @Test func aParkedProfileIsParkedNotStaleRunning() async throws {
        let vm = try await Self.loaded(capabilities: Self.v0215, status: Self.parkedStatus)
        #expect(vm.gateway.isParked)
        #expect(vm.gateway.isRunning == false)
        #expect(vm.gateway.isLoaded == false)
        #expect(vm.gateway.pid == nil, "the stale pid is not a live process")
        #expect(vm.gateway.platforms.isEmpty, "its bots are stopped")
        #expect(vm.gateway.state == "parked")
    }

    /// C1: below the floor the same output takes the old path exactly.
    @MainActor @Test func belowTheFloorTheOldFallbackIsUntouched() async throws {
        let vm = try await Self.loaded(capabilities: Self.v0214, status: Self.parkedStatus)
        #expect(vm.gateway.isParked == false)
        #expect(vm.gateway.state == "running")
        #expect(vm.gateway.pid == 4821)
    }

    /// The default profile's listing of parked satellites is not parked.
    @MainActor @Test func theDefaultProfilesListingIsNotParked() async throws {
        let vm = try await Self.loaded(
            capabilities: Self.v0215,
            status: Self.parkedStatus + "✓ Gateway is running (PID: 4821)\n  (Running manually, not as a system service)\n"
        )
        #expect(vm.gateway.isParked == false)
        #expect(vm.gateway.isRunning)
    }

    /// Stop on a served profile parks it: the banner claims the state and
    /// says only this profile moved (`gateway_profile_lifecycle.py:62-63`).
    @MainActor @Test func stoppingAServedProfileSaysParked() async throws {
        let vm = MessagingGatewayViewModel(
            context: try Self.staleRunningContext(),
            capabilities: Self.v0215,
            cliRunner: { args, _ in
                args == ["gateway", "stop"]
                    ? ("Profile 'work' parked; its bots and cron are stopped. Start again with: hermes -p work gateway start\n", 0)
                    : ("", 0)
            }
        )
        vm.stopGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        let message = try #require(vm.actionMessage)
        #expect(vm.actionFailed == false)
        #expect(message.contains("Gateway stopped"))
        #expect(message.contains("parked"))
    }
}
